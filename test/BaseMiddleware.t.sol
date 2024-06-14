// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FeeTakingLite} from "../contracts/hooks/examples/FeeTakingLite.sol";
import {FeeTakingLiteImplementation} from "./shared/implementation/FeeTakingLiteImplementation.sol";
import {BaseMiddleware} from "../contracts/hooks/examples/BaseMiddleware.sol";
import {BaseMiddlewareImplementation} from "./shared/implementation/BaseMiddlewareImplementation.sol";
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
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {console} from "../../../lib/forge-std/src/console.sol";

contract BaseMiddlewareTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    address constant TREASURY = address(0x1234567890123456789012345678901234567890);
    uint128 private constant TOTAL_BIPS = 10000;

    HookEnabledSwapRouter router;
    TestERC20 token0;
    TestERC20 token1;
    FeeTakingLite feeTakingLite =
        FeeTakingLite(address(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)));
    BaseMiddleware baseMiddleware = BaseMiddleware(
        payable(address(uint160(0x10000000 | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)))
    );
    PoolId id;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        router = new HookEnabledSwapRouter(manager);
        token0 = TestERC20(Currency.unwrap(currency0));
        token1 = TestERC20(Currency.unwrap(currency1));

        console.logAddress(address(manager));

        vm.record();
        FeeTakingLiteImplementation impl0 = new FeeTakingLiteImplementation(manager, feeTakingLite);
        (, bytes32[] memory writes0) = vm.accesses(address(impl0));
        vm.etch(address(feeTakingLite), address(impl0).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes0.length; i++) {
                bytes32 slot = writes0[i];
                vm.store(address(feeTakingLite), slot, vm.load(address(impl0), slot));
            }
        }

        vm.record();
        BaseMiddlewareImplementation impl =
            new BaseMiddlewareImplementation(manager, address(feeTakingLite), baseMiddleware);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(baseMiddleware), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(baseMiddleware), slot, vm.load(address(impl), slot));
            }
        }

        // key = PoolKey(currency0, currency1, 3000, 60, baseMiddleware);
        (key, id) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(baseMiddleware)), 3000, SQRT_PRICE_1_1, ZERO_BYTES
        );

        token0.approve(address(baseMiddleware), type(uint256).max);
        token1.approve(address(baseMiddleware), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
    }

    function testNormal() public {
        console.log("before");
        // Swap exact token0 for token1 //
        bool zeroForOne = true;
        int256 amountSpecified = -1e12;
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        // ---------------------------- //

        uint128 output = uint128(swapDelta.amount1());
        assertTrue(output > 0);

        console.log(output);

        uint256 expectedFee = calculateFeeForExactInput(output, 25);

        assertEq(manager.balanceOf(address(baseMiddleware), CurrencyLibrary.toId(key.currency0)), 0);
        assertEq(manager.balanceOf(address(baseMiddleware), CurrencyLibrary.toId(key.currency1)), expectedFee);

        // // Swap token0 for exact token1 //
        // bool zeroForOne2 = true;
        // int256 amountSpecified2 = 1e12; // positive number indicates exact output swap
        // BalanceDelta swapDelta2 = swap(key, zeroForOne2, amountSpecified2, ZERO_BYTES);
        // // ---------------------------- //

        // uint128 input = uint128(-swapDelta2.amount0());
        // assertTrue(output > 0);

        // uint256 expectedFee2 = calculateFeeForExactOutput(input, 25);

        // assertEq(manager.balanceOf(address(baseMiddleware), CurrencyLibrary.toId(key.currency0)), expectedFee2);
        // assertEq(manager.balanceOf(address(baseMiddleware), CurrencyLibrary.toId(key.currency1)), expectedFee);

        // // test withdrawing tokens //
        // Currency[] memory currencies = new Currency[](2);
        // currencies[0] = key.currency0;
        // currencies[1] = key.currency1;
        // feeTakingLite.withdraw(TREASURY, currencies);
        // assertEq(manager.balanceOf(address(baseMiddleware), CurrencyLibrary.toId(key.currency0)), 0);
        // assertEq(manager.balanceOf(address(baseMiddleware), CurrencyLibrary.toId(key.currency1)), 0);
        // assertEq(currency0.balanceOf(TREASURY), expectedFee2);
        // assertEq(currency1.balanceOf(TREASURY), expectedFee);
    }

    function calculateFeeForExactInput(uint256 outputAmount, uint128 feeBips) internal pure returns (uint256) {
        return outputAmount * TOTAL_BIPS / (TOTAL_BIPS - feeBips) - outputAmount;
    }

    function calculateFeeForExactOutput(uint256 inputAmount, uint128 feeBips) internal pure returns (uint256) {
        return (inputAmount * feeBips) / (TOTAL_BIPS + feeBips);
    }
}
