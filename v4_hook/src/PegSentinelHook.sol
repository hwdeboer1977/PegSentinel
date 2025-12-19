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

contract PegSentinelHook is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    // Fee parameters
    uint24  public constant MIN_FEE = 500;
    uint24  public constant BASE_FEE = 3000;
    uint24  public constant MAX_FEE = 100_000;
    uint256 public constant DEADZONE_BPS = 25;
    uint256 public constant ARB_TRIGGER_BPS = 5_000;
    uint256 public constant SLOPE_TOWARD = 150;
    uint256 public constant SLOPE_AWAY = 1200;

    // Hardcoded peg: 1 USD = 1e18
    uint256 public constant PEG_PRICE_1E18 = 1e18;

    // Token addresses (set your stablecoin pair here)
    address public immutable token0;
    address public immutable token1;
    uint8   public immutable decimals0;
    uint8   public immutable decimals1;

    event FeeChosen(uint24 rawFee, uint24 withFlag, bool toward, uint256 devBps);
    error MustUseDynamicFee();

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

    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal override pure
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

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

    function previewFee(PoolKey calldata key, bool zeroForOne)
        external view returns (uint24 fee, PegDebug memory dbg)
    {
        return _computePegFee(key, zeroForOne);
    }

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