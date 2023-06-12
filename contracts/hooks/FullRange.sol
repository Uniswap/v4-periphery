// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {BaseHook} from "../BaseHook.sol";

import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";

import "forge-std/console.sol";

import "../libraries/LiquidityAmounts.sol";

contract FullRange is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolId for IPoolManager.PoolKey;

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    mapping(bytes32 => address) poolToERC20;

    struct CallbackData {
        address sender;
        IPoolManager.PoolKey key;
        IPoolManager.ModifyPositionParams params;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
    }

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'Expired'); 
        _;
            }

    // maybe don't make this function public ?
    function modifyPosition(IPoolManager.PoolKey memory key, IPoolManager.ModifyPositionParams memory params)
        public
        payable
        returns (BalanceDelta delta)
    {
        delta = abi.decode(poolManager.lock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function lockAcquired(uint256, bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = poolManager.modifyPosition(data.key, data.params);

        // this does all the transfers
        if (delta.amount0() > 0) {
            if (data.key.currency0.isNative()) {
                poolManager.settle{value: uint128(delta.amount0())}(data.key.currency0);
            } else {
                IERC20Minimal(Currency.unwrap(data.key.currency0)).transferFrom(
                    data.sender, address(poolManager), uint128(delta.amount0())
                );
                poolManager.settle(data.key.currency0);
            }
        }
        if (delta.amount1() > 0) {
            if (data.key.currency1.isNative()) {
                poolManager.settle{value: uint128(delta.amount1())}(data.key.currency1);
            } else {
                IERC20Minimal(Currency.unwrap(data.key.currency1)).transferFrom(
                    data.sender, address(poolManager), uint128(delta.amount1())
                );
                poolManager.settle(data.key.currency1);
            }
        }

        return abi.encode(delta);
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: true,
            afterInitialize: false,
            beforeModifyPosition: true,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false
        });
    }

    // replaces the mint function in V3 NonfungiblePositionManager.sol
    // currently it also replaces the addLiquidity function in the supposed LiquidityManagement.sol contract
    // in the future we probably want some of this logic to be called from LiquidityManagement.sol addLiquidity
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint24 fee,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 deadline
    ) external ensure(deadline) returns (uint128 liquidity) {
        IPoolManager.PoolKey memory key = IPoolManager.PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        // replacement addLiquidity function from LiquidityManagement.sol
        (uint160 sqrtPriceX96,,) = poolManager.getSlot0(key.toId());

        // add the hardcoded TICK_LOWER and TICK_UPPER
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(MIN_TICK);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(MAX_TICK);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amountADesired, amountBDesired
        );

        // require(liquidity >= 0, "Cannot add negative liquidity to a new position");

        IPoolManager.ModifyPositionParams memory params =
            IPoolManager.ModifyPositionParams({tickLower: MIN_TICK, tickUpper: MAX_TICK, liquidityDelta: int256(int128(liquidity))});

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
        // deploy erc20 contract
        return FullRange.beforeInitialize.selector;
    }

    function beforeModifyPosition(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params
    ) external view override returns (bytes4) {
        // check msg.sender
        console.log(msg.sender);
        console.log(address(this));
        // require(msg.sender == address(this), "msg.sender must be hook");

        // check full range
        require(
            params.tickLower == MIN_TICK && params.tickUpper == MAX_TICK, "Tick range out of range or not full range"
        );

        // minting!!! save gas

        return FullRange.beforeModifyPosition.selector;
    }
}
