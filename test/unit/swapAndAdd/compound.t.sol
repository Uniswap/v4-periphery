// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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

    function test_WhenMinLiquidityAddedNotMet_Reverts() public {
        // it reverts with {InsufficientLiquidity}
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        _generateFees();
        vm.expectPartialRevert(ISwapAndAdd.InsufficientLiquidity.selector);
        zap.compound(_compoundParams(tokenId, type(uint128).max));
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

    function test_WhenRouteIsNonEmpty_RoutesTheCollectedFees() public {
        // it converts part of the fees through the route and reinvests the result
        uint256 tokenId = _mintPositionViaAdd(0, 10e18);
        uint128 liq0 = lpm.getPositionLiquidity(tokenId);
        _generateFees();

        uint256 snap = vm.snapshotState();
        (,, uint256 a1Base) = zap.compound(_compoundParams(tokenId, 0));
        vm.revertToState(snap);

        _configRoute(10100, a1Base / 2); // convert half the token1 fees at mid+1%
        ISwapAndAdd.CompoundParams memory p = _compoundParams(tokenId, 0);
        p.route = ROUTE_PAYLOAD;

        uint256 routeC1Before = currency1.balanceOf(address(route));
        (uint128 added,,) = zap.compound(p);

        assertGt(added, 0, "fees compounded");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "grew by exactly added");
        assertEq(currency1.balanceOf(address(route)) - routeC1Before, a1Base / 2, "route consumed its declared input");
        _assertZapIdle();
    }

    function test_WhenCompoundSucceeds_EmitsCompounded() public {
        // it emits Compounded whose fields match the return values
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        _generateFees();

        vm.recordLogs();
        (uint128 added, uint256 a0, uint256 a1) = zap.compound(_compoundParams(tokenId, 0));

        Vm.Log memory log = _zapLog();
        assertEq(log.topics[0], ISwapAndAdd.Compounded.selector, "topic0");
        assertEq(log.topics[1], bytes32(uint256(uint160(address(this)))), "indexed resolved recipient");
        assertEq(log.topics[2], bytes32(tokenId), "indexed tokenId");
        (address caller, uint128 eLiq, uint256 e0, uint256 e1) =
            abi.decode(log.data, (address, uint128, uint256, uint256));
        assertEq(caller, address(this), "caller");
        assertEq(eLiq, added, "liquidityAdded mirrors return");
        assertEq(e0, a0, "amount0 mirrors return");
        assertEq(e1, a1, "amount1 mirrors return");
    }
}
