// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PegFeeMath, PegDebug} from "./lib/PegFeeMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

/**
 * @title PegSentinelHook
 * @notice Uniswap v4 hook that applies directional dynamic fees based on pool price vs peg.
 *
 * Swaps that push price away from $1 are penalised with higher fees (up to MAX_FEE).
 * Swaps that help restore the peg are rewarded with lower fees (down to MIN_FEE).
 * This creates an asymmetric cost structure that makes depegging expensive and
 * arb-back-to-peg attractive.
 *
 * Fee logic is delegated to PegFeeMath.compute(). This contract handles:
 *   - hook permission registration
 *   - dynamic fee enforcement via OVERRIDE_FEE_FLAG
 *   - price decoding from sqrtPriceX96
 *   - direction classification (toward/away from peg)
 */
contract PegSentinelHook is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------------------
    // Fee parameters
    // ---------------------------------------------------------------------------

    /// @notice Minimum fee (0.05%) — applied to strongly restorative swaps.
    uint24  public constant MIN_FEE = 500;

    /// @notice Base fee (0.30%) — applied near the peg within the deadzone.
    uint24  public constant BASE_FEE = 3000;

    /// @notice Maximum fee (10%) — applied to maximally destabilising swaps.
    uint24  public constant MAX_FEE = 100_000;

    /// @notice Deadzone around peg in basis points. Price deviation below this
    ///         is treated as "at peg" and charged the BASE_FEE. (25 bps = 0.25%)
    uint256 public constant DEADZONE_BPS = 25;

    /// @notice Deviation in bps at which the fee saturates at MAX_FEE for harmful
    ///         direction swaps. Beyond this point no further fee increase is applied. (50%)
    uint256 public constant ARB_TRIGGER_BPS = 5_000;

    /// @notice Fee slope scalar for swaps toward peg. Lower value = gentler discount curve.
    uint256 public constant SLOPE_TOWARD = 150;

    /// @notice Fee slope scalar for swaps away from peg. Higher value = steeper penalty curve.
    uint256 public constant SLOPE_AWAY = 1200;

    // ---------------------------------------------------------------------------
    // Peg reference
    // ---------------------------------------------------------------------------

    /// @notice Target peg price expressed as a 1e18-scaled ratio (token1 per token0).
    ///         For a USDC/USDT pair both at $1 this is 1e18.
    uint256 public constant PEG_PRICE_1E18 = 1e18;

    // ---------------------------------------------------------------------------
    // Token metadata (immutable, set once at construction)
    // ---------------------------------------------------------------------------

    /// @notice Canonical token0 address (lower address of the sorted pair).
    address public immutable token0;

    /// @notice Canonical token1 address (higher address of the sorted pair).
    address public immutable token1;

    /// @notice Decimal precision of token0. Used to normalise sqrtPrice to 1e18.
    uint8   public immutable decimals0;

    /// @notice Decimal precision of token1. Used to normalise sqrtPrice to 1e18.
    uint8   public immutable decimals1;

    // ---------------------------------------------------------------------------
    // Events / errors
    // ---------------------------------------------------------------------------

    /// @notice Emitted on every swap with the chosen fee and debug context.
    /// @param rawFee     The fee value before the override flag is applied.
    /// @param withFlag   rawFee OR'd with OVERRIDE_FEE_FLAG, as passed to the pool.
    /// @param toward     True if the swap direction moves price toward the peg.
    /// @param devBps     Current price deviation from peg in basis points.
    event FeeChosen(uint24 rawFee, uint24 withFlag, bool toward, uint256 devBps);

    /// @notice Reverts if the pool is not initialised with the dynamic fee flag.
    error MustUseDynamicFee();

    // ---------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------

    /**
     * @param _poolManager  The Uniswap v4 PoolManager this hook is registered with.
     * @param _tokenA       One token of the stablecoin pair (order does not matter).
     * @param _tokenB       The other token of the stablecoin pair.
     */
    constructor(
        IPoolManager _poolManager,
        address _tokenA,
        address _tokenB
    ) BaseHook(_poolManager) {
        // Sort tokens
        (address t0, address t1) = _tokenA < _tokenB 
            ? (_tokenA, _tokenB) 
            : (_tokenB, _tokenA);
        
        token0 = t0;
        token1 = t1;
        decimals0 = IERC20Metadata(t0).decimals();
        decimals1 = IERC20Metadata(t1).decimals();
    }

    // ---------------------------------------------------------------------------
    // Hook permissions
    // ---------------------------------------------------------------------------

    /**
     * @notice Declares which hook callbacks this contract implements.
     *         Only beforeInitialize and beforeSwap are active; all others are disabled
     *         to minimise gas overhead on unrelated pool operations.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------

    /**
     * @notice Enforces that the pool uses a dynamic fee. Called once at pool initialisation.
     *         Reverts with MustUseDynamicFee if the pool fee slot does not have the
     *         dynamic fee flag set.
     */
    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal override pure
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    /**
     * @notice Computes and overrides the swap fee on every swap.
     *         Reads current sqrtPrice from slot0, determines swap direction relative
     *         to peg, delegates fee calculation to PegFeeMath, then returns the fee
     *         with OVERRIDE_FEE_FLAG set so the pool accepts it as a per-swap override.
     */
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        (uint24 fee, PegDebug memory dbg) = _computePegFee(key, params.zeroForOne);
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        emit FeeChosen(fee, feeWithFlag, dbg.toward, dbg.devBps);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    // ---------------------------------------------------------------------------
    // Internal fee logic
    // ---------------------------------------------------------------------------

    /**
     * @notice Core fee computation. Reads slot0 for the current price, converts it
     *         to a 1e18-scaled ratio, classifies swap direction, and calls PegFeeMath.
     * @param key        The pool key identifying the pool.
     * @param zeroForOne True if the swap sells token0 for token1.
     * @return fee       The computed fee in hundredths of a bip (e.g. 3000 = 0.30%).
     * @return dbg       Debug struct with deviation, direction, and intermediate values.
     */
    function _computePegFee(PoolKey calldata key, bool zeroForOne)
        internal view
        returns (uint24 fee, PegDebug memory dbg)
    {
        // Get current pool price
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        uint256 lpPrice1e18 = _decodePriceE18(sqrtP);

        // Direction relative to $1 peg
        bool toward = _isTowardPeg(zeroForOne, lpPrice1e18, PEG_PRICE_1E18);

        // Compute fee
        (fee, dbg) = PegFeeMath.compute(
            lpPrice1e18,
            PEG_PRICE_1E18,
            toward,
            BASE_FEE,
            MIN_FEE,
            MAX_FEE,
            DEADZONE_BPS,
            SLOPE_TOWARD,
            SLOPE_AWAY,
            ARB_TRIGGER_BPS
        );
    }

    /**
     * @notice Converts a Uniswap v4 sqrtPriceX96 value to a 1e18-scaled price ratio,
     *         accounting for token decimal differences.
     *
     *         sqrtPriceX96 encodes sqrt(token1/token0) * 2^96.
     *         Squaring and dividing by 2^96 gives the raw ratio in token units.
     *         The decimal adjustment normalises to a common 1e18 basis so the hook
     *         can compare against PEG_PRICE_1E18 regardless of token precision.
     *
     * @param sqrtP  The sqrtPriceX96 value from slot0.
     * @return       Price of token0 in token1 terms, scaled to 1e18.
     */
    function _decodePriceE18(uint160 sqrtP) internal view returns (uint256) {
        uint256 s = uint256(sqrtP);
        uint256 q96 = 1 << 96;
        uint256 pq96 = FullMath.mulDiv(s, s, q96);
        
        // Adjust for decimal differences and scale to 1e18
        // price = (pq96 / 2^96) * 10^(decimals0 - decimals1) * 1e18
        int256 decimalDiff = int256(uint256(decimals0)) - int256(uint256(decimals1));
        
        if (decimalDiff >= 0) {
            uint256 scale = 10 ** uint256(decimalDiff);
            return FullMath.mulDiv(pq96, 1e18 * scale, q96);
        } else {
            uint256 scale = 10 ** uint256(-decimalDiff);
            return FullMath.mulDiv(pq96, 1e18, q96 * scale);
        }
    }

    /**
     * @notice Determines whether a swap moves the pool price toward or away from peg.
     *
     *         In Uniswap v4, zeroForOne=true means selling token0 → price of token0
     *         falls (more token1 per token0, so ratio goes up if token1 is the numerator,
     *         or down if token0 is). The logic here interprets the price as token1/token0:
     *           - price below peg → need price to rise → restorative direction is !zeroForOne
     *           - price above peg → need price to fall → restorative direction is zeroForOne
     *
     * @param zeroForOne    True if swapping token0 for token1.
     * @param lpPrice1e18   Current pool price scaled to 1e18.
     * @param pegPrice1e18  Target peg price scaled to 1e18 (always 1e18 for a $1 peg).
     * @return              True if this swap helps restore the peg.
     */
    function _isTowardPeg(
        bool zeroForOne,
        uint256 lpPrice1e18,
        uint256 pegPrice1e18
    ) internal pure returns (bool) {
        if (lpPrice1e18 < pegPrice1e18) {
            return !zeroForOne; // need price up
        } else if (lpPrice1e18 > pegPrice1e18) {
            return zeroForOne;  // need price down
        }
        return true; // at peg
    }

    // ---------------------------------------------------------------------------
    // View helpers
    // ---------------------------------------------------------------------------

    /**
     * @notice Off-chain fee preview for a given swap direction.
     *         Useful for frontends and keepers to display the expected fee before
     *         submitting a transaction. Reads live slot0 state so the result reflects
     *         the current pool price.
     * @param key        The pool key to query.
     * @param zeroForOne True if the swap sells token0 for token1.
     * @return fee       The fee that would be applied to this swap right now.
     * @return dbg       Debug struct with deviation, slope, and direction fields.
     */
    function previewFee(PoolKey calldata key, bool zeroForOne)
        external view returns (uint24 fee, PegDebug memory dbg)
    {
        return _computePegFee(key, zeroForOne);
    }

    /**
     * @notice Constructs a PoolKey for the dynamic-fee pool managed by this hook.
     *         Convenience helper for scripts and tests — avoids having to manually
     *         assemble the key with the correct fee flag (0x800000) and hook address.
     * @param tickSpacing  The tick spacing configured for the pool.
     * @return             A fully populated PoolKey ready for use with PoolManager calls.
     */
    function keyDynamic(int24 tickSpacing) public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            hooks: IHooks(address(this)),
            fee: 0x800000,
            tickSpacing: tickSpacing
        });
    }
}
