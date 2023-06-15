// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {BaseHook} from "../BaseHook.sol";

import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {UniswapV4ERC20} from "./UniswapV4ERC20.sol";
import {IUniswapV4ERC20} from "./IUniswapV4ERC20.sol";
import {SafeMath} from "./SafeMath.sol";
import {Math} from "./Math.sol";

import "forge-std/console.sol";

import "../libraries/LiquidityAmounts.sol";

contract FullRange is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolId for IPoolManager.PoolKey;

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    uint public constant MINIMUM_LIQUIDITY = 10**3;

    mapping(bytes32 => address) public poolToERC20;

    struct CallbackData {
        address sender;
        IPoolManager.PoolKey key;
        IPoolManager.ModifyPositionParams params;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "Expired");
        _;
    }

    // maybe don't make this function public ?
    function modifyPosition(IPoolManager.PoolKey memory key, IPoolManager.ModifyPositionParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        console.log("msg.sender of modifyPosition");
        console.log(msg.sender);

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
        } else {
            if (data.key.currency0.isNative()) {
                poolManager.settle{value: uint128(delta.amount0())}(data.key.currency0);
            } else {
                IERC20Minimal(Currency.unwrap(data.key.currency0)).transferFrom(
                    address(poolManager), data.sender, uint128(delta.amount0())
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
        } else {
            // TODO: fix the native code here maybe 
            // TODO: data.sender is the hook, so how are the tests passing?
            if (data.key.currency1.isNative()) {
                poolManager.settle{value: uint128(delta.amount1())}(data.key.currency1);
            } else {
                IERC20Minimal(Currency.unwrap(data.key.currency1)).transferFrom(
                    address(poolManager), data.sender, uint128(delta.amount1())
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
        address to,
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

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // add the hardcoded TICK_LOWER and TICK_UPPER
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(MIN_TICK);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(MAX_TICK);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, amountADesired, amountBDesired
        );

        uint depositedLiquidity;
        uint128 poolLiquidity = poolManager.getLiquidity(key.toId());

        console.log("poolLiquidity");
        console.log(poolLiquidity);

        UniswapV4ERC20 erc20 = UniswapV4ERC20(poolToERC20[key.toId()]);

        // delta amounts 
        uint256 amount0 = LiquidityAmounts.getAmount0ForLiquidity(sqrtPriceX96, sqrtRatioBX96, liquidity);
        uint256 amount1 = LiquidityAmounts.getAmount1ForLiquidity(sqrtRatioAX96, sqrtPriceX96, liquidity);
        
        // if (poolLiquidity == 0) {
        //     // uint256 sqrtLiquidityDelta = Math.sqrt(amount0 * amount1);
        //     // depositedLiquidity = SafeMath.sub(liquidity, MINIMUM_LIQUIDITY);
        //     // erc20._mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens

        //     depositedLiquidity = liquidity;
        // } else {
        //     // we are not considering if sqrtRatioX96 == the min and max yet 
            
        //     // // delta liquidity 
        //     // uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtRatioBX96, amount0);
        //     // uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(sqrtRatioAX96, sqrtPriceX96, amount1);
            
        //     // total amounts
        //     uint256 amount0Total = LiquidityAmounts.getAmount0ForLiquidity(sqrtPriceX96, sqrtRatioBX96, poolLiquidity);
        //     uint256 amount1Total = LiquidityAmounts.getAmount1ForLiquidity(sqrtRatioAX96, sqrtPriceX96, poolLiquidity);

        //     // if (liquidity0 < liquidity1) {
        //     //     require(liquidity0 == liquidity, "liquidity must match");
        //     //     depositedLiquidity = FullMath.mulDiv(liquidity,(sqrtRatioBX96 - sqrtRatioAX96), amount0Total); 
        //     // } else {
        //     //     require(liquidity1 == liquidity, "liquidity must match");
        //     //     depositedLiquidity = FullMath.mulDiv(liquidity,(sqrtRatioBX96 - sqrtRatioAX96), amount1Total); 
        //     // }

        //     depositedLiquidity = Math.min(FullMath.mulDiv(amount0, poolLiquidity, amount0Total), FullMath.mulDiv(amount1, poolLiquidity, amount1Total));
        // }

        // require(liquidity >= 0, "Cannot add negative liquidity to a new position");

        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams({
            tickLower: MIN_TICK,
            tickUpper: MAX_TICK,
            liquidityDelta: int256(int128(liquidity))
        });

        modifyPosition(key, params);

        // TODO: price slippage check for v4 deposit
        // require(amountA >= amountAMin && amountB >= params.amountBMin, 'Price slippage check');

        // mint
        erc20._mint(to, liquidity);

    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint24 fee,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual ensure(deadline) returns (uint amountA, uint amountB) {
        IPoolManager.PoolKey memory key = IPoolManager.PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        (uint160 sqrtPriceX96,,) = poolManager.getSlot0(key.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // transfer liquidity tokens to erc20 contract
        UniswapV4ERC20 erc20 = UniswapV4ERC20(poolToERC20[key.toId()]);
        erc20.transferFrom(msg.sender, address(erc20), liquidity);

        IPoolManager.ModifyPositionParams memory params = IPoolManager.ModifyPositionParams({
            tickLower: MIN_TICK,
            tickUpper: MAX_TICK,
            liquidityDelta: -int256(liquidity)
        });

        BalanceDelta balanceDelta = modifyPosition(key, params);

        // transfers should be done in lockAcquired
        // CurrencyLibrary.transfer(Currency.wrap(tokenA), to, uint256(uint128(BalanceDeltaLibrary.amount0(balanceDelta))));
        // CurrencyLibrary.transfer(Currency.wrap(tokenB), to, uint256(uint128(BalanceDeltaLibrary.amount1(balanceDelta))));

        // collect rewards - or just have that dealt with in lock as well
    }

    // deploy ERC-20 contract
    function beforeInitialize(address, IPoolManager.PoolKey calldata key, uint160)
        external
        override
        returns (bytes4)
    {
        require(key.tickSpacing == 60, "Tick spacing must be default");
        
        // deploy erc20 contract

        bytes memory bytecode = type(UniswapV4ERC20).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(key.toId()));

        address poolToken; 
        assembly {
            poolToken := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        
        poolToERC20[key.toId()] = poolToken;

        return FullRange.beforeInitialize.selector;
    }

    function beforeModifyPosition(
        address sender,
        IPoolManager.PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params
    ) external override returns (bytes4) {
        // check msg.sender
        require(sender == address(this), "sender must be hook");

        // check full range
        require(
            params.tickLower == MIN_TICK && params.tickUpper == MAX_TICK, "Tick range out of range or not full range"
        );

        return FullRange.beforeModifyPosition.selector;
    }
}
