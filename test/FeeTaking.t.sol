// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FeeTaking} from "../contracts/hooks/examples/FeeTaking.sol";
import {FeeTakingImplementation} from "./shared/implementation/FeeTakingImplementation.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookEnabledSwapRouter} from "./utils/HookEnabledSwapRouter.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract FeeTakingTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    address constant TREASURY = address(0x1234567890123456789012345678901234567890);
    uint128 private constant TOTAL_BIPS = 10000;

    // rounding for tests to avoid floating point errors
    uint128 R = 10;

    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;
    FeeTaking feeTaking = FeeTaking(address(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)));
    PoolId id;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        vm.record();
        FeeTakingImplementation impl = new FeeTakingImplementation(manager, 25, address(this), feeTaking);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(feeTaking), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(feeTaking), slot, vm.load(address(impl), slot));
            }
        }

        // key = PoolKey(currency0, currency1, 3000, 60, feeTaking);
        (key, id) = initPoolAndAddLiquidity(currency0, currency1, feeTaking, 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        token0.approve(address(feeTaking), type(uint256).max);
        token1.approve(address(feeTaking), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
    }

    function testSwapHooks() public {
        assertEq(currency0.balanceOf(TREASURY), 0);
        assertEq(currency1.balanceOf(TREASURY), 0);

        // Swap exact token0 for token1 //
        bool zeroForOne = true;
        int256 amountSpecified = -1e12;
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        // ---------------------------- //

        uint128 output = uint128(swapDelta.amount1());
        assertTrue(output > 0);

        uint256 expectedFee = output * TOTAL_BIPS / (TOTAL_BIPS - feeTaking.swapFeeBips()) - output;

        assertEq(manager.balanceOf(address(feeTaking), CurrencyLibrary.toId(key.currency0)), 0);
        assertEq(manager.balanceOf(address(feeTaking), CurrencyLibrary.toId(key.currency1)) / R, expectedFee / R);

        // Swap token0 for exact token1 //
        bool zeroForOne2 = true;
        int256 amountSpecified2 = 1e12; // positive number indicates exact output swap
        BalanceDelta swapDelta2 = swap(key, zeroForOne2, amountSpecified2, ZERO_BYTES);
        // ---------------------------- //

        uint128 input = uint128(-swapDelta2.amount0());
        assertTrue(output > 0);

        uint128 expectedFee2 = (input * feeTaking.swapFeeBips()) / (TOTAL_BIPS + feeTaking.swapFeeBips());

        assertEq(manager.balanceOf(address(feeTaking), CurrencyLibrary.toId(key.currency0)) / R, expectedFee2 / R);
        assertEq(manager.balanceOf(address(feeTaking), CurrencyLibrary.toId(key.currency1)) / R, expectedFee / R);

        // test withdrawing tokens //
        Currency[] memory currencies = new Currency[](2);
        currencies[0] = key.currency0;
        currencies[1] = key.currency1;
        feeTaking.withdraw(TREASURY, currencies);
        assertEq(manager.balanceOf(address(feeTaking), CurrencyLibrary.toId(key.currency0)), 0);
        assertEq(manager.balanceOf(address(feeTaking), CurrencyLibrary.toId(key.currency1)), 0);
        assertEq(currency0.balanceOf(TREASURY) / R, expectedFee2 / R);
        assertEq(currency1.balanceOf(TREASURY) / R, expectedFee / R);
    }

    // this would error had the hook not used ERC6909
    function testEdgeCase() public {
        // first, deplete the pool of token1
        // Swap exact token0 for token1 //
        bool zeroForOne = true;
        int256 amountSpecified = -1e18;
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        // ---------------------------- //
        // now, pool only has 1 wei of token1
        uint256 poolToken1 = currency1.balanceOf(address(manager)) - manager.balanceOf(address(feeTaking), CurrencyLibrary.toId(key.currency1));
        assertEq(poolToken1, 1);

        uint128 output = uint128(swapDelta.amount1());
        assertTrue(output > 0);

        uint256 expectedFee = output * TOTAL_BIPS / (TOTAL_BIPS - feeTaking.swapFeeBips()) - output;

        assertEq(manager.balanceOf(address(feeTaking), CurrencyLibrary.toId(key.currency0)), 0);
        assertEq(manager.balanceOf(address(feeTaking), CurrencyLibrary.toId(key.currency1)) / R, expectedFee / R);

        // Swap token1 for exact token0 //
        bool zeroForOne2 = false;
        int256 amountSpecified2 = 1e18; // positive number indicates exact output swap
        BalanceDelta swapDelta2 = swap(key, zeroForOne2, amountSpecified2, ZERO_BYTES);
        // ---------------------------- //

        uint128 input = uint128(-swapDelta2.amount1());
        assertTrue(output > 0);

        uint128 expectedFee2 = (input * feeTaking.swapFeeBips()) / (TOTAL_BIPS + feeTaking.swapFeeBips());

        assertEq(manager.balanceOf(address(feeTaking), CurrencyLibrary.toId(key.currency0)), 0);
        assertEq(
            manager.balanceOf(address(feeTaking), CurrencyLibrary.toId(key.currency1)) / R,
            (expectedFee + expectedFee2) / R
        );

        // test withdrawing tokens //
        Currency[] memory currencies = new Currency[](2);
        currencies[0] = key.currency0;
        currencies[1] = key.currency1;
        feeTaking.withdraw(TREASURY, currencies);
        assertEq(currency0.balanceOf(TREASURY) / R, 0);
        assertEq(currency1.balanceOf(TREASURY) / R, (expectedFee + expectedFee2) / R);
    }
}
