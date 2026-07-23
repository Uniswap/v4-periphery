// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {MarginRouter} from "../src/MarginRouter.sol";
import {IMarginAccount} from "../src/interfaces/IMarginAccount.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {Market} from "../src/types/Market.sol";
import {PositionData} from "../src/types/PositionData.sol";
import {raw} from "../src/types/Ltv.sol";

/// @title RemoveExcessCollateral
/// @notice Withdraws excess collateral from an existing margin position without touching its
///         debt, using the MarginAccount's owner-callable `withdrawCollateral` primitive. The
///         withdrawal amount is sized so the resulting LTV lands on a configured target; the
///         collateral is delivered to the caller's wallet.
/// @dev The lending protocol only enforces its liquidation LTV on withdrawal, so this script is
///      the safety layer: it sizes the withdrawal against TARGET_LTV_BPS and verifies the
///      resulting health afterward.
///      Broadcast example (mainnet, sender must be the margin account owner):
///      forge script script/RemoveExcessCollateral.s.sol:RemoveExcessCollateral
///        --rpc-url $MAINNET_RPC_URL --sender <account owner> --private-key $TRADER_PRIVATE_KEY
///        --broadcast --slow
///      Run without --broadcast first to dry-run. Optional env overrides:
///        MARGIN_ROUTER, LENDING_ADAPTER (default: mainnet deployment, Morpho adapter),
///        COLLATERAL, DEBT (default: WETH collateral, USDC debt), SUB_ID (default 0),
///        TARGET_LTV_BPS (default 8000; the LTV the position is levered back up to),
///        WITHDRAW_WEI (default 0: size automatically from TARGET_LTV_BPS).
contract RemoveExcessCollateral is Script {
    /// @dev Deployed mainnet margin suite (DeployMargin.s.sol broadcast, chain 1).
    address internal constant DEFAULT_MARGIN_ROUTER = 0x0000000004BBC92D0657580CAe35aEBF054E5CDC;
    address internal constant DEFAULT_MORPHO_ADAPTER = 0x9A7f8F5A9496D3c9dc0BEEfb44cCaC17CAAF28fa;

    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    function run() external {
        MarginRouter router = MarginRouter(payable(vm.envOr("MARGIN_ROUTER", DEFAULT_MARGIN_ROUTER)));
        ILendingAdapter adapter = ILendingAdapter(vm.envOr("LENDING_ADAPTER", DEFAULT_MORPHO_ADAPTER));

        uint256 subId = vm.envOr("SUB_ID", uint256(0));
        uint256 targetLtvBps = vm.envOr("TARGET_LTV_BPS", uint256(8000));
        uint256 withdrawWei = vm.envOr("WITHDRAW_WEI", uint256(0));

        Market memory market = Market({
            collateral: Currency.wrap(vm.envOr("COLLATERAL", MAINNET_WETH)),
            debt: Currency.wrap(vm.envOr("DEBT", MAINNET_USDC))
        });

        address account = router.accountOf(msg.sender, subId);
        require(account.code.length != 0, "margin account not deployed for (sender, SUB_ID)");
        require(IMarginAccount(account).owner() == msg.sender, "sender is not the margin account owner");

        PositionData memory before = adapter.describePosition(account, market);
        require(before.collateralAmount > 0, "no collateral to remove");

        uint256 amount = withdrawWei == 0 ? _excessCollateral(before, targetLtvBps) : withdrawWei;
        require(amount > 0, "nothing to withdraw");
        require(amount <= before.collateralAmount, "WITHDRAW_WEI exceeds position collateral");
        // withdrawing everything is only sound with zero debt; Morpho would revert anyway, but
        // fail here with a clear message instead of a protocol health-check revert
        if (before.debtAmount > 0) {
            require(amount < before.collateralAmount, "cannot withdraw all collateral against open debt");
        }

        _logPlan(account, before, amount, targetLtvBps);

        IERC20 collateralToken = IERC20(Currency.unwrap(market.collateral));
        uint256 balanceBefore = collateralToken.balanceOf(msg.sender);

        vm.startBroadcast(msg.sender);
        IMarginAccount(account).withdrawCollateral(adapter, market, amount, msg.sender);
        vm.stopBroadcast();

        PositionData memory afterPos = adapter.describePosition(account, market);
        uint256 received = collateralToken.balanceOf(msg.sender) - balanceBefore;
        require(received == amount, "receiver did not get the withdrawn collateral");
        if (afterPos.debtAmount > 0) {
            require(afterPos.healthFactorWad >= WAD, "position unhealthy after withdrawal");
            if (withdrawWei == 0) {
                require(
                    raw(afterPos.currentLtv) <= targetLtvBps * WAD / BPS, "resulting LTV above target after withdrawal"
                );
            }
        }

        console2.log("withdrawn collateral (wei)", received);
        console2.log("resulting LTV (wad)", raw(afterPos.currentLtv));
        console2.log("resulting health factor (wad)", afterPos.healthFactorWad);
    }

    /// @notice The largest withdrawal that keeps the position's LTV at or under the target.
    /// @dev Removing collateral scales LTV by `collateral / (collateral - x)`, so the excess is
    ///      `collateral * (target - current) / target`, needing no oracle read. Rounds down, so
    ///      the resulting LTV lands at or below the target. With zero debt, everything is excess.
    function _excessCollateral(PositionData memory data, uint256 targetLtvBps) internal pure returns (uint256) {
        if (data.debtAmount == 0) return data.collateralAmount;

        uint256 targetLtvWad = targetLtvBps * WAD / BPS;
        uint256 currentLtvWad = raw(data.currentLtv);
        require(targetLtvWad < raw(data.maxLtv), "TARGET_LTV_BPS at or above the market liquidation LTV");
        require(currentLtvWad < targetLtvWad, "position already at or above target LTV; nothing safe to remove");

        return data.collateralAmount * (targetLtvWad - currentLtvWad) / targetLtvWad;
    }

    function _logPlan(address account, PositionData memory before, uint256 amount, uint256 targetLtvBps) internal pure {
        console2.log("margin account", account);
        console2.log("collateral before (wei)", before.collateralAmount);
        console2.log("debt before", before.debtAmount);
        console2.log("current LTV (wad)", raw(before.currentLtv));
        console2.log("max LTV (wad)", raw(before.maxLtv));
        console2.log("target LTV (bps)", targetLtvBps);
        console2.log("withdrawing (wei)", amount);
    }
}
