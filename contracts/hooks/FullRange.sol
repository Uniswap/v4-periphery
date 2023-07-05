// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {BaseHook} from "../BaseHook.sol";

import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {UniswapV4ERC20} from "./UniswapV4ERC20.sol";
import {IUniswapV4ERC20} from "./IUniswapV4ERC20.sol";
import {SafeMath} from "./SafeMath.sol";
import {Math} from "./Math.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import "@uniswap/v4-core/contracts/libraries/FixedPoint128.sol";

import "forge-std/console.sol";

import "../libraries/LiquidityAmounts.sol";

contract FullRange is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for IPoolManager.PoolKey;

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;

    struct CallbackData {
        address sender;
        IPoolManager.PoolKey key;
        IPoolManager.ModifyPositionParams params;
        bool rebalance;
    }

    struct PoolInfo {
        uint128 liquidity;
        // the fee growth of the aggregate position as of the last action on the individual position
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // how many uncollected tokens are owed to the position, as of the last computation
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        uint256 blockNumber;
        address liquidityToken;
    }

    mapping(PoolId => PoolInfo) public poolToInfo;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "Expired");
        _;
    }

    function balanceOf(Currency currency, address user) internal view returns (uint256) {
        if (currency.isNative()) {
            return user.balance;
        } else {
            return IERC20Minimal(Currency.unwrap(currency)).balanceOf(user);
        }
    }

    function modifyPosition(IPoolManager.PoolKey memory key, IPoolManager.ModifyPositionParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        // msg.sender is the test contract (aka whoever called addLiquidity/removeLiquidity)

        delta = abi.decode(poolManager.lock(abi.encode(CallbackData(msg.sender, key, params, false))), (BalanceDelta));

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function hookModifyPosition(IPoolManager.PoolKey memory key, IPoolManager.ModifyPositionParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        IERC20Minimal(Currency.unwrap(key.currency0)).approve(address(this), type(uint256).max);
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(address(this), type(uint256).max);

        delta = abi.decode(poolManager.lock(abi.encode(CallbackData(address(this), key, params, true))), (BalanceDelta));

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function lockAcquired(uint256, bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = poolManager.modifyPosition(data.key, data.params);

        // check if we are inputting liquidity for token0
        if (delta.amount0() > 0) {
            if (data.key.currency0.isNative()) {
                poolManager.settle{value: uint128(delta.amount0())}(data.key.currency0);
            } else {
                IERC20Minimal(Currency.unwrap(data.key.currency0)).transferFrom(
                    data.sender, address(poolManager), uint128(delta.amount0())
                );
                poolManager.settle(data.key.currency0);
            }
            // withdrawing liquidity for token0
        } else {
            // if withdrawing is because of rebalance
            if (data.rebalance) {
                poolManager.take(data.key.currency0, data.sender, uint256(uint128(-delta.amount0())));

                // NOTE: even though we've taken all of the tokens we're owed, we don't set position.tokensOwed to 0
                // since we need to reinvest into the pool
                // after reinvestment, we should set the tokens owed to 0
            } else {
                poolManager.take(data.key.currency0, data.sender, uint256(uint128(-delta.amount0())));

                // NOTE: commented out because we are never adding the liquidity being taken out to the tokensOwed.
                // position.tokensOwed0 -= delta.amount0();
            }

            if (data.key.currency0.isNative()) {
                poolManager.settle{value: uint128(-delta.amount0())}(data.key.currency0);
            } else {
                poolManager.settle(data.key.currency0);
            }
        }

        // check if we are inputting liquidity for token1
        if (delta.amount1() > 0) {
            if (data.key.currency1.isNative()) {
                poolManager.settle{value: uint128(delta.amount1())}(data.key.currency1);
            } else {
                IERC20Minimal(Currency.unwrap(data.key.currency1)).transferFrom(
                    data.sender, address(poolManager), uint128(delta.amount1())
                );
                poolManager.settle(data.key.currency1);
            }
            // withdrawing liquidity for token1
        } else {
            // withdrawing is because of rebalance
            if (data.rebalance) {
                poolManager.take(data.key.currency1, data.sender, uint256(uint128(-delta.amount1())));
            } else {
                poolManager.take(data.key.currency1, data.sender, uint128(-delta.amount1()));

                // NOTE: commented out because we are never adding the liquidity being taken out to the tokensOwed.
                // position.tokensOwed1 -= delta.amount1();
            }

            if (data.key.currency1.isNative()) {
                poolManager.settle{value: uint128(-delta.amount1())}(data.key.currency1);
            } else {
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
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false
        });
    }

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
        (uint160 sqrtPriceX96,,,,,) = poolManager.getSlot0(key.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(MIN_TICK),
            TickMath.getSqrtRatioAtTick(MAX_TICK),
            amountADesired,
            amountBDesired
        );

        modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: int256(int128(liquidity))
            })
        );

        // NOTE: we've already done the rebalance here

        Position.Info memory posInfo = poolManager.getPosition(key.toId(), address(this), MIN_TICK, MAX_TICK);

        PoolInfo storage poolInfo = poolToInfo[key.toId()];

        poolInfo.tokensOwed0 += uint128(
            FullMath.mulDiv(
                posInfo.feeGrowthInside0LastX128 - poolInfo.feeGrowthInside0LastX128,
                poolInfo.liquidity,
                FixedPoint128.Q128
            )
        );
        poolInfo.tokensOwed1 += uint128(
            FullMath.mulDiv(
                posInfo.feeGrowthInside1LastX128 - poolInfo.feeGrowthInside1LastX128,
                poolInfo.liquidity,
                FixedPoint128.Q128
            )
        );

        poolInfo.feeGrowthInside0LastX128 = posInfo.feeGrowthInside0LastX128;
        poolInfo.feeGrowthInside1LastX128 = posInfo.feeGrowthInside1LastX128;
        poolInfo.liquidity += liquidity;

        // TODO: price slippage check for v4 deposit
        // require(amountA >= amountAMin && amountB >= params.amountBMin, 'Price slippage check');

        // mint
        UniswapV4ERC20(poolInfo.liquidityToken)._mint(to, liquidity);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint24 fee,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public virtual ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        IPoolManager.PoolKey memory key = IPoolManager.PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        (uint160 sqrtPriceX96,,,,,) = poolManager.getSlot0(key.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // transfer liquidity tokens to erc20 contract
        UniswapV4ERC20 erc20 = UniswapV4ERC20(poolToInfo[key.toId()].liquidityToken);

        erc20.transferFrom(msg.sender, address(0), liquidity);

        modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -int256(liquidity)
            })
        );

        // here, all of the necessary liquidity should have been removed, this portion is just to update fees and feeGrowth
        PoolInfo storage poolInfo = poolToInfo[key.toId()];

        uint128 positionLiquidity = poolInfo.liquidity;
        require(positionLiquidity >= liquidity);

        Position.Info memory posInfo = poolManager.getPosition(key.toId(), address(this), MIN_TICK, MAX_TICK);

        poolInfo.tokensOwed0 += uint128(
            FullMath.mulDiv(
                posInfo.feeGrowthInside0LastX128 - poolInfo.feeGrowthInside0LastX128,
                positionLiquidity,
                FixedPoint128.Q128
            )
        );
        poolInfo.tokensOwed1 += uint128(
            FullMath.mulDiv(
                posInfo.feeGrowthInside1LastX128 - poolInfo.feeGrowthInside1LastX128,
                positionLiquidity,
                FixedPoint128.Q128
            )
        );

        poolInfo.feeGrowthInside0LastX128 = posInfo.feeGrowthInside0LastX128;
        poolInfo.feeGrowthInside1LastX128 = posInfo.feeGrowthInside1LastX128;
        // subtraction is safe because we checked positionLiquidity is gte liquidity
        poolInfo.liquidity = uint128(positionLiquidity - liquidity);
    }

    // deploy ERC-20 contract
    function beforeInitialize(address, IPoolManager.PoolKey calldata key, uint160) external override returns (bytes4) {
        require(key.tickSpacing == 60, "Tick spacing must be default");

        // deploy erc20 contract

        bytes memory bytecode = type(UniswapV4ERC20).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(key.toId()));

        address poolToken;
        assembly {
            poolToken := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        PoolInfo memory poolInfo = PoolInfo({
            liquidity: 0,
            feeGrowthInside0LastX128: 0,
            feeGrowthInside1LastX128: 0,
            tokensOwed0: 0,
            tokensOwed1: 0,
            blockNumber: block.number,
            liquidityToken: poolToken
        });

        poolToInfo[key.toId()] = poolInfo;

        return FullRange.beforeInitialize.selector;
    }

    function _rebalance(IPoolManager.PoolKey calldata key) internal {
        PoolInfo storage position = poolToInfo[key.toId()];

        BalanceDelta balanceDelta = hookModifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -int256(int128(position.liquidity))
            })
        );

        (uint160 sqrtPriceX96,,,,,) = poolManager.getSlot0(key.toId());

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(MIN_TICK),
            TickMath.getSqrtRatioAtTick(MAX_TICK),
            uint256(uint128(-balanceDelta.amount0())),
            uint256(uint128(-balanceDelta.amount1()))
        );

        // reinvest everything
        hookModifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: int256(int128(liquidity))
            })
        );

        // update position
        Position.Info memory posInfo = poolManager.getPosition(key.toId(), address(this), MIN_TICK, MAX_TICK);

        position.feeGrowthInside0LastX128 = posInfo.feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = posInfo.feeGrowthInside1LastX128;
        position.tokensOwed0 = 0;
        position.tokensOwed1 = 0;
    }

    function beforeModifyPosition(
        address sender,
        IPoolManager.PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params
    ) external override returns (bytes4) {
        // check msg.sender
        require(sender == address(this), "sender must be hook");
        PoolInfo storage position = poolToInfo[key.toId()];
        if (block.number > position.blockNumber) {
            position.blockNumber = block.number;

            if (position.tokensOwed1 > 0 || position.tokensOwed0 > 0) {
                _rebalance(key);
            }
        }

        return FullRange.beforeModifyPosition.selector;
    }

    function beforeSwap(address, IPoolManager.PoolKey calldata key, IPoolManager.SwapParams calldata)
        external
        override
        returns (bytes4)
    {
        PoolInfo storage position = poolToInfo[key.toId()];
        if (block.number > position.blockNumber) {
            position.blockNumber = block.number;

            if (position.tokensOwed1 > 0 || position.tokensOwed0 > 0) {
                _rebalance(key);
            }
        }
        return IHooks.beforeSwap.selector;
    }
}
