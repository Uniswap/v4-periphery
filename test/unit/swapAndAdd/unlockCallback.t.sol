// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";

contract UnlockCallbackTest is BttBase {
    function test_WhenDeployTokenIdIsZero_DoesNotCollectFees() public {
        // it does not collect fees and proceeds to swapAndAdd
        uint256 nextBefore = lpm.nextTokenId();
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(5e18, 5e18));
        assertEq(tokenId, nextBefore, "minted next id");
        assertGt(liq, 0, "liquidity minted");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT transferred to recipient");
        _assertZapIdle();
    }

    modifier givenDeployTokenIdIsNonZero() {
        _;
    }

    function test_WhenPositionLiquidityIsZero_SkipsFeeCollect() public givenDeployTokenIdIsNonZero {
        // it skips the fee-collect decrease
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        _emptyPosition(tokenId);
        uint256 nextBefore = lpm.nextTokenId();

        (uint128 added,,) = zap.increase(_increaseParams(tokenId, 5e18, 5e18));

        assertGt(added, 0, "emptied position refilled");
        assertEq(lpm.nextTokenId(), nextBefore, "same tokenId");
        assertGt(lpm.getPositionLiquidity(tokenId), 0, "liquidity restored");
        _assertZapIdle();
    }

    function test_WhenPositionLiquidityIsNonZero_CollectsFees() public givenDeployTokenIdIsNonZero {
        // it collects fees into the budget
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        uint128 liqBefore = lpm.getPositionLiquidity(tokenId);
        _generateFees();

        (uint128 added,,) = zap.compound(_compoundParams(tokenId, 0));

        assertGt(added, 0, "fees reinvested");
        assertEq(lpm.getPositionLiquidity(tokenId), liqBefore + added, "grew by collected fees");
        _assertZapIdle();
    }

    function test_WhenNoBudgetAndNoRoute_RevertsNoFeesToCompound() public givenDeployTokenIdIsNonZero {
        // it reverts with {NoFeesToCompound}
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        _emptyPosition(tokenId);
        vm.expectRevert(ISwapAndAdd.NoFeesToCompound.selector);
        zap.compound(_compoundParams(tokenId, 0));
    }
}
