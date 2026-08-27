// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";

contract IncreaseTest is BttBase {
    function test_WhenCallerIsNotAuthorized_Reverts() public {
        // it reverts with {NotAuthorizedForToken}
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.NotAuthorizedForToken.selector, tokenId));
        zap.increase(_increaseParams(tokenId, 0, 10e18));
    }

    function test_WhenDeadlineHasPassed_Reverts() public {
        // it reverts with {DeadlinePassed}
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        ISwapAndAdd.IncreaseParams memory p = _increaseParams(tokenId, 0, 10e18);
        p.deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.DeadlinePassed.selector, p.deadline));
        zap.increase(p);
    }

    function test_WhenMinLiquidityAddedNotMet_Reverts() public {
        // it reverts with {InsufficientLiquidity}
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        ISwapAndAdd.IncreaseParams memory p = _increaseParams(tokenId, 0, 10e18);
        p.minLiquidityAdded = type(uint128).max;
        vm.expectRevert();
        zap.increase(p);
    }

    function test_WhenPositionHasLiquidity_GrowsSameTokenId() public {
        // it grows the same tokenId and leaves the zap idle
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        uint128 liq0 = lpm.getPositionLiquidity(tokenId);
        uint256 nextBefore = lpm.nextTokenId();

        (uint128 added, uint256 a0, uint256 a1) = zap.increase(_increaseParams(tokenId, 0, 10e18));

        assertGt(added, 0, "liquidity added");
        assertGt(a0 + a1, 0, "amounts deployed");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "grew by added");
        assertEq(lpm.nextTokenId(), nextBefore, "no new NFT");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "owner unchanged");
        _assertZapIdle();
    }

    function test_WhenPositionIsEmptied_RefillsSameTokenId() public {
        // it refills the same tokenId
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        _emptyPosition(tokenId);
        uint256 nextBefore = lpm.nextTokenId();

        (uint128 added,,) = zap.increase(_increaseParams(tokenId, 5e18, 5e18));

        assertGt(added, 0, "refilled");
        assertEq(lpm.nextTokenId(), nextBefore, "same NFT");
        assertGt(lpm.getPositionLiquidity(tokenId), 0, "liquidity restored");
        _assertZapIdle();
    }

    function test_WhenPoolIsNative_GrowsSameTokenId() public {
        // it grows the same tokenId and leaves the zap idle
        uint256 tokenId = _nativeAdd(1e17);
        _approvePosmForZap();
        uint128 liq0 = lpm.getPositionLiquidity(tokenId);
        uint256 nextBefore = lpm.nextTokenId();

        (uint128 added,,) = zap.increase{value: 1e17}(_increaseParams(tokenId, 1e17, 0));

        assertGt(added, 0, "liquidity added");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "grew by added");
        assertEq(lpm.nextTokenId(), nextBefore, "no new NFT");
        _assertZapIdle();
    }

    function test_WhenCallerIsOperator_DustGoesToOwner() public {
        // it forces dust to the owner
        address operator = makeAddr("operator");
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        IERC721(address(lpm)).setApprovalForAll(operator, true);
        MockERC20(Currency.unwrap(currency1)).mint(operator, 20e18);
        _approveZapFor(operator, currency1);

        vm.prank(operator);
        zap.increase(_increaseParams(tokenId, 0, 10e18));

        assertEq(currency0.balanceOf(operator), 0, "operator got no token0");
        assertEq(currency1.balanceOf(operator), 10e18, "operator kept unspent budget only");
        _assertZapIdle();
    }
}
