// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {BttBase} from "./BttBase.sol";
import {ISwapAndAddHarness} from "./ISwapAndAddHarness.sol";

contract DeployLiquidityTest is BttBase {
    using CurrencyLibrary for Currency;

    modifier givenDeployTokenIdIsZero() {
        _;
    }

    function test_WhenMintingOnErc20Pool() public givenDeployTokenIdIsZero {
        // it mints a new POSM NFT to the zap and writes the requested liquidity
        uint256 budget0 = 50e18;
        uint256 budget1 = 50e18;
        _fundZap(currency0, budget0);
        _fundZap(currency1, budget1);
        zap.exposedEnsureApproved(currency0);
        zap.exposedEnsureApproved(currency1);

        ISwapAndAddHarness.CoreParams memory cp = _core(key, budget0, budget1);
        (uint160 sl, uint160 su) = _sqrtBounds();
        (uint128 liq, uint256 a0,) = zap.exposedPlanLiquidity(cp, sl, su);
        uint256 nextId = lpm.nextTokenId();

        uint256 tokenId = zap.exposedDeployLiquidity(cp, liq, a0);

        assertEq(tokenId, nextId, "tokenId is the next mint id");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(zap), "NFT sits on the zap until add transfers it");
        assertEq(lpm.getPositionLiquidity(tokenId), liq, "deployed liquidity");
        assertEq(lpm.nextTokenId(), nextId + 1, "nextTokenId advanced");
    }

    modifier whenThePoolIsNative() {
        _;
    }

    function test_WhenMintingOnNativePool_Amount0GtZero() public givenDeployTokenIdIsZero whenThePoolIsNative {
        // it forwards amount0 as msg.value and mints the native position
        uint256 budget0 = 1e18;
        uint256 budget1 = 1e18;
        vm.deal(address(zap), budget0);
        _fundZap(currency1, budget1);
        zap.exposedEnsureApproved(currency1);

        ISwapAndAddHarness.CoreParams memory cp = _core(nativeKey, budget0, budget1);
        (uint160 sl, uint160 su) = _sqrtBounds();
        (uint128 liq, uint256 a0,) = zap.exposedPlanLiquidity(cp, sl, su);
        uint256 nextId = lpm.nextTokenId();

        uint256 tokenId = zap.exposedDeployLiquidity{value: 0}(cp, liq, a0);

        assertEq(tokenId, nextId, "tokenId");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(zap), "NFT on zap");
        assertEq(lpm.getPositionLiquidity(tokenId), liq, "deployed liquidity");
        // Native SWEEP returns unconsumed wei of the forwarded ETH to the zap (MSG_SENDER).
        assertGt(lpm.getPositionLiquidity(tokenId), 0, "native mint wrote liquidity");
    }

    function test_WhenMintingOnNativePool_Amount0EqZero() public givenDeployTokenIdIsZero whenThePoolIsNative {
        // it forwards 0 value and still mints (below-range token1-only)
        uint256 budget1 = 20e18;
        _fundZap(currency1, budget1);
        zap.exposedEnsureApproved(currency1);

        ISwapAndAddHarness.CoreParams memory cp = _core(nativeKey, 0, budget1);
        cp.tickLower = -1200;
        cp.tickUpper = -600;
        uint160 sl = TickMath.getSqrtPriceAtTick(cp.tickLower);
        uint160 su = TickMath.getSqrtPriceAtTick(cp.tickUpper);
        (uint128 liq, uint256 a0, uint256 a1) = zap.exposedPlanLiquidity(cp, sl, su);
        assertEq(a0, 0, "token1-only range: no token0");
        assertGt(a1, 0, "token1-only range: token1");
        assertGt(liq, 0, "sized liquidity");

        uint256 tokenId = zap.exposedDeployLiquidity(cp, liq, a0);

        assertEq(lpm.getPositionLiquidity(tokenId), liq, "deployed liquidity");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(zap), "NFT on zap");
    }

    modifier givenDeployTokenIdIsNonZero() {
        _;
    }

    function test_WhenIncreasingOnErc20Pool() public givenDeployTokenIdIsNonZero {
        // it grows that tokenId in place and does not mint a new NFT
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        uint128 liqBefore = lpm.getPositionLiquidity(tokenId);
        uint256 nextBefore = lpm.nextTokenId();

        uint256 budget0 = 20e18;
        uint256 budget1 = 20e18;
        _fundZap(currency0, budget0);
        _fundZap(currency1, budget1);
        zap.exposedEnsureApproved(currency0);
        zap.exposedEnsureApproved(currency1);

        ISwapAndAddHarness.CoreParams memory cp = _core(key, budget0, budget1);
        cp.deployTokenId = tokenId;
        (uint160 sl, uint160 su) = _sqrtBounds();
        (uint128 addLiq, uint256 a0,) = zap.exposedPlanLiquidity(cp, sl, su);

        uint256 returnedId = zap.exposedDeployLiquidity(cp, addLiq, a0);

        assertEq(returnedId, tokenId, "same tokenId");
        assertEq(lpm.nextTokenId(), nextBefore, "no new NFT");
        assertEq(lpm.getPositionLiquidity(tokenId), liqBefore + addLiq, "liquidity grew by addLiq");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "owner unchanged");
    }

    function test_WhenIncreasingOnNativePool() public givenDeployTokenIdIsNonZero {
        // it grows that tokenId in place and leaves no ETH on the zap
        uint256 tokenId = _nativeAdd(1e17);
        _approvePosmForZap();
        uint128 liqBefore = lpm.getPositionLiquidity(tokenId);
        uint256 nextBefore = lpm.nextTokenId();

        uint256 budget0 = 1e17;
        uint256 budget1 = 1e17;
        vm.deal(address(zap), budget0);
        _fundZap(currency1, budget1);
        zap.exposedEnsureApproved(currency1);

        ISwapAndAddHarness.CoreParams memory cp = _core(nativeKey, budget0, budget1);
        cp.deployTokenId = tokenId;
        (uint160 sl, uint160 su) = _sqrtBounds();
        (uint128 addLiq, uint256 a0,) = zap.exposedPlanLiquidity(cp, sl, su);
        // Native deploy forwards `a0` as msg.value; round-up amounts can exceed the budget.
        vm.deal(address(zap), a0);

        uint256 returnedId = zap.exposedDeployLiquidity(cp, addLiq, a0);

        assertEq(returnedId, tokenId, "same tokenId");
        assertEq(lpm.nextTokenId(), nextBefore, "no new NFT");
        assertEq(lpm.getPositionLiquidity(tokenId), liqBefore + addLiq, "native position grew");
    }
}
