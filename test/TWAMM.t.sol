pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {TWAMMImplementation} from "./shared/implementation/TWAMMImplementation.sol";
import {TWAMMHook} from "../../contracts/hooks/TWAMMHook.sol";
import {ITWAMM} from "../../contracts/interfaces/ITWAMM.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/contracts/test/PoolDonateTest.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";

contract TWAMMTest is Test, Deployers {
    using PoolId for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    // address constant twammHookAddr = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG));
    TWAMMHook twamm = TWAMMHook(
        address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG))
    );
    // TWAMMHook twamm;
    PoolManager manager;
    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter;
    PoolDonateTest donateRouter;
    address hookAddress;
    TestERC20 token0;
    TestERC20 token1;
    IPoolManager.PoolKey poolKey;
    bytes32 id;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);
        manager = new PoolManager(500000);

        TWAMMImplementation impl = new TWAMMImplementation(manager, 10_000, twamm);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(twamm), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(twamm), slot, vm.load(address(impl), slot));
            }
        }

        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));

        poolKey = IPoolManager.PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, twamm);
        id = PoolId.toId(poolKey);
        manager.initialize(poolKey, SQRT_RATIO_1_1);

        token0.approve(address(modifyPositionRouter), 100 ether);
        token1.approve(address(modifyPositionRouter), 100 ether);
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-60, 60, 10 ether));
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-120, 120, 10 ether));
        modifyPositionRouter.modifyPosition(
            poolKey, IPoolManager.ModifyPositionParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether)
        );
    }

    function newPoolKeyWithTWAMM(IHooks hooks) public returns (IPoolManager.PoolKey memory, bytes32) {
        TestERC20[] memory tokens = deployTokens(2, 2 ** 255);
        IPoolManager.PoolKey memory key =
            IPoolManager.PoolKey(Currency.wrap(address(tokens[0])), Currency.wrap(address(tokens[1])), 0, 60, hooks);
        return (key, key.toId());
    }

    function testTWAMMbeforeInitializeInitializesTWAMM() public {
        (IPoolManager.PoolKey memory initKey, bytes32 initId) = newPoolKeyWithTWAMM(twamm);
        assertEq(twamm.lastVirtualOrderTimestamp(initId), 0);
        vm.warp(10000);
        manager.initialize(initKey, SQRT_RATIO_1_1);
        assertEq(twamm.lastVirtualOrderTimestamp(initId), 10000);
    }

    function testTWAMMSubmitLTOStoresOrderUnderCorrectPool() public {
        ITWAMM.OrderKey memory orderKey = ITWAMM.OrderKey(address(this), 30000, true);

        ITWAMM.Order memory nullOrder = twamm.getOrder(poolKey, orderKey);
        assertEq(nullOrder.sellRate, 0);
        assertEq(nullOrder.earningsFactorLast, 0);

        token0.approve(address(twamm), 100 ether);
        vm.warp(10000);
        twamm.submitOrder(poolKey, orderKey, 1 ether);

        ITWAMM.Order memory submittedOrder = twamm.getOrder(poolKey, orderKey);
        assertEq(submittedOrder.sellRate, 1 ether / 20000);
        assertEq(submittedOrder.earningsFactorLast, 0);
    }

    function TWAMMSingleSellFailing() public {
        // TODO: fails with a bug for single pool sell, swap amount 3 wei above balance.
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 40000, true);

        token0.approve(address(twamm), 100e18);
        token1.approve(address(twamm), 100e18);
        vm.warp(10000);
        twamm.submitOrder(poolKey, orderKey1, 1e18);
        vm.warp(30000);
        token0.approve(address(twamm), 100e18);
        twamm.submitOrder(poolKey, orderKey2, 1e18);
        vm.warp(40000);

        ITWAMM.Order memory submittedOrder = twamm.getOrder(poolKey, orderKey2);
        (, uint256 earningsFactorCurrent) = twamm.getOrderPool(poolKey, true);
        assertEq(submittedOrder.sellRate, 1 ether / 10000);
        assertEq(submittedOrder.earningsFactorLast, earningsFactorCurrent);
    }

    function testTWAMMOrderStoresEarningsFactorLast() public {
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 40000, true);
        ITWAMM.OrderKey memory orderKey3 = ITWAMM.OrderKey(address(this), 40000, false);

        token0.approve(address(twamm), 100e18);
        token1.approve(address(twamm), 100e18);
        vm.warp(10000);
        twamm.submitOrder(poolKey, orderKey1, 1e18);
        twamm.submitOrder(poolKey, orderKey3, 10e18);
        vm.warp(30000);
        token0.approve(address(twamm), 100e18);
        twamm.submitOrder(poolKey, orderKey2, 1e18);
        vm.warp(40000);

        ITWAMM.Order memory submittedOrder = twamm.getOrder(poolKey, orderKey2);
        (, uint256 earningsFactorCurrent) = twamm.getOrderPool(poolKey, true);
        assertEq(submittedOrder.sellRate, 1 ether / 10000);
        assertEq(submittedOrder.earningsFactorLast, earningsFactorCurrent);
    }

    event SubmitOrder(
        bytes32 indexed poolId,
        address indexed owner,
        uint160 expiration,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast
    );

    function testTWAMMSubmitOrderEmitsEvent() public {
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);

        token0.approve(address(twamm), 100e18);
        vm.warp(10000);

        vm.expectEmit(false, false, false, true);
        emit SubmitOrder(id, address(this), 30000, true, 1 ether / 20000, 0);
        twamm.submitOrder(poolKey, orderKey1, 1e18);
    }

    function testTWAMMEndToEndSimEvenTradingGas() public {
        uint256 orderAmount = 1e18;
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 30000, false);

        token0.approve(address(twamm), 100e18);
        token1.approve(address(twamm), 100e18);
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-2400, 2400, 10 ether));

        vm.warp(10000);
        twamm.submitOrder(poolKey, orderKey1, orderAmount);
        twamm.submitOrder(poolKey, orderKey2, orderAmount);
        vm.warp(20000);
        twamm.executeTWAMMOrders(poolKey);
        twamm.updateOrder(poolKey, orderKey1, 0);
        twamm.updateOrder(poolKey, orderKey2, 0);

        uint256 earningsToken0 = twamm.tokensOwed(poolKey.currency0, address(this));
        uint256 earningsToken1 = twamm.tokensOwed(poolKey.currency1, address(this));

        assertEq(earningsToken0, orderAmount / 2);
        assertEq(earningsToken1, orderAmount / 2);

        uint256 balance0BeforeTWAMM = TestERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(twamm));
        uint256 balance1BeforeTWAMM = TestERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(twamm));
        uint256 balance0BeforeThis = poolKey.currency0.balanceOfSelf();
        uint256 balance1BeforeThis = poolKey.currency1.balanceOfSelf();

        vm.warp(30000);
        twamm.executeTWAMMOrders(poolKey);
        twamm.updateOrder(poolKey, orderKey1, 0);
        twamm.updateOrder(poolKey, orderKey2, 0);
        twamm.claimTokens(poolKey.currency0, address(this), 0);
        twamm.claimTokens(poolKey.currency1, address(this), 0);

        uint256 balance0AfterTWAMM = TestERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(twamm));
        uint256 balance1AfterTWAMM = TestERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(twamm));
        uint256 balance0AfterThis = poolKey.currency0.balanceOfSelf();
        uint256 balance1AfterThis = poolKey.currency1.balanceOfSelf();

        assertEq(balance1AfterTWAMM, 0);
        assertEq(balance0AfterTWAMM, 0);
        assertEq(balance0BeforeTWAMM - balance0AfterTWAMM, orderAmount);
        assertEq(balance0AfterThis - balance0BeforeThis, orderAmount);
        assertEq(balance1BeforeTWAMM - balance1AfterTWAMM, orderAmount);
        assertEq(balance1AfterThis - balance1BeforeThis, orderAmount);
    }
}
