// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MarginRouter} from "../src/MarginRouter.sol";
import {IMarginRouter} from "../src/interfaces/IMarginRouter.sol";
import {IMarginAccount} from "../src/interfaces/IMarginAccount.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {Market} from "../src/types/Market.sol";
import {PositionData} from "../src/types/PositionData.sol";
import {raw} from "../src/types/Ltv.sol";

import {RemoveExcessCollateral} from "../script/RemoveExcessCollateral.s.sol";

/// @dev Exposes the script's internal sizing math so the fork test exercises it verbatim.
contract SizingHarness is RemoveExcessCollateral {
    function excess(PositionData memory data, uint256 targetLtvBps) external pure returns (uint256) {
        return _excessCollateral(data, targetLtvBps);
    }
}

/// @notice Mainnet fork test for RemoveExcessCollateral: opens a real position through the
///         deployed MarginRouter, then withdraws the script-sized excess and verifies the
///         resulting LTV lands on target with the collateral delivered to the owner.
contract RemoveExcessCollateralForkTest is Test {
    // Deployed mainnet margin suite (DeployMargin.s.sol broadcast, chain 1).
    MarginRouter constant ROUTER = MarginRouter(payable(0x0000000666Adc6Ecc1A344fDB78F369B64F84444));
    ILendingAdapter constant ADAPTER = ILendingAdapter(0xe32286F0217d7dF340Fbc002d65d65bf1049A8C4);
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 constant WAD = 1e18;
    uint256 constant FORK_BLOCK = 25_547_732;

    address trader = makeAddr("trader");
    Market market;
    PoolKey poolKey;
    SizingHarness harness;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), FORK_BLOCK);

        harness = new SizingHarness();
        market = Market({collateral: Currency.wrap(WETH), debt: Currency.wrap(USDC)});
        poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        // fund and approve: 1 WETH equity pulled via Permit2
        deal(WETH, trader, 1 ether);
        vm.startPrank(trader);
        IERC20(WETH).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(WETH, address(ROUTER), type(uint160).max, type(uint48).max);

        // modest leverage so there is clear excess: buy 0.5 WETH against 1 WETH equity
        ROUTER.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: ADAPTER,
                market: market,
                poolKey: poolKey,
                equity: 1 ether,
                collateralToBuy: 0.5 ether,
                maxDebtIn: 2_000e6, // generous cap; ETH is well under $4000 at the fork block
                minHopPriceX36: 0,
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.stopPrank();
    }

    function test_removeExcessCollateral_landsOnTargetLtv() public {
        address account = ROUTER.accountOf(trader, 0);
        PositionData memory before = ADAPTER.describePosition(account, market);
        assertGt(before.collateralAmount, 0, "position should exist");
        assertGt(before.debtAmount, 0, "position should have debt");
        // 0.5 WETH bought against ~1.5 WETH collateral: LTV well under the 60% target
        uint256 targetLtvBps = 6000;
        assertLt(raw(before.currentLtv), targetLtvBps * WAD / 10_000, "setup LTV should be under target");

        uint256 amount = harness.excess(before, targetLtvBps);
        assertGt(amount, 0, "sizing should find excess");

        uint256 balanceBefore = IERC20(WETH).balanceOf(trader);
        vm.prank(trader);
        IMarginAccount(account).withdrawCollateral(ADAPTER, market, amount, trader);

        PositionData memory afterPos = ADAPTER.describePosition(account, market);
        assertEq(IERC20(WETH).balanceOf(trader) - balanceBefore, amount, "owner receives the collateral");
        assertEq(afterPos.collateralAmount, before.collateralAmount - amount, "collateral reduced by amount");
        assertEq(afterPos.debtAmount, before.debtAmount, "debt untouched");
        assertLe(raw(afterPos.currentLtv), targetLtvBps * WAD / 10_000, "resulting LTV at or under target");
        // rounding puts the result within 1 bps of the target
        assertApproxEqRel(raw(afterPos.currentLtv), targetLtvBps * WAD / 10_000, 1e14, "lands on target");
        assertGe(afterPos.healthFactorWad, WAD, "healthy after withdrawal");
    }

    function test_removeExcessCollateral_zeroDebtWithdrawsAll() public {
        // build a debt-free account state: full close, then re-add collateral only
        address account = ROUTER.accountOf(trader, 0);
        PositionData memory pos = ADAPTER.describePosition(account, market);

        vm.startPrank(trader);
        ROUTER.decreasePosition(
            IMarginRouter.DecreaseParams({
                adapter: ADAPTER,
                market: market,
                poolKey: poolKey,
                debtToRepay: type(uint256).max,
                maxCollateralIn: uint128(pos.collateralAmount),
                minHopPriceX36: 0,
                maxLtvAfter: pos.maxLtv,
                subId: 0,
                deadline: block.timestamp + 1 hours
            })
        );
        ROUTER.addCollateral(
            IMarginRouter.AddCollateralParams({
                adapter: ADAPTER, market: market, amount: 0.25 ether, subId: 0, deadline: block.timestamp + 1 hours
            })
        );
        vm.stopPrank();

        PositionData memory before = ADAPTER.describePosition(account, market);
        assertEq(before.debtAmount, 0, "debt-free state");
        assertEq(harness.excess(before, 6000), before.collateralAmount, "everything is excess with zero debt");

        vm.prank(trader);
        IMarginAccount(account).withdrawCollateral(ADAPTER, market, before.collateralAmount, trader);
        assertEq(ADAPTER.describePosition(account, market).collateralAmount, 0, "fully withdrawn");
    }

    function test_excess_revertsAtOrAboveTarget() public {
        address account = ROUTER.accountOf(trader, 0);
        PositionData memory before = ADAPTER.describePosition(account, market);

        // a target below the current LTV must refuse to size a withdrawal
        uint256 tooLowTargetBps = raw(before.currentLtv) * 10_000 / WAD / 2;
        vm.expectRevert(bytes("position already at or above target LTV; nothing safe to remove"));
        harness.excess(before, tooLowTargetBps);

        vm.expectRevert(bytes("TARGET_LTV_BPS at or above the market liquidation LTV"));
        harness.excess(before, 8600);
    }
}
