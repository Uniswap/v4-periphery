// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TakingFee} from "../contracts/hooks/examples/TakingFee.sol";
import {TakingFeeImplementation} from "./shared/implementation/TakingFeeImplementation.sol";
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

contract TakingFeeTest is Test, Deployers {
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
    TakingFee takingFee = TakingFee(address(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)));
    PoolId id;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        vm.record();
        TakingFeeImplementation impl = new TakingFeeImplementation(manager, 25, takingFee);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(takingFee), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(takingFee), slot, vm.load(address(impl), slot));
            }
        }

        // key = PoolKey(currency0, currency1, 3000, 60, takingFee);
        (key, id) = initPoolAndAddLiquidity(currency0, currency1, takingFee, 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        token0.approve(address(takingFee), type(uint256).max);
        token1.approve(address(takingFee), type(uint256).max);
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

        uint256 expectedFee = output * TOTAL_BIPS / (TOTAL_BIPS - takingFee.swapFeeBips()) - output;

        assertEq(manager.balanceOf(address(takingFee), CurrencyLibrary.toId(key.currency0)), 0);
        assertEq(manager.balanceOf(address(takingFee), CurrencyLibrary.toId(key.currency1)) / R, expectedFee / R);

        // Swap token0 for exact token1 //
        bool zeroForOne2 = true;
        int256 amountSpecified2 = 1e12; // positive number indicates exact output swap
        BalanceDelta swapDelta2 = swap(key, zeroForOne2, amountSpecified2, ZERO_BYTES);
        // ---------------------------- //

        uint128 input = uint128(-swapDelta2.amount0());
        assertTrue(output > 0);

        uint128 expectedFee2 = (input * takingFee.swapFeeBips()) / (TOTAL_BIPS + takingFee.swapFeeBips());

        assertEq(manager.balanceOf(address(takingFee), CurrencyLibrary.toId(key.currency0)) / R, expectedFee2 / R);
        assertEq(manager.balanceOf(address(takingFee), CurrencyLibrary.toId(key.currency1)) / R, expectedFee / R);

        // test withdrawing tokens //
        Currency[] memory currencies = new Currency[](2);
        currencies[0] = key.currency0;
        currencies[1] = key.currency1;
        takingFee.withdraw(TREASURY, currencies);
        assertEq(manager.balanceOf(address(this), CurrencyLibrary.toId(key.currency0)), 0);
        assertEq(manager.balanceOf(address(this), CurrencyLibrary.toId(key.currency1)), 0);
        assertEq(currency0.balanceOf(TREASURY) / R, expectedFee2 / R);
        assertEq(currency1.balanceOf(TREASURY) / R, expectedFee / R);
    }

    function testEdgeCase() public {
        // Swap exact token0 for token1 //
        bool zeroForOne = true;
        int256 amountSpecified = -1e18;
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        // ---------------------------- //

        uint128 output = uint128(swapDelta.amount1());
        assertTrue(output > 0);

        uint256 expectedFee = output * TOTAL_BIPS / (TOTAL_BIPS - takingFee.swapFeeBips()) - output;

        assertEq(manager.balanceOf(address(takingFee), CurrencyLibrary.toId(key.currency0)), 0);
        assertEq(manager.balanceOf(address(takingFee), CurrencyLibrary.toId(key.currency1)) / R, expectedFee / R);

        // Swap token1 for exact token0 //
        bool zeroForOne2 = false;
        int256 amountSpecified2 = 1e18; // positive number indicates exact output swap
        BalanceDelta swapDelta2 = swap(key, zeroForOne2, amountSpecified2, ZERO_BYTES);
        // ---------------------------- //

        uint128 input = uint128(-swapDelta2.amount1());
        assertTrue(output > 0);

        uint128 expectedFee2 = (input * takingFee.swapFeeBips()) / (TOTAL_BIPS + takingFee.swapFeeBips());

        assertEq(manager.balanceOf(address(takingFee), CurrencyLibrary.toId(key.currency0)), 0);
        assertEq(manager.balanceOf(address(takingFee), CurrencyLibrary.toId(key.currency1)) / R, (expectedFee + expectedFee2) / R);

        // test withdrawing tokens //
        Currency[] memory currencies = new Currency[](2);
        currencies[0] = key.currency0;
        currencies[1] = key.currency1;
        takingFee.withdraw(TREASURY, currencies);
        assertEq(currency0.balanceOf(TREASURY) / R, 0);
        assertEq(currency1.balanceOf(TREASURY) / R, (expectedFee + expectedFee2) / R);
    }
}
