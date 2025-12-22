// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PegSentinelVault (POC++)
/// @notice Protocol-owned vault that holds token0/token1 and stores LP configuration + regime ranges on-chain.
/// @dev No user shares, no ERC4626, no accounting. Owner = protocol treasury/multisig.
contract PegSentinelVault is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    /// @notice optional operator that can call `rebalance()` / `execute()` (if enabled)
    address public keeper;

    /// @notice optional allowlist for execution targets (recommended even for POC)
    mapping(address => bool) public isAllowedTarget;

    /// @notice optional cooldown for rebalances (anti-thrash)
    uint256 public rebalanceCooldown;
    uint256 public lastRebalanceAt;

    /*//////////////////////////////////////////////////////////////
                           UNISWAP V4 CONFIG
    //////////////////////////////////////////////////////////////*/

    struct PoolConfig {
        address hook;            // PegSentinelHook
        address permit2;         // Permit2
        address positionManager; // v4 PositionManager

        uint24 fee;              // e.g. DYNAMIC_FEE_FLAG
        int24 tickSpacing;       // e.g. 60
    }

    PoolConfig public pool;

    event PoolConfigUpdated(
        address hook,
        address permit2,
        address positionManager,
        uint24 fee,
        int24 tickSpacing
    );

    /*//////////////////////////////////////////////////////////////
                         REGIMES + RANGES (TICKS)
    //////////////////////////////////////////////////////////////*/

    enum Regime {
        Normal,
        Mild,
        Severe
    }

    struct RangeConfig {
        int24 tickLower;
        int24 tickUpper;
        bool enabled;
    }

    RangeConfig public normalRange; // price ~ 0.98–1.02
    RangeConfig public mildRange;   // price ~ 0.95–1.00
    RangeConfig public severeRange; // price ~ 0.85–0.97

    Regime public activeRegime;

    event RangeUpdated(Regime indexed regime, int24 tickLower, int24 tickUpper, bool enabled);
    event ActiveRegimeUpdated(Regime previous, Regime current);

    /*//////////////////////////////////////////////////////////////
                         POSITION METADATA (VAULT-OWNED)
    //////////////////////////////////////////////////////////////*/

    struct PositionMeta {
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;  // used with PoolManager.getPositionInfo; your current scheme is bytes32(tokenId)
        bool active;
    }

    PositionMeta public normalPosition;
    PositionMeta public supportPosition; // used for mild OR severe at any moment

    event PositionUpdated(
        bytes32 indexed label, // "NORMAL" / "SUPPORT"
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        bool active
    );

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event AllowedTargetSet(address indexed target, bool allowed);

    event Funded(address indexed from, uint256 amount0, uint256 amount1);
    event TreasuryWithdrawn(address indexed to, uint256 amount0, uint256 amount1);

    event Executed(address indexed target, uint256 value, bytes data, bytes result);
    event Rebalanced(address indexed caller);

    event RebalanceCooldownUpdated(uint256 previous, uint256 current);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotKeeperOrOwner();
    error TargetNotAllowed(address target);
    error CooldownActive(uint256 nextRebalanceAt);
    error ZeroAddress();
    error CallFailed(address target, bytes returndata);
    error InvalidTickSpacing(int24 tickSpacing);
    error InvalidTicks(int24 tickLower, int24 tickUpper);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyKeeperOrOwner() {
        if (msg.sender != owner() && msg.sender != keeper) revert NotKeeperOrOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _token0, address _token1, address _owner) Ownable(_owner) {
        if (_token0 == address(0) || _token1 == address(0) || _owner == address(0)) revert ZeroAddress();
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    /*//////////////////////////////////////////////////////////////
                             ADMIN SETTERS
    //////////////////////////////////////////////////////////////*/

    function setKeeper(address newKeeper) external onlyOwner {
        // keeper can be set to zero to disable
        address old = keeper;
        keeper = newKeeper;
        emit KeeperUpdated(old, newKeeper);
    }

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        isAllowedTarget[target] = allowed;
        emit AllowedTargetSet(target, allowed);
    }

    function setRebalanceCooldown(uint256 newCooldown) external onlyOwner {
        uint256 prev = rebalanceCooldown;
        rebalanceCooldown = newCooldown;
        emit RebalanceCooldownUpdated(prev, newCooldown);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /*//////////////////////////////////////////////////////////////
                         UNISWAP CONFIG SETTERS
    //////////////////////////////////////////////////////////////*/

    function setPoolConfig(
        address hook,
        address permit2,
        address positionManager,
        uint24 fee,
        int24 tickSpacing
    ) external onlyOwner {
        if (permit2 == address(0) || positionManager == address(0)) revert ZeroAddress();
        if (tickSpacing <= 0) revert InvalidTickSpacing(tickSpacing);

        pool = PoolConfig({
            hook: hook,
            permit2: permit2,
            positionManager: positionManager,
            fee: fee,
            tickSpacing: tickSpacing
        });

        emit PoolConfigUpdated(hook, permit2, positionManager, fee, tickSpacing);
    }

    function setRange(Regime regime, int24 tickLower, int24 tickUpper, bool enabled) external onlyOwner {
        _validateTicks(tickLower, tickUpper);

        if (regime == Regime.Normal) normalRange = RangeConfig(tickLower, tickUpper, enabled);
        else if (regime == Regime.Mild) mildRange = RangeConfig(tickLower, tickUpper, enabled);
        else severeRange = RangeConfig(tickLower, tickUpper, enabled);

        emit RangeUpdated(regime, tickLower, tickUpper, enabled);
    }

    function setActiveRegime(Regime next) external onlyKeeperOrOwner {
        Regime prev = activeRegime;
        activeRegime = next;
        emit ActiveRegimeUpdated(prev, next);
    }

    /// @dev ticks should be multiples of tickSpacing once set
    function _validateTicks(int24 tickLower, int24 tickUpper) internal view {
        if (tickLower >= tickUpper) revert InvalidTicks(tickLower, tickUpper);

        int24 ts = pool.tickSpacing;
        if (ts > 0) {
            // ensure multiples of spacing (Solidity int division truncates toward zero; fine for our typical multiples)
            if ((tickLower / ts) * ts != tickLower) revert InvalidTicks(tickLower, tickUpper);
            if ((tickUpper / ts) * ts != tickUpper) revert InvalidTicks(tickLower, tickUpper);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       POSITION METADATA SETTERS
    //////////////////////////////////////////////////////////////*/

    function setNormalPosition(
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        bool active
    ) external onlyKeeperOrOwner {
        _validateTicks(tickLower, tickUpper);
        normalPosition = PositionMeta(tokenId, tickLower, tickUpper, salt, active);
        emit PositionUpdated("NORMAL", tokenId, tickLower, tickUpper, salt, active);
    }

    function setSupportPosition(
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        bool active
    ) external onlyKeeperOrOwner {
        _validateTicks(tickLower, tickUpper);
        supportPosition = PositionMeta(tokenId, tickLower, tickUpper, salt, active);
        emit PositionUpdated("SUPPORT", tokenId, tickLower, tickUpper, salt, active);
    }

    /// @notice Convenience for your current scheme: salt == bytes32(tokenId)
    function saltFromTokenId(uint256 tokenId) external pure returns (bytes32) {
        return bytes32(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                               FUNDING
    //////////////////////////////////////////////////////////////*/

    /// @notice Pull funds from the treasury (owner must approve first).
    function fund(uint256 amount0, uint256 amount1) external onlyOwner whenNotPaused nonReentrant {
        if (amount0 > 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) token1.safeTransferFrom(msg.sender, address(this), amount1);
        emit Funded(msg.sender, amount0, amount1);
    }

    /// @notice Send idle funds back to the treasury.
    function withdrawTreasury(address to, uint256 amount0, uint256 amount1)
        external
        onlyOwner
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount0 > 0) token0.safeTransfer(to, amount0);
        if (amount1 > 0) token1.safeTransfer(to, amount1);
        emit TreasuryWithdrawn(to, amount0, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                              CORE EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute a call to an allowed target (e.g., PositionManager / Permit2 / ERC20 approvals).
    function execute(address target, uint256 value, bytes calldata data)
        public
        onlyKeeperOrOwner
        whenNotPaused
        nonReentrant
        returns (bytes memory result)
    {
        if (!isAllowedTarget[target]) revert TargetNotAllowed(target);

        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) revert CallFailed(target, ret);

        emit Executed(target, value, data, ret);
        return ret;
    }

    /// @notice A thin wrapper: typically decrease liquidity, then add/increase liquidity.
    /// @dev You pass the exact calldata you want to run on your PositionManager/Router.
    function rebalance(
        address targetA,
        bytes calldata callA,
        address targetB,
        bytes calldata callB
    ) external onlyKeeperOrOwner whenNotPaused nonReentrant {
        // optional cooldown
        if (rebalanceCooldown != 0) {
            uint256 next = lastRebalanceAt + rebalanceCooldown;
            if (block.timestamp < next) revert CooldownActive(next);
        }

        if (callA.length != 0) {
            if (!isAllowedTarget[targetA]) revert TargetNotAllowed(targetA);
            (bool okA, bytes memory retA) = targetA.call(callA);
            if (!okA) revert CallFailed(targetA, retA);
            emit Executed(targetA, 0, callA, retA);
        }

        if (callB.length != 0) {
            if (!isAllowedTarget[targetB]) revert TargetNotAllowed(targetB);
            (bool okB, bytes memory retB) = targetB.call(callB);
            if (!okB) revert CallFailed(targetB, retB);
            emit Executed(targetB, 0, callB, retB);
        }

        lastRebalanceAt = block.timestamp;
        emit Rebalanced(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                               VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function balances() external view returns (uint256 bal0, uint256 bal1) {
        bal0 = token0.balanceOf(address(this));
        bal1 = token1.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                               RESCUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Rescue any ERC20 accidentally sent here (NOT token0/token1 unless you explicitly want that).
    function rescueToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0) || token == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    receive() external payable {}
}
