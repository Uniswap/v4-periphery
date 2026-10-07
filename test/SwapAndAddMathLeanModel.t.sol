// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapAndAddMath} from "../src/libraries/SwapAndAddMath.sol";

/// @notice Replays test vectors produced by the Lean model in fv/swap-and-add/SwapAndAddFV against the
///         Solidity. The Lean proofs are about the model, so these checks are what tie them to the code:
///         every vector must give the model's output, including the sentinel and revert cases.
///         Regenerate with `lake exe vectors` in fv/swap-and-add/SwapAndAddFV.
contract SwapAndAddMathLeanModelTest is Test {
    string constant VECTORS = "fv/swap-and-add/vectors/";

    struct TrimVectors {
        uint256[] p;
        uint256[] lo;
        uint256[] hi;
        bool[] deficitIsCurrency1;
        uint256[] d;
        uint256[] expected;
        bool[] reverts;
    }

    struct AmountVectors {
        uint256[] a;
        uint256[] b;
        uint256[] liquidity;
        uint256[] amount0Up;
        uint256[] amount0Down;
        uint256[] amount1Up;
        uint256[] amount1Down;
    }

    function test_getLiquidityToTrim_matchesLeanModel() public view {
        TrimVectors memory v = _loadTrim();
        assertGt(v.p.length, 0, "no vectors");
        for (uint256 i; i < v.p.length; i++) {
            string memory label = string.concat("trim vector ", vm.toString(i));
            try this.getLiquidityToTrim(
                uint160(v.p[i]), uint160(v.lo[i]), uint160(v.hi[i]), v.deficitIsCurrency1[i], v.d[i]
            ) returns (
                uint256 got
            ) {
                assertFalse(v.reverts[i], string.concat(label, ": expected a revert"));
                assertEq(got, v.expected[i], label);
            } catch {
                assertTrue(v.reverts[i], string.concat(label, ": unexpected revert"));
            }
        }
    }

    function test_getAmountDeltas_matchLeanModel() public view {
        AmountVectors memory v = _loadAmounts();
        assertGt(v.a.length, 0, "no vectors");
        for (uint256 i; i < v.a.length; i++) {
            string memory label = string.concat("amount vector ", vm.toString(i));
            (uint160 a, uint160 b, uint128 l) = (uint160(v.a[i]), uint160(v.b[i]), uint128(v.liquidity[i]));
            assertEq(SqrtPriceMath.getAmount0Delta(a, b, l, true), v.amount0Up[i], string.concat(label, " amount0Up"));
            assertEq(
                SqrtPriceMath.getAmount0Delta(a, b, l, false), v.amount0Down[i], string.concat(label, " amount0Down")
            );
            assertEq(SqrtPriceMath.getAmount1Delta(a, b, l, true), v.amount1Up[i], string.concat(label, " amount1Up"));
            assertEq(
                SqrtPriceMath.getAmount1Delta(a, b, l, false), v.amount1Down[i], string.concat(label, " amount1Down")
            );
        }
    }

    function test_calculateSwapFee_matchesLeanModel() public view {
        string memory json = _read("fees.json");
        uint256[] memory pf = vm.parseJsonUintArray(json, ".protocolFee");
        uint256[] memory lf = vm.parseJsonUintArray(json, ".lpFee");
        uint256[] memory zeroForOne = vm.parseJsonUintArray(json, ".zeroForOneFee");
        uint256[] memory oneForZero = vm.parseJsonUintArray(json, ".oneForZeroFee");
        assertGt(pf.length, 0, "no vectors");
        for (uint256 i; i < pf.length; i++) {
            string memory label = string.concat("fee vector ", vm.toString(i));
            uint24 protocolFee = uint24(pf[i]);
            uint24 lpFee = uint24(lf[i]);
            assertEq(
                ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.getZeroForOneFee(protocolFee), lpFee),
                zeroForOne[i],
                string.concat(label, " zeroForOne")
            );
            assertEq(
                ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.getOneForZeroFee(protocolFee), lpFee),
                oneForZero[i],
                string.concat(label, " oneForZero")
            );
        }
    }

    function test_getAmountsForLiquidityRoundingUp_matchesLeanModel() public view {
        string memory json = _read("roundingUp.json");
        uint256[] memory p = vm.parseJsonUintArray(json, ".p");
        uint256[] memory lo = vm.parseJsonUintArray(json, ".lo");
        uint256[] memory hi = vm.parseJsonUintArray(json, ".hi");
        uint256[] memory liquidity = vm.parseJsonUintArray(json, ".liquidity");
        uint256[] memory amount0 = vm.parseJsonUintArray(json, ".amount0");
        uint256[] memory amount1 = vm.parseJsonUintArray(json, ".amount1");
        bool[] memory reverts = vm.parseJsonBoolArray(json, ".reverts");
        assertGt(p.length, 0, "no vectors");
        for (uint256 i; i < p.length; i++) {
            string memory label = string.concat("roundingUp vector ", vm.toString(i));
            try this.getAmountsForLiquidityRoundingUp(
                uint160(p[i]), uint160(lo[i]), uint160(hi[i]), uint128(liquidity[i])
            ) returns (
                uint256 a0, uint256 a1
            ) {
                assertFalse(reverts[i], string.concat(label, ": expected a revert"));
                assertEq(a0, amount0[i], string.concat(label, " amount0"));
                assertEq(a1, amount1[i], string.concat(label, " amount1"));
            } catch {
                assertTrue(reverts[i], string.concat(label, ": unexpected revert"));
            }
        }
    }

    function test_getLiquidityForAmountsWeighted_matchesLeanModel() public view {
        SizingVectors memory v = _loadSizing("weighted.json", ".amount0", ".amount1", ".pipsWeight0", ".pipsWeight1");
        for (uint256 i; i < v.p.length; i++) {
            string memory label = string.concat("weighted vector ", vm.toString(i));
            try this.getLiquidityForAmountsWeighted(
                uint160(v.p[i]), uint160(v.lo[i]), uint160(v.hi[i]), v.x0[i], v.x1[i], v.y0[i], v.y1[i]
            ) returns (
                uint128 got
            ) {
                assertFalse(v.reverts[i], string.concat(label, ": expected a revert"));
                assertEq(got, v.expected[i], label);
            } catch {
                assertTrue(v.reverts[i], string.concat(label, ": unexpected revert"));
            }
        }
    }

    function test_getLiquidityFeeAware_matchesLeanModel() public view {
        SizingVectors memory v = _loadSizing("feeAware.json", ".budget0", ".budget1", ".protocolFee", ".lpFee");
        for (uint256 i; i < v.p.length; i++) {
            string memory label = string.concat("feeAware vector ", vm.toString(i));
            try this.getLiquidityFeeAware(
                uint160(v.p[i]), uint160(v.lo[i]), uint160(v.hi[i]), v.x0[i], v.x1[i], uint24(v.y0[i]), uint24(v.y1[i])
            ) returns (
                uint128 got
            ) {
                assertFalse(v.reverts[i], string.concat(label, ": expected a revert"));
                assertEq(got, v.expected[i], label);
            } catch {
                assertTrue(v.reverts[i], string.concat(label, ": unexpected revert"));
            }
        }
    }

    function test_getSqrtPriceAtTick_matchesLeanModel() public view {
        string memory json = _read("ticks.json");
        int256[] memory ticks = vm.parseJsonIntArray(json, ".tick");
        uint256[] memory expected = vm.parseJsonUintArray(json, ".expected");
        bool[] memory reverts = vm.parseJsonBoolArray(json, ".reverts");
        assertGt(ticks.length, 0, "no vectors");
        for (uint256 i; i < ticks.length; i++) {
            string memory label = string.concat("tick vector ", vm.toString(i));
            try this.getSqrtPriceAtTick(int24(ticks[i])) returns (uint160 got) {
                assertFalse(reverts[i], string.concat(label, ": expected a revert"));
                assertEq(got, expected[i], label);
            } catch {
                assertTrue(reverts[i], string.concat(label, ": unexpected revert"));
            }
        }
    }

    function getSqrtPriceAtTick(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    /// @dev Shared shape of the weighted and fee-aware vectors: a price and range, two amounts, two
    ///      parameters (weights or fees), and the outcome.
    struct SizingVectors {
        uint256[] p;
        uint256[] lo;
        uint256[] hi;
        uint256[] x0;
        uint256[] x1;
        uint256[] y0;
        uint256[] y1;
        uint256[] expected;
        bool[] reverts;
    }

    function _loadSizing(string memory file, string memory x0, string memory x1, string memory y0, string memory y1)
        internal
        view
        returns (SizingVectors memory v)
    {
        string memory json = _read(file);
        v.p = vm.parseJsonUintArray(json, ".p");
        v.lo = vm.parseJsonUintArray(json, ".lo");
        v.hi = vm.parseJsonUintArray(json, ".hi");
        v.x0 = vm.parseJsonUintArray(json, x0);
        v.x1 = vm.parseJsonUintArray(json, x1);
        v.y0 = vm.parseJsonUintArray(json, y0);
        v.y1 = vm.parseJsonUintArray(json, y1);
        v.expected = vm.parseJsonUintArray(json, ".expected");
        v.reverts = vm.parseJsonBoolArray(json, ".reverts");
        assertGt(v.p.length, 0, "no vectors");
    }

    function _read(string memory file) internal view returns (string memory) {
        return vm.readFile(string.concat(VECTORS, file));
    }

    function getAmountsForLiquidityRoundingUp(uint160 p, uint160 lo, uint160 hi, uint128 liquidity)
        external
        pure
        returns (uint256, uint256)
    {
        return SwapAndAddMath.getAmountsForLiquidityRoundingUp(p, lo, hi, liquidity);
    }

    function getLiquidityForAmountsWeighted(
        uint160 p,
        uint160 lo,
        uint160 hi,
        uint256 amount0,
        uint256 amount1,
        uint256 pipsWeight0,
        uint256 pipsWeight1
    ) external pure returns (uint128) {
        return SwapAndAddMath.getLiquidityForAmountsWeighted(p, lo, hi, amount0, amount1, pipsWeight0, pipsWeight1);
    }

    function getLiquidityFeeAware(
        uint160 p,
        uint160 lo,
        uint160 hi,
        uint256 budget0,
        uint256 budget1,
        uint24 protocolFee,
        uint24 lpFee
    ) external pure returns (uint128) {
        return SwapAndAddMath.getLiquidityFeeAware(p, lo, hi, budget0, budget1, protocolFee, lpFee);
    }

    /// @dev External so reverts can be caught with try/catch.
    function getLiquidityToTrim(uint160 p, uint160 lo, uint160 hi, bool deficitIsCurrency1, uint256 d)
        external
        pure
        returns (uint256)
    {
        return SwapAndAddMath.getLiquidityToTrim(p, lo, hi, deficitIsCurrency1, d);
    }

    function _loadTrim() internal view returns (TrimVectors memory v) {
        string memory json = vm.readFile(string.concat(VECTORS, "trim.json"));
        v.p = vm.parseJsonUintArray(json, ".p");
        v.lo = vm.parseJsonUintArray(json, ".lo");
        v.hi = vm.parseJsonUintArray(json, ".hi");
        v.deficitIsCurrency1 = vm.parseJsonBoolArray(json, ".deficitIsCurrency1");
        v.d = vm.parseJsonUintArray(json, ".d");
        v.expected = vm.parseJsonUintArray(json, ".expected");
        v.reverts = vm.parseJsonBoolArray(json, ".reverts");
    }

    function _loadAmounts() internal view returns (AmountVectors memory v) {
        string memory json = vm.readFile(string.concat(VECTORS, "amounts.json"));
        v.a = vm.parseJsonUintArray(json, ".a");
        v.b = vm.parseJsonUintArray(json, ".b");
        v.liquidity = vm.parseJsonUintArray(json, ".liquidity");
        v.amount0Up = vm.parseJsonUintArray(json, ".amount0Up");
        v.amount0Down = vm.parseJsonUintArray(json, ".amount0Down");
        v.amount1Up = vm.parseJsonUintArray(json, ".amount1Up");
        v.amount1Down = vm.parseJsonUintArray(json, ".amount1Down");
    }
}
