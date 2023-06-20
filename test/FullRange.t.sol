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
import {UniswapV4ERC20} from "../contracts/hooks/UniswapV4ERC20.sol";

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
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
    }

    function testBeforeInitializeAllowsPoolCreation() public {
        vm.expectEmit(true, true, true, true);
        emit Initialize(PoolId.toId(key), key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks);
        manager.initialize(key, SQRT_RATIO_1_1);

        // check that address is in mapping
        assertFalse(fullRange.poolToERC20(PoolId.toId(key)) == address(0));
    }

    function testBeforeInitializeRevertsIfWrongSpacing() public {
        IPoolManager.PoolKey memory wrongKey = IPoolManager.PoolKey(
            Currency.wrap(address(token0)), Currency.wrap(address(token1)), 0, TICK_SPACING + 1, fullRange
        );

        vm.expectRevert("Tick spacing must be default");
        manager.initialize(wrongKey, SQRT_RATIO_1_1);
    }

    function testInitialAddLiquiditySucceeds() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 100);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 100);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 100);
    }

    function testAddLiquidityFailsIfNoPool() public {
        // PoolNotInitialized()
        vm.expectRevert(0x486aa307);
        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);
    }

    function testAddLiquiditySucceedsWithNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 100);

        fullRange.addLiquidity(address(token0), address(token1), 0, 50, 50, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 150);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 150);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 150);
    }

    function testAddLiquidityWithDiffRatiosAndNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 100);

        fullRange.addLiquidity(address(token0), address(token1), 0, 50, 25, address(this), 12329839823);

        // evem though we desire to deposit more token0, we cannot, since the ratio is 1:1
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 125);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 125);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 125);
    }

    function testInitialRemoveLiquiditySucceeds() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 100);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 100);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 100);

        // approve fullRange to spend our liquidity tokens
        UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 0, 100, 0, 0, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 0);
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 1);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 1);
    }

    function testRemoveLiquidityFailsIfNoPool() public {
        // PoolNotInitialized()
        vm.expectRevert(0x486aa307);
        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);
    }

    function testRemoveLiquiditySucceedsWithNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 100);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 100);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 100);

        fullRange.addLiquidity(address(token0), address(token1), 0, 50, 50, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 150);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 150);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 150);

        UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 0, 150, 0, 0, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 0);
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 1);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 1);
    }

    function testRemoveLiquiditySucceedsWithPartial() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 100);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 100);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 100);

        UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 0, 50, 0, 0, address(this), 12329839823);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 50);
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 51);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 51);
    }

    function testRemoveLiquidityWithDiffRatiosAndNoFee() public {
        manager.initialize(key, SQRT_RATIO_1_1);

        uint256 currBalance0 = TestERC20(token0).balanceOf(address(this));
        uint256 currBalance1 = TestERC20(token1).balanceOf(address(this));

        fullRange.addLiquidity(address(token0), address(token1), 0, 100, 100, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 100);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 100);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 100);

        fullRange.addLiquidity(address(token0), address(token1), 0, 50, 25, address(this), 12329839823);

        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 125);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 125);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 125);

        UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(address(token0), address(token1), 0, 50, 0, 0, address(this), 12329839823);

        // TODO: balance checks for token0 and token1
        assertEq(TestERC20(token0).balanceOf(address(this)), currBalance0 - 76);
        assertEq(TestERC20(token1).balanceOf(address(this)), currBalance1 - 76);

        assertEq(UniswapV4ERC20(fullRange.poolToERC20(PoolId.toId(key))).balanceOf(address(this)), 75);
    }

    // this test is never called
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
}
