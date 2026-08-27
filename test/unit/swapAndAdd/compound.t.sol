// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";

contract CompoundTest is BttBase {
    function test_WhenCallerIsNotAuthorized_Reverts() public {
        // it reverts with {NotAuthorizedForToken}
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.NotAuthorizedForToken.selector, tokenId));
        zap.compound(_compoundParams(tokenId, 0));
    }

    function test_WhenDeadlineHasPassed_Reverts() public {
        // it reverts with {DeadlinePassed}
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        ISwapAndAdd.CompoundParams memory p = _compoundParams(tokenId, 0);
        p.deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.DeadlinePassed.selector, p.deadline));
        zap.compound(p);
    }

    function test_WhenNoFeesAndNoRoute_Reverts() public {
        // it reverts with {NoFeesToCompound}
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        vm.expectRevert(ISwapAndAdd.NoFeesToCompound.selector);
        zap.compound(_compoundParams(tokenId, 0));
    }

    function test_WhenPositionHasAccruedFees_ReinvestsIntoSameTokenId() public {
        // it reinvests fees into the same tokenId and leaves the zap idle
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        uint128 liq0 = lpm.getPositionLiquidity(tokenId);
        _generateFees();

        (uint128 added, uint256 a0, uint256 a1) = zap.compound(_compoundParams(tokenId, 0));

        assertGt(added, 0, "fees reinvested");
        assertGt(a0 + a1, 0, "amounts deployed");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "grew by added");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "owner unchanged");
        _assertZapIdle();
    }

    function test_WhenCallerIsOperator_DustGoesToOwner() public {
        // it forces dust to the owner
        address operator = makeAddr("operator");
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        IERC721(address(lpm)).setApprovalForAll(operator, true);
        _generateFees();

        vm.prank(operator);
        zap.compound(_compoundParams(tokenId, 0));

        assertEq(currency0.balanceOf(operator), 0, "operator got no token0");
        assertEq(currency1.balanceOf(operator), 0, "operator got no token1");
        _assertZapIdle();
    }
}
