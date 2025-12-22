// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

// 1) set -a; source .env.anvil; set +a
// Change regime? export TARGET_REGIME=1
// 2) forge script script/06_AdjustLiquidity.s.sol:AdjustLiquidityScript --rpc-url $RPC_URL --broadcast -vv --via-ir

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";

import {PegSentinelVault} from "../src/PegSentinelVault.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Adjust liquidity for PegSentinelVault:
/// - Reads current active regime from vault.activeRegime()
/// - Auto-selects target regime based on currentTick, OR override with env TARGET_REGIME
/// - Decreases liquidity from the CURRENT active position (Normal->normalPosition, Mild/Severe->supportPosition)
/// - Then either:
///     A) INCREASE existing target position if it exists AND tickLower/tickUpper match target range
///     B) Otherwise MINT a NEW position to the vault and update vault metadata
///
/// Env vars:
/// Required:
/// - PRIVATE_KEY
/// - VAULT_ADDRESS
///
/// Optional:
/// - TARGET_REGIME (uint): 0=Normal, 1=Mild, 2=Severe. If unset/invalid => auto.
/// - AMOUNT0_MIN (uint) default 0
/// - AMOUNT1_MIN (uint) default 0
/// - DEADLINE_SECONDS (uint) default 300
/// - LP_FEE (uint) default DYNAMIC_FEE_FLAG
/// - TICK_SPACING (uint) default 60
/// - FORCE_MINT (bool) default false
contract AdjustLiquidityScript is Script, BaseScript, LiquidityHelpers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() external {
        // ---------- env ----------
        uint256 pk = uint256(vm.envBytes32("PRIVATE_KEY"));
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        uint256 amount0Min = vm.envOr("AMOUNT0_MIN", uint256(0));
        uint256 amount1Min = vm.envOr("AMOUNT1_MIN", uint256(0));
        uint256 deadlineSeconds = vm.envOr("DEADLINE_SECONDS", uint256(300));

        uint24 lpFee = uint24(vm.envOr("LP_FEE", uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG)));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        bool forceMint = vm.envOr("FORCE_MINT", false);

        PegSentinelVault vault = PegSentinelVault(payable(vaultAddr));

        // ---------- pool key ----------
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: hookContract
        });

        PoolId pid = poolKey.toId();
        bytes memory hookData = new bytes(0);

        // ---------- pool state ----------
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(pid);
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // ---------- decide regimes ----------
        PegSentinelVault.Regime currentRegime = vault.activeRegime();
        PegSentinelVault.Regime autoTarget = _determineTargetRegime(vault, currentTick);
        PegSentinelVault.Regime targetRegime = _overrideTargetRegimeIfProvided(autoTarget);

        console2.log("=== AdjustLiquidity ===");
        console2.log("vault:", vaultAddr);
        console2.log("currentTick:", int256(currentTick));
        console2.log("currentRegime:", uint256(currentRegime));
        console2.log("targetRegime :", uint256(targetRegime));
        console2.log("forceMint    :", forceMint);

        // ---------- get CURRENT active position (where liquidity currently is) ----------
        (uint256 tokenIdOld, int24 oldTickLower, int24 oldTickUpper, bytes32 saltOld, bool oldActive) =
            _getPositionForRegime(vault, currentRegime);

        require(oldActive, "old position not active");
        require(tokenIdOld != 0, "old tokenId=0");

        // ---------- read old liquidity from PoolManager ----------
        (uint128 liqOld,,) = poolManager.getPositionInfo(
            pid,
            address(positionManager),
            oldTickLower,
            oldTickUpper,
            saltOld
        );

        console2.log("tokenIdOld:", tokenIdOld);
        console2.log("oldTickLower:", int256(oldTickLower));
        console2.log("oldTickUpper:", int256(oldTickUpper));
        console2.log("saltOld:");
        console2.logBytes32(saltOld);
        console2.log("liqOld:", uint256(liqOld));
        require(liqOld > 0, "Old position liquidity=0 (wrong ticks/salt or empty)");

        // ---------- target ticks from vault range ----------
        (int24 newTickLower, int24 newTickUpper, bool enabledTarget) = _getRangeForRegime(vault, targetRegime);
        require(enabledTarget, "target range not enabled");
        require(newTickLower < newTickUpper, "bad target ticks");

        // Optional safety: ensure target ticks align to script tickSpacing
        // (your vault also validates multiples if pool.tickSpacing is set)
        require(newTickLower % tickSpacing == 0 && newTickUpper % tickSpacing == 0, "target ticks not aligned");

        console2.log("newTickLower:", int256(newTickLower));
        console2.log("newTickUpper:", int256(newTickUpper));

        // ---------- broadcast ----------
        vm.startBroadcast(pk);

        // ---- allowlist targets the vault will call (owner-only in vault) ----
        vault.setAllowedTarget(address(positionManager), true);
        vault.setAllowedTarget(address(permit2), true);

        address t0 = address(0);
        address t1 = address(0);

        if (!currency0.isAddressZero()) {
            t0 = Currency.unwrap(currency0);
            vault.setAllowedTarget(t0, true);
        }
        if (!currency1.isAddressZero()) {
            t1 = Currency.unwrap(currency1);
            vault.setAllowedTarget(t1, true);
        }

        // ---- approvals FROM THE VAULT (idempotent) ----
        _ensurePermit2Approvals(vault, t0, t1);

        // ---------- 1) DECREASE old liquidity to vault ----------
        (bytes memory decActions, bytes[] memory decParams) =
            _decreaseLiquidityParams(
                tokenIdOld,
                uint256(liqOld),
                amount0Min,
                amount1Min,
                vaultAddr,
                hookData
            );

        bytes memory decCall = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector,
            abi.encode(decActions, decParams),
            block.timestamp + deadlineSeconds
        );

        vault.execute(address(positionManager), 0, decCall);

        // ---------- balances now in vault ----------
        uint256 bal0 = currency0.isAddressZero() ? vaultAddr.balance : IERC20(t0).balanceOf(vaultAddr);
        uint256 bal1 = currency1.isAddressZero() ? vaultAddr.balance : IERC20(t1).balanceOf(vaultAddr);

        console2.log("Vault balances after decrease:");
        console2.log("bal0:", bal0);
        console2.log("bal1:", bal1);
        require(bal0 > 0 || bal1 > 0, "No funds in vault after decrease");

        // ---------- 2) add liquidity into TARGET position ----------
        // Normal => normalPosition, Mild/Severe => supportPosition
        (uint256 tokenIdTarget, int24 tLo, int24 tHi, bytes32 tSalt, bool tActive) =
            _getPositionForRegime(vault, targetRegime);

        bool canIncreaseExisting =
            (!forceMint) &&
            tActive &&
            tokenIdTarget != 0 &&
            tLo == newTickLower &&
            tHi == newTickUpper;

        if (canIncreaseExisting) {
            // -------- INCREASE existing target position --------
            uint128 liqAdd = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(newTickLower),
                TickMath.getSqrtPriceAtTick(newTickUpper),
                bal0,
                bal1
            );

            console2.log("Increasing existing target tokenId:", tokenIdTarget);
            console2.log("liqAdd:", uint256(liqAdd));
            console2.log("targetSalt:");
            console2.logBytes32(tSalt);

            (bytes memory incActions, bytes[] memory incParams) =
                _increaseLiquidityParams(
                    tokenIdTarget,
                    uint256(liqAdd),
                    bal0 + 1,
                    bal1 + 1,
                    hookData
                );

            bytes memory incCall = abi.encodeWithSelector(
                positionManager.modifyLiquidities.selector,
                abi.encode(incActions, incParams),
                block.timestamp + deadlineSeconds
            );

            uint256 valueToPass = currency0.isAddressZero() ? (bal0 + 1) : 0;
            vault.execute(address(positionManager), valueToPass, incCall);
        } else {
            // -------- MINT new target position --------
            uint128 liqNew = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(newTickLower),
                TickMath.getSqrtPriceAtTick(newTickUpper),
                bal0,
                bal1
            );

            uint256 tokenIdNew = positionManager.nextTokenId();
            bytes32 saltNew = bytes32(tokenIdNew);

            console2.log("Minting NEW target tokenId:", tokenIdNew);
            console2.log("liqNew:", uint256(liqNew));

            (bytes memory mintActions, bytes[] memory mintParams) =
                _mintLiquidityParams(
                    poolKey,
                    newTickLower,
                    newTickUpper,
                    uint256(liqNew),
                    bal0 + 1,
                    bal1 + 1,
                    vaultAddr,
                    hookData
                );

            bytes memory mintCall = abi.encodeWithSelector(
                positionManager.modifyLiquidities.selector,
                abi.encode(mintActions, mintParams),
                block.timestamp + deadlineSeconds
            );

            uint256 valueToPass = currency0.isAddressZero() ? (bal0 + 1) : 0;
            vault.execute(address(positionManager), valueToPass, mintCall);

            // update vault meta
            if (targetRegime == PegSentinelVault.Regime.Normal) {
                vault.setNormalPosition(tokenIdNew, newTickLower, newTickUpper, saltNew, true);
            } else {
                vault.setSupportPosition(tokenIdNew, newTickLower, newTickUpper, saltNew, true);
            }

            console2.log("Updated vault position meta for target regime.");
        }

        // ---------- finalize ----------
        vault.setActiveRegime(targetRegime);

        vm.stopBroadcast();

        console2.log("Done. activeRegime now:", uint256(targetRegime));
    }

    // ------------------------------------------------------------
    // Permit2 approvals (executed by the vault)
    // ------------------------------------------------------------

    function _ensurePermit2Approvals(PegSentinelVault vault, address t0, address t1) internal {
        // token.approve(permit2, max) + permit2.approve(token, positionManager, max160, max48)
        if (t0 != address(0)) {
            vault.execute(
                t0,
                0,
                abi.encodeWithSelector(IERC20.approve.selector, address(permit2), type(uint256).max)
            );
            vault.execute(
                address(permit2),
                0,
                abi.encodeWithSelector(
                    IPermit2.approve.selector,
                    t0,
                    address(positionManager),
                    type(uint160).max,
                    type(uint48).max
                )
            );
        }

        if (t1 != address(0)) {
            vault.execute(
                t1,
                0,
                abi.encodeWithSelector(IERC20.approve.selector, address(permit2), type(uint256).max)
            );
            vault.execute(
                address(permit2),
                0,
                abi.encodeWithSelector(
                    IPermit2.approve.selector,
                    t1,
                    address(positionManager),
                    type(uint160).max,
                    type(uint48).max
                )
            );
        }
    }

    // ------------------------------------------------------------
    // Regime / range / position helpers (tuple-based)
    // ------------------------------------------------------------

    function _getRangeForRegime(PegSentinelVault vault, PegSentinelVault.Regime r)
        internal
        view
        returns (int24 lo, int24 hi, bool en)
    {
        if (r == PegSentinelVault.Regime.Normal) return vault.normalRange();
        if (r == PegSentinelVault.Regime.Mild) return vault.mildRange();
        return vault.severeRange();
    }

    function _getPositionForRegime(PegSentinelVault vault, PegSentinelVault.Regime r)
        internal
        view
        returns (uint256 tokenId, int24 lo, int24 hi, bytes32 salt, bool active)
    {
        // Normal => normalPosition
        // Mild/Severe => supportPosition (shared)
        if (r == PegSentinelVault.Regime.Normal) return vault.normalPosition();
        return vault.supportPosition();
    }

    function _overrideTargetRegimeIfProvided(PegSentinelVault.Regime autoRegime)
        internal
        view
        returns (PegSentinelVault.Regime)
    {
        // If TARGET_REGIME not set, envOr returns 999 and we keep autoRegime.
        uint256 raw = vm.envOr("TARGET_REGIME", uint256(999));
        if (raw <= 2) return PegSentinelVault.Regime(raw);
        return autoRegime;
    }

    /// @dev Simple auto-selection based on your configured tick bands.
    /// Uses:
    /// - normalRange.tickLower as first “below peg” trigger
    /// - severeRange.tickUpper as deeper trigger
    function _determineTargetRegime(PegSentinelVault vault, int24 currentTick)
        internal
        view
        returns (PegSentinelVault.Regime)
    {
        (int24 nLo,, bool nEn) = vault.normalRange();
        (, int24 sHi, bool sEn) = vault.severeRange();
        (, , bool mEn) = vault.mildRange();
        require(nEn && mEn && sEn, "ranges not configured");

        if (currentTick < nLo) {
            if (currentTick < sHi) return PegSentinelVault.Regime.Severe;
            return PegSentinelVault.Regime.Mild;
        }
        return PegSentinelVault.Regime.Normal;
    }
}
