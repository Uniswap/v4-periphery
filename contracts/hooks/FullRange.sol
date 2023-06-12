// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {IPoolManager} from "@uniswap/core-next/contracts/interfaces/IPoolManager.sol";
import {Pool} from "@uniswap/core-next/contracts/libraries/Pool.sol";
import {Hooks} from "@uniswap/core-next/contracts/libraries/Hooks.sol";
import {BaseHook} from "../BaseHook.sol";

import {IHooks} from "@uniswap/core-next/contracts/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/core-next/contracts/libraries/CurrencyLibrary.sol";
import {TickMath} from "@uniswap/core-next/contracts/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/core-next/contracts/types/BalanceDelta.sol";
import {IERC20Minimal} from "../interfaces/external/IERC20Minimal.sol";
import {ILockCallback} from "../interfaces/callback/ILockCallback.sol";

import "../libraries/LiquidityAmounts.sol";

contract FullRange is BaseHook {
    IPoolManager public immutable poolManager;

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    mapping(poolId => address) poolToERC20;

    struct CallbackData {
        address sender;
        IPoolManager.PoolKey key;
        IPoolManager.ModifyPositionParams params;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        poolManager = _poolManager;
    }

    function modifyPosition(IPoolManager.PoolKey memory key, IPoolManager.ModifyPositionParams memory params)
        external
        payable
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.lock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));

        // do i need this ?
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function lockAcquired(uint256, bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = manager.modifyPosition(data.key, data.params);

        // this does all the transfers
        if (delta.amount0() > 0) {
            if (data.key.currency0.isNative()) {
                manager.settle{value: uint128(delta.amount0())}(data.key.currency0);
            } else {
                IERC20Minimal(Currency.unwrap(data.key.currency0)).transferFrom(
                    data.sender, address(manager), uint128(delta.amount0())
                );
                manager.settle(data.key.currency0);
            }
        }
        if (delta.amount1() > 0) {
            if (data.key.currency1.isNative()) {
                manager.settle{value: uint128(delta.amount1())}(data.key.currency1);
            } else {
                IERC20Minimal(Currency.unwrap(data.key.currency1)).transferFrom(
                    data.sender, address(manager), uint128(delta.amount1())
                );
                manager.settle(data.key.currency1);
            }
        }

        return abi.encode(delta);
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: true,
            afterInitialize: true,
            beforeModifyPosition: true,
            afterModifyPosition: true,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false
        });
    }

    // IPoolManager.PoolKey memory key = IPoolManager.PoolKey({
    //         currency0: currency0,
    //         currency1: currency1,
    //         fee: 3000,
    //         hooks: IHooks(address(0)),
    //         tickSpacing: 60
    //     });
    //     vm.expectRevert();
    //     modifyPositionRouter.modifyPosition(
    //         key, IPoolManager.ModifyPositionParams({tickLower: 0, tickUpper: 60, liquidityDelta: 100})
    //     );

    // replaces the mint function in V3 NonfungiblePositionManager.sol
    // currently it also replaces the addLiquidity function in the supposed LiquidityManagement.sol contract
    // in the future we probably want some of this logic to be called from LiquidityManagement.sol addLiquidity
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint24 fee,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        IPoolManager.PoolKey key = IPoolManager.PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        // replacement addLiquidity function from LiquidityManagement.sol

        Pool.State poolState = poolManager.pools.get(key.toId());
        (uint160 sqrtPriceX96,,) = poolState.slot0();

        // add the hardcoded TICK_LOWER and TICK_UPPER
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(MIN_TICK);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(MAX_TICK);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amountADesired, amountBDesired
        );

        require(liquidity >= 0, "Cannot add negative liquidity to a new position");

        IPoolManager.ModifyPositionParams params =
            IPoolManager.ModifyPositionParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liquidity});

        BalanceDelta delta = modifyPosition(key, params);

        // TODO: price slippage check for v4 deposit
        // require(amountA >= amountAMin && amountB >= params.amountBMin, 'Price slippage check');
    }

    // deploy ERC-20 contract
    function beforeInitialize(address, IPoolManager.PoolKey calldata key, uint160)
        external
        view
        override
        returns (bytes4)
    {
        require(key.tickSpacing == 60, "Tick spacing must be default");

        return FullRange.beforeInitialize.selector;
    }

    function beforeModifyPosition(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params
    ) external view override returns (bytes4) {
        // check pool exists
        require(poolManager.pools.get(key.toId()) != 0, "Pool doesn't exist");

        // check msg.sender
        require(msg.sender == address(this), "msg.sender must be hook");

        // check full range
        require(
            params.tickLower == MIN_TICK && params.tickUpper == MAX_TICK, "Tick range out of range or not full range"
        );

        return FullRange.beforeModifyPosition.selector;
    }

    function afterModifyPosition(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata,
        IPoolManager.BalanceDelta calldata
    ) external view override returns (bytes4) {
        // find the optimal amount of liquidity to transfer
        Pool.State poolState = poolManager.pools.get(key.toId());
        Pool.Slot0 poolSlot0 = poolState.slot0;
        uint128 liquidity = poolState.liquidity;
        uint160 sqrtPriceX96 = poolSlot0.sqrtPriceX96;

        // uint reserveA =
        // uint reserveB = liquidity * sqrtPriceX96;

        // (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
        // if (reserveA == 0 && reserveB == 0) {
        //     (amountA, amountB) = (amountADesired, amountBDesired);
        // } else {
        //     uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
        //     if (amountBOptimal <= amountBDesired) {
        //         require(amountBOptimal >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
        //         (amountA, amountB) = (amountADesired, amountBOptimal);
        //     } else {
        //         uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
        //         assert(amountAOptimal <= amountADesired);
        //         require(amountAOptimal >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
        //         (amountA, amountB) = (amountAOptimal, amountBDesired);
        //     }
        // }

        return FullRange.afterModifyPosition.selector;
    }
}
