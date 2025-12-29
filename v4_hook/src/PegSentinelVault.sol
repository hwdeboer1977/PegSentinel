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



/// @title PegSentinelVault (Hackathon Edition)
/// @notice Protocol-owned vault with FULL on-chain rebalancing for stablecoin peg defense
/// @dev Keeper only needs to call `autoRebalance()` - all logic is on-chain
contract PegSentinelVault is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    /// @notice Keeper that can call `autoRebalance()`
    address public keeper;

    /// @notice Cooldown between rebalances (anti-thrash)
    uint256 public rebalanceCooldown;
    uint256 public lastRebalanceAt;

    /// @notice Allowlist for execute() targets
    mapping(address => bool) public isAllowedTarget;

    /*//////////////////////////////////////////////////////////////
                           UNISWAP V4 CONFIG
    //////////////////////////////////////////////////////////////*/

    IPoolManager public poolManager;
    IPositionManager public positionManager;
    IAllowanceTransfer public permit2;

    PoolKey public poolKey;

    event PoolKeyUpdated(
        Currency currency0,
        Currency currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks
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

    RangeConfig public normalRange;
    RangeConfig public mildRange;
    RangeConfig public severeRange;

    Regime public activeRegime;

    /// @notice Tick thresholds for automatic regime detection
    int24 public mildThreshold;     // Below this = Mild regime
    int24 public severeThreshold;   // Below this = Severe regime

    event RangeUpdated(Regime indexed regime, int24 tickLower, int24 tickUpper, bool enabled);
    event ActiveRegimeUpdated(Regime previous, Regime current);
    event ThresholdsUpdated(int24 mildThreshold, int24 severeThreshold);

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

    PositionMeta public normalPosition;
    PositionMeta public supportPosition;

    event PositionUpdated(
        bytes32 indexed label,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bool active
    );

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event AllowedTargetSet(address indexed target, bool allowed);
    event Funded(address indexed from, uint256 amount0, uint256 amount1);
    event TreasuryWithdrawn(address indexed to, uint256 amount0, uint256 amount1);
    event Executed(address indexed target, uint256 value, bytes data);
    event Rebalanced(address indexed caller, Regime fromRegime, Regime toRegime, int24 currentTick);
    event RebalanceCooldownUpdated(uint256 previous, uint256 current);
    event LiquidityWithdrawn(uint256 indexed tokenId, uint128 liquidity);
    event LiquidityAdded(uint256 indexed tokenId, uint128 liquidity);
    event PositionMinted(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotKeeperOrOwner();
    error CooldownActive(uint256 nextRebalanceAt);
    error ZeroAddress();
    error InvalidTickSpacing(int24 tickSpacing);
    error InvalidTicks(int24 tickLower, int24 tickUpper);
    error InvalidThresholds();
    error RegimeNotEnabled(Regime regime);
    error NoLiquidityToWithdraw();
    error InsufficientBalance(uint256 required0, uint256 required1, uint256 available0, uint256 available1);
    error PositionManagerNotSet();
    error NoRegimeChange();
    error TargetNotAllowed(address target);
    error ExecutionFailed(address target, bytes data);

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

    /// @notice Execute arbitrary call to allowed target
    /// @dev Used for initial setup, approvals, and manual operations
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
                         REGIME CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function setRange(Regime regime, int24 tickLower, int24 tickUpper, bool enabled) external onlyOwner {
        _validateTicks(tickLower, tickUpper);

        if (regime == Regime.Normal) {
            normalRange = RangeConfig(tickLower, tickUpper, enabled);
        } else if (regime == Regime.Mild) {
            mildRange = RangeConfig(tickLower, tickUpper, enabled);
        } else {
            severeRange = RangeConfig(tickLower, tickUpper, enabled);
        }

        emit RangeUpdated(regime, tickLower, tickUpper, enabled);
    }

    function setThresholds(int24 _mildThreshold, int24 _severeThreshold) external onlyOwner {
        if (_severeThreshold >= _mildThreshold) revert InvalidThresholds();
        mildThreshold = _mildThreshold;
        severeThreshold = _severeThreshold;
        emit ThresholdsUpdated(_mildThreshold, _severeThreshold);
    }

    /// @notice Manually set the active regime (for initialization or emergency)
    function setActiveRegime(Regime regime) external onlyKeeperOrOwner {
        Regime prev = activeRegime;
        activeRegime = regime;
        emit ActiveRegimeUpdated(prev, regime);
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
                         POSITION SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set normal position metadata (script-compatible signature with bytes32 salt)
    function setNormalPosition(
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        bool active
    ) external onlyKeeperOrOwner {
        // Query actual liquidity from position manager if available
        uint128 liquidity = 0;
        if (address(positionManager) != address(0) && tokenId != 0) {
            liquidity = positionManager.getPositionLiquidity(tokenId);
        }
        normalPosition = PositionMeta(tokenId, tickLower, tickUpper, salt, liquidity, active);
        emit PositionUpdated(bytes32("NORMAL"), tokenId, tickLower, tickUpper, liquidity, active);
    }

    /// @notice Set support position metadata (script-compatible signature with bytes32 salt)
    function setSupportPosition(
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
        supportPosition = PositionMeta(tokenId, tickLower, tickUpper, salt, liquidity, active);
        emit PositionUpdated(bytes32("SUPPORT"), tokenId, tickLower, tickUpper, liquidity, active);
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
                          REGIME DETECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Get current tick from the pool
    function getCurrentTick() public view returns (int24 tick) {
        PoolId poolId = poolKey.toId();
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    /// @notice Determine which regime the pool should be in based on current tick
    function determineRegime(int24 currentTick) public view returns (Regime) {
        if (currentTick <= severeThreshold) return Regime.Severe;
        if (currentTick <= mildThreshold) return Regime.Mild;
        return Regime.Normal;
    }

    /// @notice Get the target regime based on current pool state
    function getTargetRegime() external view returns (Regime) {
        return determineRegime(getCurrentTick());
    }

    /// @notice Check if rebalance is needed
    function needsRebalance() external view returns (bool needed, Regime currentRegime, Regime targetRegime, int24 currentTick) {
        currentTick = getCurrentTick();
        currentRegime = activeRegime;
        targetRegime = determineRegime(currentTick);
        needed = (targetRegime != currentRegime);
    }

    /*//////////////////////////////////////////////////////////////
                         CORE AUTO-REBALANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Fully on-chain rebalance - keeper just calls this
    /// @dev Withdraws from current position, deposits into target regime position
    function autoRebalance() external onlyKeeperOrOwner whenNotPaused nonReentrant {
        if (address(positionManager) == address(0)) revert PositionManagerNotSet();
        
        // 1. Check cooldown
        if (rebalanceCooldown != 0) {
            uint256 next = lastRebalanceAt + rebalanceCooldown;
            if (block.timestamp < next) revert CooldownActive(next);
        }

        // 2. Get current tick and determine target regime
        int24 currentTick = getCurrentTick();
        Regime targetRegime = determineRegime(currentTick);

        // 3. Skip if no change needed
        if (targetRegime == activeRegime) revert NoRegimeChange();

        // 4. Get target range config
        RangeConfig memory targetRange = _getRangeConfig(targetRegime);
        if (!targetRange.enabled) revert RegimeNotEnabled(targetRegime);

        // 5. Execute the rebalance
        _executeRebalance(activeRegime, targetRegime, targetRange);

        // 6. Update state
        Regime prevRegime = activeRegime;
        activeRegime = targetRegime;
        lastRebalanceAt = block.timestamp;

        emit Rebalanced(msg.sender, prevRegime, targetRegime, currentTick);
    }

    /// @notice Force rebalance to a specific regime (for testing/emergency)
    function forceRebalance(Regime targetRegime) external onlyOwner whenNotPaused nonReentrant {
        if (address(positionManager) == address(0)) revert PositionManagerNotSet();
        if (targetRegime == activeRegime) revert NoRegimeChange();

        RangeConfig memory targetRange = _getRangeConfig(targetRegime);
        if (!targetRange.enabled) revert RegimeNotEnabled(targetRegime);

        _executeRebalance(activeRegime, targetRegime, targetRange);

        Regime prevRegime = activeRegime;
        activeRegime = targetRegime;
        lastRebalanceAt = block.timestamp;

        int24 currentTick = getCurrentTick();
        emit Rebalanced(msg.sender, prevRegime, targetRegime, currentTick);
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL REBALANCE LOGIC
    //////////////////////////////////////////////////////////////*/

    function _getRangeConfig(Regime regime) internal view returns (RangeConfig memory) {
        if (regime == Regime.Normal) return normalRange;
        if (regime == Regime.Mild) return mildRange;
        return severeRange;
    }

    function _executeRebalance(
        Regime fromRegime,
        Regime toRegime,
        RangeConfig memory targetRange
    ) internal {
        // Step 1: Withdraw liquidity from current position
        _withdrawFromCurrentPosition(fromRegime);

        // Step 2: Calculate how much liquidity we can add with current balances
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));

        // Step 3: Add liquidity to target position
        _addToTargetPosition(toRegime, targetRange, bal0, bal1);
    }

    function _withdrawFromCurrentPosition(Regime fromRegime) internal returns (uint128 liquidity) {
        PositionMeta storage pos;
        
        if (fromRegime == Regime.Normal) {
            pos = normalPosition;
        } else {
            pos = supportPosition;
        }

        if (!pos.active || pos.tokenId == 0) return 0;

        // Query current liquidity from position manager
        liquidity = positionManager.getPositionLiquidity(pos.tokenId);
        if (liquidity == 0) return 0;

        // Build decrease liquidity action
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        
        // DECREASE_LIQUIDITY params
        params[0] = abi.encode(
            pos.tokenId,
            liquidity,
            0, // min amount0
            0, // min amount1
            ""  // hookData
        );

        // TAKE_PAIR params - send tokens to this vault
        params[1] = abi.encode(
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1),
            address(this)
        );

        // Execute via PositionManager
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60
        );

        // Update position metadata
        pos.liquidity = 0;
        pos.active = false;

        emit LiquidityWithdrawn(pos.tokenId, liquidity);
        
        return liquidity;
    }

    function _addToTargetPosition(
        Regime toRegime,
        RangeConfig memory targetRange,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal {
        // Approve tokens to PositionManager via Permit2
        _approveTokens(amount0Max, amount1Max);

        PositionMeta storage targetPos;
        bool isNormalTarget = (toRegime == Regime.Normal);
        
        if (isNormalTarget) {
            targetPos = normalPosition;
        } else {
            targetPos = supportPosition;
        }

        // Calculate liquidity from available amounts
        uint128 liquidity = _calculateLiquidity(
            targetRange.tickLower,
            targetRange.tickUpper,
            amount0Max,
            amount1Max
        );

        if (targetPos.tokenId != 0 && targetPos.tickLower == targetRange.tickLower && targetPos.tickUpper == targetRange.tickUpper) {
            // Existing position with same range - increase liquidity
            _increaseLiquidity(targetPos.tokenId, liquidity, amount0Max, amount1Max);
            targetPos.liquidity += liquidity;
            targetPos.active = true;
            
            emit LiquidityAdded(targetPos.tokenId, liquidity);
        } else {
            // Need to mint new position
            uint256 newTokenId = _mintNewPosition(
                targetRange.tickLower,
                targetRange.tickUpper,
                liquidity,
                amount0Max,
                amount1Max
            );

            // Update position metadata
            targetPos.tokenId = newTokenId;
            targetPos.tickLower = targetRange.tickLower;
            targetPos.tickUpper = targetRange.tickUpper;
            targetPos.salt = bytes32(newTokenId);
            targetPos.liquidity = liquidity;
            targetPos.active = true;

            emit PositionMinted(newTokenId, targetRange.tickLower, targetRange.tickUpper, liquidity);
        }

        emit PositionUpdated(
            isNormalTarget ? bytes32("NORMAL") : bytes32("SUPPORT"),
            targetPos.tokenId,
            targetPos.tickLower,
            targetPos.tickUpper,
            targetPos.liquidity,
            targetPos.active
        );
    }

    function _approveTokens(uint256 amount0, uint256 amount1) internal {
        // Reset and set approvals for Permit2
        token0.forceApprove(address(permit2), amount0);
        token1.forceApprove(address(permit2), amount1);

        // Approve PositionManager via Permit2
        permit2.approve(
            address(token0),
            address(positionManager),
            uint160(amount0),
            uint48(block.timestamp + 3600)
        );
        permit2.approve(
            address(token1),
            address(positionManager),
            uint160(amount1),
            uint48(block.timestamp + 3600)
        );
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

    function _increaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        
        params[0] = abi.encode(
            tokenId,
            liquidity,
            amount0Max,
            amount1Max,
            ""  // hookData
        );

        params[1] = abi.encode(
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1)
        );

        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60
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
            address(this), // owner of the NFT
            ""  // hookData
        );

        params[1] = abi.encode(
            Currency.unwrap(poolKey.currency0),
            Currency.unwrap(poolKey.currency1)
        );

        // Get tokenId before minting (next token ID)
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

    function balances() external view returns (uint256 bal0, uint256 bal1) {
        bal0 = token0.balanceOf(address(this));
        bal1 = token1.balanceOf(address(this));
    }

    function getPositionInfo(Regime regime) external view returns (PositionMeta memory) {
        if (regime == Regime.Normal) return normalPosition;
        return supportPosition;
    }

    function getRangeConfig(Regime regime) external view returns (RangeConfig memory) {
        return _getRangeConfig(regime);
    }

    function getPoolId() external view returns (PoolId) {
        return poolKey.toId();
    }

    /*//////////////////////////////////////////////////////////////
                               RESCUE
    //////////////////////////////////////////////////////////////*/

    function rescueToken(address tokenAddr, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0) || tokenAddr == address(0)) revert ZeroAddress();
        IERC20(tokenAddr).safeTransfer(to, amount);
    }

    /// @notice Receive NFTs (for LP position ownership)
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
