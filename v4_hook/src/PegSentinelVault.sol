// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Uniswap V4 imports
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title PegSentinelVault v2 — Treasury Buffer Model
/// @notice Protocol-owned vault for stablecoin peg defense
/// @dev Core LP stays at peg. Treasury from collected fees deploys as buffer during depeg.
///
/// Architecture:
///   - lpPosition: LP at tight range around peg (e.g. [-60, +60]). NEVER moved.
///   - bufferPosition: Single-sided USDT deployed below LP range during depeg. Funded by treasury.
///   - Treasury: Accumulated fees (USDC + USDT) sitting in vault, not deployed as LP.
///
/// Defense playbook:
///   1. EARN: LP earns fees at peg. Keeper calls collectFees() periodically → treasury grows.
///   2. DEFEND: Depeg detected → deployBuffer() puts treasury USDT below LP range as sell wall.
///   3. RECOVER: Peg restores → removeBuffer() pulls buffer back to treasury (now holding discounted USDC).
///   4. PROFIT: Treasury is richer from buying USDC at discount + dynamic fee revenue.
contract PegSentinelVault is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable token0; // USDC (sorted lower)
    IERC20 public immutable token1; // USDT (sorted higher)

    address public keeper;
    uint256 public rebalanceCooldown;
    uint256 public lastRebalanceAt;

    mapping(address => bool) public isAllowedTarget;

    /*//////////////////////////////////////////////////////////////
                           UNISWAP V4 CONFIG
    //////////////////////////////////////////////////////////////*/

    IPoolManager public poolManager;
    IPositionManager public positionManager;
    IAllowanceTransfer public permit2;

    PoolKey public poolKey;

    /*//////////////////////////////////////////////////////////////
                         REGIME DETECTION
    //////////////////////////////////////////////////////////////*/

    enum Regime {
        Normal,  // At peg — only LP active
        Defend   // Depeg detected — LP stays, buffer deployed
    }

    Regime public activeRegime;

    /// @notice Tick threshold: if current tick drops below this, deploy buffer
    int24 public defendThreshold;

    /// @notice Tick threshold for recovery: must rise above this to remove buffer (hysteresis)
    int24 public recoverThreshold;

    /*//////////////////////////////////////////////////////////////
                         RANGE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    struct RangeConfig {
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice LP range — tight around peg, never changes
    RangeConfig public lpRange;

    /// @notice Buffer range — below LP range, deployed during depeg
    RangeConfig public bufferRange;

    /*//////////////////////////////////////////////////////////////
                         POSITION METADATA
    //////////////////////////////////////////////////////////////*/

    struct PositionMeta {
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
        uint128 liquidity;
        bool active;
    }

    /// @notice The core LP position — stays at peg, never moved
    PositionMeta public lpPosition;

    /// @notice The buffer position — deployed/removed based on regime
    PositionMeta public bufferPosition;

    /// @notice Running total of fees collected into treasury
    uint256 public totalFeesCollected0;
    uint256 public totalFeesCollected1;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event AllowedTargetSet(address indexed target, bool allowed);
    event Funded(address indexed from, uint256 amount0, uint256 amount1);
    event TreasuryWithdrawn(address indexed to, uint256 amount0, uint256 amount1);
    event Executed(address indexed target, uint256 value, bytes data);
    event RebalanceCooldownUpdated(uint256 previous, uint256 current);
    event PoolKeyUpdated(Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, address hooks);

    event FeesCollected(uint256 amount0, uint256 amount1);
    event BufferDeployed(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 usdtDeployed);
    event BufferRemoved(uint256 tokenId, uint128 liquidity);
    event RegimeChanged(Regime indexed from, Regime indexed to, int24 currentTick);

    event PositionUpdated(
        bytes32 indexed label,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bool active
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotKeeperOrOwner();
    error CooldownActive(uint256 nextRebalanceAt);
    error ZeroAddress();
    error InvalidTickSpacing(int24 tickSpacing);
    error InvalidTicks(int24 tickLower, int24 tickUpper);
    error InvalidThresholds();
    error PositionManagerNotSet();
    error NoRegimeChange();
    error TargetNotAllowed(address target);
    error ExecutionFailed(address target, bytes data);
    error BufferAlreadyActive();
    error BufferNotActive();
    error InsufficientTreasuryUSDT(uint256 available, uint256 needed);

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

    constructor(
        address _token0,
        address _token1,
        address _owner
    ) Ownable(_owner) {
        if (_token0 == address(0) || _token1 == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }

        // Ensure token0 < token1 (Uniswap V4 requirement)
        if (_token0 > _token1) {
            (_token0, _token1) = (_token1, _token0);
        }

        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
    }

    /*//////////////////////////////////////////////////////////////
                             ADMIN SETTERS
    //////////////////////////////////////////////////////////////*/

    function setKeeper(address newKeeper) external onlyOwner {
        address old = keeper;
        keeper = newKeeper;
        emit KeeperUpdated(old, newKeeper);
    }

    function setPositionManager(address _positionManager) external onlyOwner {
        if (_positionManager == address(0)) revert ZeroAddress();
        positionManager = IPositionManager(_positionManager);
    }

    function setPoolManager(address _poolManager) external onlyOwner {
        if (_poolManager == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(_poolManager);
    }

    function setPermit2(address _permit2) external onlyOwner {
        if (_permit2 == address(0)) revert ZeroAddress();
        permit2 = IAllowanceTransfer(_permit2);
    }

    function setRebalanceCooldown(uint256 newCooldown) external onlyOwner {
        uint256 prev = rebalanceCooldown;
        rebalanceCooldown = newCooldown;
        emit RebalanceCooldownUpdated(prev, newCooldown);
    }

    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        isAllowedTarget[target] = allowed;
        emit AllowedTargetSet(target, allowed);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /*//////////////////////////////////////////////////////////////
                         EXECUTE (FOR SETUP/APPROVALS)
    //////////////////////////////////////////////////////////////*/

    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyKeeperOrOwner
        returns (bytes memory result)
    {
        if (!isAllowedTarget[target]) revert TargetNotAllowed(target);

        (bool success, bytes memory ret) = target.call{value: value}(data);
        if (!success) revert ExecutionFailed(target, ret);

        emit Executed(target, value, data);
        return ret;
    }

    /*//////////////////////////////////////////////////////////////
                         POOL KEY CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function setPoolKey(
        address _currency0,
        address _currency1,
        uint24 _fee,
        int24 _tickSpacing,
        address _hooks
    ) external onlyOwner {
        if (_tickSpacing <= 0) revert InvalidTickSpacing(_tickSpacing);

        poolKey = PoolKey({
            currency0: Currency.wrap(_currency0),
            currency1: Currency.wrap(_currency1),
            fee: _fee,
            tickSpacing: _tickSpacing,
            hooks: IHooks(_hooks)
        });

        emit PoolKeyUpdated(
            Currency.wrap(_currency0),
            Currency.wrap(_currency1),
            _fee,
            _tickSpacing,
            _hooks
        );
    }

    /*//////////////////////////////////////////////////////////////
                         RANGE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the LP range (tight around peg, e.g. [-60, +60])
    function setLPRange(int24 tickLower, int24 tickUpper) external onlyOwner {
        _validateTicks(tickLower, tickUpper);
        lpRange = RangeConfig(tickLower, tickUpper);
    }

    /// @notice Set the buffer range (below LP, e.g. [-240, -60])
    function setBufferRange(int24 tickLower, int24 tickUpper) external onlyOwner {
        _validateTicks(tickLower, tickUpper);
        bufferRange = RangeConfig(tickLower, tickUpper);
    }

    /// @notice Set defend/recover thresholds with hysteresis
    /// @param _defendThreshold  Deploy buffer when tick drops below this (e.g. -50)
    /// @param _recoverThreshold Remove buffer when tick rises above this (e.g. -30)
    function setThresholds(int24 _defendThreshold, int24 _recoverThreshold) external onlyOwner {
        if (_recoverThreshold <= _defendThreshold) revert InvalidThresholds();
        defendThreshold = _defendThreshold;
        recoverThreshold = _recoverThreshold;
    }

    function _validateTicks(int24 tickLower, int24 tickUpper) internal view {
        if (tickLower >= tickUpper) revert InvalidTicks(tickLower, tickUpper);

        int24 ts = poolKey.tickSpacing;
        if (ts > 0) {
            if (tickLower % ts != 0) revert InvalidTicks(tickLower, tickUpper);
            if (tickUpper % ts != 0) revert InvalidTicks(tickLower, tickUpper);
        }
    }

    /*//////////////////////////////////////////////////////////////
                         POSITION SETTERS (SETUP)
    //////////////////////////////////////////////////////////////*/

    /// @notice Set LP position metadata (after initial mint via script)
    function setLPPosition(
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        bool active
    ) external onlyKeeperOrOwner {
        uint128 liquidity = 0;
        if (address(positionManager) != address(0) && tokenId != 0) {
            liquidity = positionManager.getPositionLiquidity(tokenId);
        }
        lpPosition = PositionMeta(tokenId, tickLower, tickUpper, salt, liquidity, active);
        emit PositionUpdated(bytes32("LP"), tokenId, tickLower, tickUpper, liquidity, active);
    }

    /*//////////////////////////////////////////////////////////////
                               FUNDING
    //////////////////////////////////////////////////////////////*/

    function fund(uint256 amount0, uint256 amount1) external onlyOwner whenNotPaused nonReentrant {
        if (amount0 > 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) token1.safeTransferFrom(msg.sender, address(this), amount1);
        emit Funded(msg.sender, amount0, amount1);
    }

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
                         FEE COLLECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Collect accumulated fees from LP position into treasury
    /// @dev Calls DECREASE_LIQUIDITY with 0 amount to collect fees only
    function collectFees() external onlyKeeperOrOwner nonReentrant {
        if (address(positionManager) == address(0)) revert PositionManagerNotSet();
        if (lpPosition.tokenId == 0 || !lpPosition.active) return;

        uint256 bal0Before = token0.balanceOf(address(this));
        uint256 bal1Before = token1.balanceOf(address(this));

        // Decrease by 0 liquidity = collect fees only
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);

        params[0] = abi.encode(
            lpPosition.tokenId,
            uint128(0),  // 0 liquidity = fees only
            0,           // min amount0
            0,           // min amount1
            ""           // hookData
        );

        params[1] = abi.encode(
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1),
            address(this)
        );

        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60
        );

        uint256 fees0 = token0.balanceOf(address(this)) - bal0Before;
        uint256 fees1 = token1.balanceOf(address(this)) - bal1Before;

        totalFeesCollected0 += fees0;
        totalFeesCollected1 += fees1;

        emit FeesCollected(fees0, fees1);
    }

    /*//////////////////////////////////////////////////////////////
                         REGIME DETECTION
    //////////////////////////////////////////////////////////////*/

    function getCurrentTick() public view returns (int24 tick) {
        PoolId poolId = poolKey.toId();
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    /// @notice Determine target regime based on current tick and active regime (hysteresis)
    function determineRegime(int24 currentTick) public view returns (Regime) {
        if (activeRegime == Regime.Normal) {
            // Escalation: only enter Defend if tick drops below defend threshold
            if (currentTick <= defendThreshold) return Regime.Defend;
            return Regime.Normal;
        } else {
            // De-escalation: only return to Normal if tick rises above recover threshold
            if (currentTick >= recoverThreshold) return Regime.Normal;
            return Regime.Defend;
        }
    }

    function getTargetRegime() external view returns (Regime) {
        return determineRegime(getCurrentTick());
    }

    function needsRebalance() external view returns (
        bool needed,
        Regime currentRegime,
        Regime targetRegime,
        int24 currentTick
    ) {
        currentTick = getCurrentTick();
        currentRegime = activeRegime;
        targetRegime = determineRegime(currentTick);
        needed = (targetRegime != currentRegime);
    }

    /*//////////////////////////////////////////////////////////////
                         CORE: DEPLOY / REMOVE BUFFER
    //////////////////////////////////////////////////////////////*/

    /// @notice Auto-rebalance: deploy or remove buffer based on regime
    /// @dev Keeper calls this. LP is NEVER touched.
    function autoRebalance() external onlyKeeperOrOwner whenNotPaused nonReentrant {
        if (address(positionManager) == address(0)) revert PositionManagerNotSet();

        // Check cooldown
        if (rebalanceCooldown != 0) {
            uint256 next = lastRebalanceAt + rebalanceCooldown;
            if (block.timestamp < next) revert CooldownActive(next);
        }

        int24 currentTick = getCurrentTick();
        Regime targetRegime = determineRegime(currentTick);

        if (targetRegime == activeRegime) revert NoRegimeChange();

        Regime prevRegime = activeRegime;

        if (targetRegime == Regime.Defend) {
            _deployBuffer();
        } else {
            _removeBuffer();
        }

        activeRegime = targetRegime;
        lastRebalanceAt = block.timestamp;

        emit RegimeChanged(prevRegime, targetRegime, currentTick);
    }

    /// @notice Force deploy buffer (owner emergency)
    function forceDeployBuffer() external onlyOwner whenNotPaused nonReentrant {
        if (address(positionManager) == address(0)) revert PositionManagerNotSet();
        if (bufferPosition.active) revert BufferAlreadyActive();

        _deployBuffer();

        Regime prev = activeRegime;
        activeRegime = Regime.Defend;
        lastRebalanceAt = block.timestamp;

        emit RegimeChanged(prev, Regime.Defend, getCurrentTick());
    }

    /// @notice Force remove buffer (owner emergency)
    function forceRemoveBuffer() external onlyOwner whenNotPaused nonReentrant {
        if (address(positionManager) == address(0)) revert PositionManagerNotSet();
        if (!bufferPosition.active) revert BufferNotActive();

        _removeBuffer();

        Regime prev = activeRegime;
        activeRegime = Regime.Normal;
        lastRebalanceAt = block.timestamp;

        emit RegimeChanged(prev, Regime.Normal, getCurrentTick());
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL: BUFFER DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy treasury USDT as single-sided buffer below LP range
    function _deployBuffer() internal {
        if (bufferPosition.active) revert BufferAlreadyActive();

        // Use all available USDT in treasury as buffer
        // token1 = USDT (the strong token we deploy as defense)
        uint256 usdtAvailable = token1.balanceOf(address(this));
        if (usdtAvailable == 0) revert InsufficientTreasuryUSDT(0, 1);

        // Buffer is single-sided USDT below current price
        _approveTokens(0, usdtAvailable);

        uint128 liquidity = _calculateLiquidity(
            bufferRange.tickLower,
            bufferRange.tickUpper,
            0,              // no USDC
            usdtAvailable   // all USDT
        );

        uint256 tokenId = _mintNewPosition(
            bufferRange.tickLower,
            bufferRange.tickUpper,
            liquidity,
            0,
            usdtAvailable
        );

        bufferPosition = PositionMeta({
            tokenId: tokenId,
            tickLower: bufferRange.tickLower,
            tickUpper: bufferRange.tickUpper,
            salt: bytes32(tokenId),
            liquidity: liquidity,
            active: true
        });

        emit BufferDeployed(bufferRange.tickLower, bufferRange.tickUpper, liquidity, usdtAvailable);
        emit PositionUpdated(
            bytes32("BUFFER"),
            tokenId,
            bufferRange.tickLower,
            bufferRange.tickUpper,
            liquidity,
            true
        );
    }

    /// @notice Remove buffer position — returns tokens to treasury
    function _removeBuffer() internal {
        if (!bufferPosition.active) revert BufferNotActive();

        uint128 liquidity = positionManager.getPositionLiquidity(bufferPosition.tokenId);

        if (liquidity > 0) {
            bytes memory actions = abi.encodePacked(
                uint8(Actions.DECREASE_LIQUIDITY),
                uint8(Actions.TAKE_PAIR)
            );

            bytes[] memory params = new bytes[](2);

            params[0] = abi.encode(
                bufferPosition.tokenId,
                liquidity,
                0, // min amount0
                0, // min amount1
                "" // hookData
            );

            params[1] = abi.encode(
                Currency.unwrap(poolKey.currency0),
                Currency.unwrap(poolKey.currency1),
                address(this)
            );

            positionManager.modifyLiquidities(
                abi.encode(actions, params),
                block.timestamp + 60
            );
        }

        emit BufferRemoved(bufferPosition.tokenId, liquidity);

        // Clear buffer position
        bufferPosition.liquidity = 0;
        bufferPosition.active = false;
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL: UNISWAP V4 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _approveTokens(uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) {
            token0.forceApprove(address(permit2), amount0);
            permit2.approve(
                address(token0),
                address(positionManager),
                uint160(amount0),
                uint48(block.timestamp + 3600)
            );
        }
        if (amount1 > 0) {
            token1.forceApprove(address(permit2), amount1);
            permit2.approve(
                address(token1),
                address(positionManager),
                uint160(amount1),
                uint48(block.timestamp + 3600)
            );
        }
    }

    function _calculateLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128) {
        int24 currentTick = getCurrentTick();
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            amount0,
            amount1
        );
    }

    function _mintNewPosition(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal returns (uint256 tokenId) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);

        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            address(this),
            ""
        );

        params[1] = abi.encode(
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1)
        );

        tokenId = positionManager.nextTokenId();

        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60
        );

        return tokenId;
    }

    /*//////////////////////////////////////////////////////////////
                               VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get vault token balances (= treasury when no buffer deployed)
    function balances() external view returns (uint256 bal0, uint256 bal1) {
        bal0 = token0.balanceOf(address(this));
        bal1 = token1.balanceOf(address(this));
    }

    /// @notice Get treasury size (tokens in vault not deployed as buffer)
    function treasuryBalances() external view returns (uint256 treasury0, uint256 treasury1) {
        treasury0 = token0.balanceOf(address(this));
        treasury1 = token1.balanceOf(address(this));
    }

    function getLPPosition() external view returns (PositionMeta memory) {
        return lpPosition;
    }

    function getBufferPosition() external view returns (PositionMeta memory) {
        return bufferPosition;
    }

    function getPoolId() external view returns (PoolId) {
        return poolKey.toId();
    }

    /// @notice Get buffer L value for display/monitoring
    function getBufferLiquidity() external view returns (uint128) {
        if (!bufferPosition.active || bufferPosition.tokenId == 0) return 0;
        return positionManager.getPositionLiquidity(bufferPosition.tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                               RESCUE
    //////////////////////////////////////////////////////////////*/

    function rescueToken(address tokenAddr, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0) || tokenAddr == address(0)) revert ZeroAddress();
        IERC20(tokenAddr).safeTransfer(to, amount);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
