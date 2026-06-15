// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {LibClone} from "solady/utils/LibClone.sol";

import {MorphoLendingAdapter} from "../../src/MorphoLendingAdapter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv} from "../../src/types/Ltv.sol";

/// @notice Forks mainnet and exercises MorphoLendingAdapter against the real Morpho Blue WETH/USDC
///         market, validating the accrual-dependent reads that the unit tests could not. All
///         addresses are verified on-chain in setUp (idToMarketParams must match) rather than
///         trusted blindly.
contract MorphoLendingAdapterForkTest is Test {
    using MarketParamsLib for MarketParams;

    // verified on mainnet (see setUp assertions)
    IMorpho internal constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ORACLE = 0xdC6fd5831277c693b1054e19E94047cB37c77615;
    address internal constant IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 internal constant LLTV = 0.86e18;
    uint256 internal constant FORK_BLOCK = 25_319_047;

    MorphoLendingAdapter internal adapter;
    MarginAccount internal account;
    MarketParams internal marketParams;
    Market internal market;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);

        marketParams = MarketParams({loanToken: USDC, collateralToken: WETH, oracle: ORACLE, irm: IRM, lltv: LLTV});
        market = Market({collateral: Currency.wrap(WETH), debt: Currency.wrap(USDC)});

        // verify the market actually exists on Morpho with the expected tokens
        assertEq(MORPHO.idToMarketParams(_id()).collateralToken, WETH, "market collateral");
        assertEq(MORPHO.idToMarketParams(_id()).loanToken, USDC, "market loan token");

        adapter = new MorphoLendingAdapter(MORPHO, address(this));
        adapter.setMarket(marketParams);

        // an account owned and managed by this test, so it can drive the primitives directly
        address impl = address(new MarginAccount());
        account = MarginAccount(
            LibClone.cloneDeterministic(impl, abi.encode(address(this), address(this)), keccak256("fork-acct"))
        );
    }

    function _id() internal view returns (Id) {
        return marketParams.id();
    }

    function test_fork_supplyBorrowReadAndRepay() public {
        // supply 1 WETH of collateral
        deal(WETH, address(account), 1 ether);
        account.supplyCollateral(adapter, market, 1 ether);

        (uint256 collateral, uint256 debt0) = adapter.positionOf(address(account), market);
        assertEq(collateral, 1 ether, "collateral supplied");
        assertEq(debt0, 0, "no debt yet");

        // borrow 1000 USDC to this test, well under the 0.86 LTV cap
        uint256 borrowAmount = 1_000e6;
        account.borrow(adapter, market, borrowAmount, address(this));
        assertEq(IERC20(USDC).balanceOf(address(this)), borrowAmount, "received borrowed USDC");

        (, uint256 debt1) = adapter.positionOf(address(account), market);
        assertApproxEqAbs(debt1, borrowAmount, 10, "accrued debt equals borrow");

        // current LTV is positive and safely under the market max
        Ltv current = adapter.currentLtvWad(address(account), market);
        assertGt(Ltv.unwrap(current), 0, "ltv positive");
        assertLt(Ltv.unwrap(current), LLTV, "ltv under max");

        // accrue interest, then fully unwind. Repay-all by shares clears the borrow shares, so the
        // subsequent full-collateral withdrawal passes Morpho's health check. This is the exact
        // sequence closePosition performs; an asset-denominated repay would leave dust shares and
        // make the withdrawal revert INSUFFICIENT_COLLATERAL.
        vm.warp(block.timestamp + 1 days);
        deal(USDC, address(account), borrowAmount + 10e6);
        account.repay(adapter, market, type(uint256).max);
        (uint256 collateralAfter, uint256 debtAfter) = adapter.positionOf(address(account), market);
        assertEq(debtAfter, 0, "debt fully repaid");

        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        account.withdrawCollateral(adapter, market, collateralAfter, address(this));
        (uint256 collateralEnd,) = adapter.positionOf(address(account), market);
        assertEq(collateralEnd, 0, "all collateral withdrawn after full repay");
        assertEq(IERC20(WETH).balanceOf(address(this)) - wethBefore, collateralAfter, "collateral returned");
    }
}
