// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {FullRange} from "../contracts/hooks/FullRange.sol";
import {FullRangeImplementation} from "./shared/implementation/FullRangeImplementation.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Oracle} from "../contracts/libraries/Oracle.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";

import "forge-std/console.sol";

contract TestFullRange is Test, Deployers {
    event Initialize(
        bytes32 indexed poolId,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        IHooks hooks
    );
    event ModifyPosition(
        bytes32 indexed poolId, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta
    );

    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    TestERC20 token0;
    TestERC20 token1;
    PoolManager manager;
    FullRangeImplementation fullRange =
        FullRangeImplementation(address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG)));
    IPoolManager.PoolKey key;
    bytes32 id;

    PoolModifyPositionTest modifyPositionRouter;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);
        manager = new PoolManager(500000);

        vm.record();
        FullRangeImplementation impl = new FullRangeImplementation(manager, fullRange);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(fullRange), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(fullRange), slot, vm.load(address(impl), slot));
            }
        }
        key = IPoolManager.PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, TICK_SPACING, fullRange
        );
        id = PoolId.toId(key);

        modifyPositionRouter = new PoolModifyPositionTest(manager);

        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        token0.approve(address(modifyPositionRouter), type(uint256).max);
        token1.approve(address(modifyPositionRouter), type(uint256).max);
    }

    function testBeforeInitializeAllowsPoolCreation() public {
        vm.expectEmit(true, true, true, true);
        emit Initialize(PoolId.toId(key), key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
        manager.initialize(key, SQRT_RATIO_1_1);

        // TODO: check that address is in mapping
    }

    function testBeforeInitializeRevertsIfWrongSpacing() public {
        IPoolManager.PoolKey memory wrongKey = IPoolManager.PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, TICK_SPACING + 1, fullRange
        );

        vm.expectRevert("Tick spacing must be default");
        manager.initialize(wrongKey, SQRT_RATIO_1_1);
    }

    function testAddLiquiditySucceeds() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, 12329839823);
    }

    // function testModifyPositionFailsIfNotFullRange() public {
    //     manager.initialize(key, SQRT_RATIO_1_1);
    //     vm.expectRevert("Tick range out of range or not full range");

    //     modifyPositionRouter.modifyPosition(
    //         key, IPoolManager.ModifyPositionParams({tickLower: MIN_TICK + 1, tickUpper: MAX_TICK - 1, liquidityDelta: 100})
    //     );
    // }

    function testBeforeModifyPositionFailsWithWrongMsgSender() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        vm.expectRevert("sender must be hook");

        modifyPositionRouter.modifyPosition(
            key, IPoolManager.ModifyPositionParams({tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: 100})
        );
    }

    // function testBeforeModifyPositionFailsIfNoPool() public {

    // }
}
