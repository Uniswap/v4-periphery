// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";
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

    function test_WhenAdditionalDeltasHaveMixedSigns_PullsOneAndReturnsTheOther() public {
        // it pulls more token0 and returns some token1 in one call
        uint256 tokenId = _mintPositionViaAdd(3e18, 10e18);
        uint256 c1Before = currency1.balanceOf(address(this));

        (uint256 newTokenId, uint128 newLiq,,) = zap.rebalance(_rebalanceParams(tokenId, 2e18, -1e18));

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "owner of the new NFT");
        assertGt(newLiq, 0, "liquidity");
        assertEq(lpm.getPositionLiquidity(tokenId), 0, "old position burned");
        assertGe(currency1.balanceOf(address(this)) - c1Before, 1e18, "recipient received the returned token1");
        _assertZapIdle();
    }

    function test_WhenCallerIsOperator_NewNftAndCashOutGoToOwner() public {
        // it forces the new NFT and the cash-out to the owner
        address operator = makeAddr("operator");
        uint256 tokenId = _mintPositionViaAdd(0, 10e18);
        IERC721(address(lpm)).setApprovalForAll(operator, true);

        ISwapAndAdd.RebalanceParams memory p = _rebalanceParams(tokenId, 0, -1e18); // cash out 1 token1
        p.recipient = operator; // the operator tries to redirect the output
        uint256 opC1Before = currency1.balanceOf(operator);
        uint256 ownerC1Before = currency1.balanceOf(address(this));

        vm.prank(operator);
        (uint256 newTokenId,,,) = zap.rebalance(p);

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "NFT forced to owner");
        assertEq(currency1.balanceOf(operator), opC1Before, "operator received no cash-out");
        assertGe(currency1.balanceOf(address(this)) - ownerC1Before, 1e18, "owner received the cash-out");
        _assertZapIdle();
    }

    function test_WhenOwnerChoosesRecipient_NewNftGoesThere() public {
        // it sends the new NFT to the chosen recipient
        address dest = makeAddr("dest");
        uint256 tokenId = _mintPositionViaAdd(0, 10e18);

        ISwapAndAdd.RebalanceParams memory p = _rebalanceParams(tokenId, 0, 0);
        p.recipient = dest;
        (uint256 newTokenId,,,) = zap.rebalance(p);

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), dest, "owner may choose the recipient");
    }

    function test_WhenPoolIsNative_PositiveDeltaAddsMore() public {
        // it pulls the extra native via msg.value and deploys more
        uint256 tokenId = _nativeAdd(5e17);
        _approvePosmForZap();

        uint256 snap = vm.snapshotState();
        (, uint128 liqBase,,) = zap.rebalance(_rebalanceParams(tokenId, 0, 0));
        vm.revertToState(snap);

        int128 addNative = 1e17;
        (, uint128 liqMore,,) =
            zap.rebalance{value: uint256(uint128(addNative))}(_rebalanceParams(tokenId, addNative, 0));

        assertGt(liqMore, liqBase, "extra native deploys more than a full redeploy");
        _assertZapIdle();
    }

    function test_WhenPoolIsNativeAndValueIsWrong_Reverts() public {
        // it reverts with {InvalidEthValue}
        uint256 tokenId = _nativeAdd(5e17);
        _approvePosmForZap();
        vm.expectRevert(ISwapAndAdd.InvalidEthValue.selector);
        zap.rebalance{value: 1e17 - 1}(_rebalanceParams(tokenId, 1e17, 0));
    }

    function test_WhenRebalanceSucceeds_EmitsRebalancedWithLineage() public {
        // it emits Rebalanced carrying both the old and the new tokenId
        uint256 tokenId = _mintPositionViaAdd(5e18, 5e18);
        vm.recordLogs();
        (uint256 newTokenId, uint128 liq, uint256 a0, uint256 a1) = zap.rebalance(_rebalanceParams(tokenId, 0, 0));

        Vm.Log memory log = _zapLog();
        assertEq(log.topics[0], ISwapAndAdd.Rebalanced.selector, "topic0");
        assertEq(log.topics[1], bytes32(uint256(uint160(address(this)))), "indexed recipient");
        assertEq(log.topics[2], bytes32(tokenId), "indexed oldTokenId");
        assertEq(log.topics[3], bytes32(newTokenId), "indexed newTokenId");
        (address caller, uint128 eLiq, uint256 e0, uint256 e1) =
            abi.decode(log.data, (address, uint128, uint256, uint256));
        assertEq(caller, address(this), "caller");
        assertEq(eLiq, liq, "liquidity mirrors return");
        assertEq(e0, a0, "amount0 mirrors return");
        assertEq(e1, a1, "amount1 mirrors return");
    }
}
