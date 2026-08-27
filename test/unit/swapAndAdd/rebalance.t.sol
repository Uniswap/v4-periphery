// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";

contract RebalanceTest is BttBase {
    function test_WhenCallerIsNotAuthorized_Reverts() public {
        // it reverts with {NotAuthorizedForToken}
        uint256 tokenId = _mintPositionViaAdd(0, 10e18);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.NotAuthorizedForToken.selector, tokenId));
        zap.rebalance(_rebalanceParams(tokenId, 0, 0));
    }

    function test_WhenDeadlineHasPassed_Reverts() public {
        // it reverts with {DeadlinePassed}
        uint256 tokenId = _mintPositionViaAdd(0, 10e18);
        ISwapAndAdd.RebalanceParams memory p = _rebalanceParams(tokenId, 0, 0);
        p.deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.DeadlinePassed.selector, p.deadline));
        zap.rebalance(p);
    }

    function test_WhenAdditionalDeltaExceedsWithdrawn_Reverts() public {
        // it reverts with {ReturnExceedsWithdrawn}
        uint256 tokenId = _mintPositionViaAdd(0, 10e18);
        vm.expectRevert();
        zap.rebalance(_rebalanceParams(tokenId, 0, type(int128).min));
    }

    function test_WhenAdditionalDeltasAreZero_MintsNewRange() public {
        // it burns the old NFT, mints a new range, and leaves the zap idle
        uint256 tokenId = _mintPositionViaAdd(0, 10e18);
        (uint256 newTokenId, uint128 liq,,) = zap.rebalance(_rebalanceParams(tokenId, 0, 0));
        assertTrue(newTokenId != tokenId, "new NFT");
        assertGt(liq, 0, "liquidity");
        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "owner of new NFT");
        _assertZapIdle();
    }

    function test_WhenAdditionalDeltasAreNegative_CashesOut() public {
        // it cashes out to the owner
        uint256 tokenId = _mintPositionViaAdd(5e18, 5e18);
        uint256 c0Before = currency0.balanceOf(address(this));
        int128 cashOut0 = -1e17;
        zap.rebalance(_rebalanceParams(tokenId, cashOut0, 0));
        assertGt(currency0.balanceOf(address(this)), c0Before, "token0 cashed out");
        _assertZapIdle();
    }

    function test_WhenAdditionalDeltasArePositive_DeploysMore() public {
        // it deploys more liquidity than a full redeploy
        uint256 tokenId = _mintPositionViaAdd(5e18, 5e18);
        uint256 snap = vm.snapshotState();
        (, uint128 liqBase,,) = zap.rebalance(_rebalanceParams(tokenId, 0, 0));
        vm.revertToState(snap);

        (, uint128 liqMore,,) = zap.rebalance(_rebalanceParams(tokenId, 1e18, 1e18));
        assertGt(liqMore, liqBase, "positive delta deploys more");
        _assertZapIdle();
    }

    function test_WhenCallerIsOperator_NewNftGoesToOwner() public {
        // it forces the new NFT to the owner
        address operator = makeAddr("operator");
        uint256 tokenId = _mintPositionViaAdd(0, 10e18);
        IERC721(address(lpm)).setApprovalForAll(operator, true);

        ISwapAndAdd.RebalanceParams memory p = _rebalanceParams(tokenId, 0, 0);
        p.recipient = operator;
        vm.prank(operator);
        (uint256 newTokenId,,,) = zap.rebalance(p);

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "NFT forced to owner");
        _assertZapIdle();
    }
}
