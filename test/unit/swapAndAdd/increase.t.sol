// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";

contract IncreaseTest is BttBase {
    using StateLibrary for IPoolManager;

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

    function test_WhenBudgetIsToken0Only_GrowsSameTokenId() public {
        // it grows the same tokenId from the other single-sided direction
        uint256 tokenId = _mintPositionViaAdd(0, 10e18);
        uint128 liq0 = lpm.getPositionLiquidity(tokenId);

        (uint128 added,,) = zap.increase(_increaseParams(tokenId, 10e18, 0));

        assertGt(added, 0, "liquidity added");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "grew by added");
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

    function test_WhenSpotDriftedOutOfRange_CollectsFeesAndGrows() public {
        // it collects the accrued fees first and still grows the position
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        // a deep wide band, so one push moves spot a controlled distance past the range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: int256(5e21), salt: 0}),
            ""
        );
        _generateFees();
        swap(key, false, -5e21, "");
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertGt(tick, TICK_UPPER, "spot must sit above the range");

        (uint128 added,,) = zap.increase(_increaseParams(tokenId, 0, 5e18));

        assertGt(added, 0, "out-of-range increase grew the position");
        _assertZapIdle();
    }

    function test_WhenBudgetIsZeroAndFeesAccrued_EqualsCompound() public {
        // it reinvests the fees alone, matching compound
        uint256 tokenId = _mintPositionViaAdd(0, 10e18);
        _generateFees();

        uint256 snap = vm.snapshotState();
        (uint128 viaCompound,,) = zap.compound(_compoundParams(tokenId, 0));
        vm.revertToState(snap);

        (uint128 viaIncrease,,) = zap.increase(_increaseParams(tokenId, 0, 0));

        assertGt(viaIncrease, 0, "zero-budget increase reinvested the fees");
        assertEq(viaIncrease, viaCompound, "increase(0,0) equals compound");
    }

    function test_WhenBudgetIsSpentWithFees_ConsumesTheFees() public {
        // it deploys budget and fees together, leaving nothing to compound
        uint256 tokenId = _mintPositionViaAdd(0, 10e18);
        uint128 liq0 = lpm.getPositionLiquidity(tokenId);
        _generateFees();

        (uint128 added,,) = zap.increase(_increaseParams(tokenId, 0, 5e18));

        assertGt(added, 0, "budget and fees deployed");
        assertEq(lpm.getPositionLiquidity(tokenId), liq0 + added, "grew by exactly added");
        vm.expectRevert(ISwapAndAdd.NoFeesToCompound.selector);
        zap.compound(_compoundParams(tokenId, 0));
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

    function test_WhenIncreaseSucceeds_EmitsIncreasedWithResolvedRecipient() public {
        // it emits Increased whose recipient is the resolved one
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        vm.recordLogs();
        (uint128 added, uint256 a0, uint256 a1) = zap.increase(_increaseParams(tokenId, 1e18, 1e18));

        Vm.Log memory log = _zapLog();
        assertEq(log.topics[0], ISwapAndAdd.Increased.selector, "topic0");
        assertEq(log.topics[1], bytes32(uint256(uint160(address(this)))), "indexed resolved recipient");
        assertEq(log.topics[2], bytes32(tokenId), "indexed tokenId");
        (address caller, uint128 eLiq, uint256 e0, uint256 e1) =
            abi.decode(log.data, (address, uint128, uint256, uint256));
        assertEq(caller, address(this), "caller");
        assertEq(eLiq, added, "liquidityAdded mirrors return");
        assertEq(e0, a0, "amount0 mirrors return");
        assertEq(e1, a1, "amount1 mirrors return");
    }

    function test_WhenOperatorIncreases_EventCarriesOwnerAsRecipient() public {
        // it emits Increased with the owner as recipient and the operator as caller
        address operator = makeAddr("operator");
        uint256 tokenId = _mintPositionViaAdd(10e18, 10e18);
        IERC721(address(lpm)).setApprovalForAll(operator, true);
        MockERC20(Currency.unwrap(currency0)).mint(operator, 20e18);
        MockERC20(Currency.unwrap(currency1)).mint(operator, 20e18);
        _approveZapFor(operator, currency0);
        _approveZapFor(operator, currency1);

        ISwapAndAdd.IncreaseParams memory p = _increaseParams(tokenId, 1e18, 1e18);
        p.recipient = operator; // ignored, resolved to the owner
        vm.recordLogs();
        vm.prank(operator);
        zap.increase(p);

        Vm.Log memory log = _zapLog();
        assertEq(log.topics[1], bytes32(uint256(uint160(address(this)))), "recipient resolved to the owner");
        (address caller,,,) = abi.decode(log.data, (address, uint128, uint256, uint256));
        assertEq(caller, operator, "caller is the operator");
    }
}
