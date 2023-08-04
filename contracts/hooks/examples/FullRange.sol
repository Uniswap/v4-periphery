// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {BaseHook} from "../../BaseHook.sol";

import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {UniswapV4ERC20} from "../../libraries/UniswapV4ERC20.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {FixedPoint128} from "@uniswap/v4-core/contracts/libraries/FixedPoint128.sol";
import {FixedPoint96} from "@uniswap/v4-core/contracts/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ILockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/ILockCallback.sol";

import "../../libraries/LiquidityAmounts.sol";

contract FullRange is BaseHook, ILockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    int256 internal constant MAX_INT = type(int256).max;

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyPositionParams params;
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

    mapping(PoolId => PoolInfo) public poolInfo;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "Expired");
        _;
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
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

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

        PoolInfo storage pool = poolInfo[key.toId()];

        pool.tokensOwed0 += uint128(
            FullMath.mulDiv(
                posInfo.feeGrowthInside0LastX128 - pool.feeGrowthInside0LastX128, pool.liquidity, FixedPoint128.Q128
            )
        );
        pool.tokensOwed1 += uint128(
            FullMath.mulDiv(
                posInfo.feeGrowthInside1LastX128 - pool.feeGrowthInside1LastX128, pool.liquidity, FixedPoint128.Q128
            )
        );

        pool.feeGrowthInside0LastX128 = posInfo.feeGrowthInside0LastX128;
        pool.feeGrowthInside1LastX128 = posInfo.feeGrowthInside1LastX128;
        pool.liquidity += liquidity;

        UniswapV4ERC20(pool.liquidityToken).mint(to, liquidity);
    }

    function removeLiquidity(address tokenA, address tokenB, uint24 fee, uint256 liquidity, uint256 deadline)
        public
        virtual
        ensure(deadline)
        returns (BalanceDelta delta)
    {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        (uint160 sqrtPriceX96,,,,,) = poolManager.getSlot0(key.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // transfer liquidity tokens to erc20 contract
        UniswapV4ERC20 erc20 = UniswapV4ERC20(poolInfo[key.toId()].liquidityToken);

        erc20.burn(msg.sender, liquidity);

        delta = modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -int256(liquidity)
            })
        );

        // here, all of the necessary liquidity should have been removed, this portion is just to update fees and feeGrowth
        PoolInfo storage pool = poolInfo[key.toId()];

        uint128 positionLiquidity = pool.liquidity;
        require(positionLiquidity >= liquidity);

        Position.Info memory posInfo = poolManager.getPosition(key.toId(), address(this), MIN_TICK, MAX_TICK);

        pool.tokensOwed0 += uint128(
            FullMath.mulDiv(
                posInfo.feeGrowthInside0LastX128 - pool.feeGrowthInside0LastX128, positionLiquidity, FixedPoint128.Q128
            )
        );
        pool.tokensOwed1 += uint128(
            FullMath.mulDiv(
                posInfo.feeGrowthInside1LastX128 - pool.feeGrowthInside1LastX128, positionLiquidity, FixedPoint128.Q128
            )
        );

        pool.feeGrowthInside0LastX128 = posInfo.feeGrowthInside0LastX128;
        pool.feeGrowthInside1LastX128 = posInfo.feeGrowthInside1LastX128;
        // subtraction is safe because we checked positionLiquidity is gte liquidity
        pool.liquidity = uint128(positionLiquidity - liquidity);
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external override returns (bytes4) {
        require(key.tickSpacing == 60, "Tick spacing must be default");
        bytes memory bytecode = type(UniswapV4ERC20).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(key.toId()));

        address poolToken;
        assembly {
            poolToken := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }

        PoolInfo memory info = PoolInfo({
            liquidity: 0,
            feeGrowthInside0LastX128: 0,
            feeGrowthInside1LastX128: 0,
            tokensOwed0: 0,
            tokensOwed1: 0,
            blockNumber: block.number,
            liquidityToken: poolToken
        });

        poolInfo[key.toId()] = info;

        return FullRange.beforeInitialize.selector;
    }

    function beforeModifyPosition(address sender, PoolKey calldata key, IPoolManager.ModifyPositionParams calldata)
        external
        override
        returns (bytes4)
    {
        require(sender == address(this), "sender must be hook");
        _rebalance(key);

        return FullRange.beforeModifyPosition.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata)
        external
        override
        returns (bytes4)
    {
        _rebalance(key);
        return IHooks.beforeSwap.selector;
    }

    function modifyPosition(PoolKey memory key, IPoolManager.ModifyPositionParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(poolManager.lock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));
    }

    function hookModifyPosition(PoolKey memory key, IPoolManager.ModifyPositionParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(poolManager.lock(abi.encode(CallbackData(address(this), key, params))), (BalanceDelta));
    }

    function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        _settleDelta(sender, key.currency0, uint128(delta.amount0()));
        _settleDelta(sender, key.currency1, uint128(delta.amount1()));
    }

    function _settleDelta(address sender, Currency currency, uint128 amount) internal {
        if (currency.isNative()) {
            poolManager.settle{value: amount}(currency);
        } else {
            if (sender == address(this)) {
                currency.transfer(address(poolManager), amount);
            } else {
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(sender, address(poolManager), amount);
            }
            poolManager.settle(currency);
        }
    }

    function _takeDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        poolManager.take(key.currency0, sender, uint256(uint128(-delta.amount0())));
        poolManager.take(key.currency1, sender, uint256(uint128(-delta.amount1())));
    }

    function lockAcquired(bytes calldata rawData)
        external
        override(ILockCallback, BaseHook)
        poolManagerOnly
        returns (bytes memory)
    {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = poolManager.modifyPosition(data.key, data.params);

        if (delta.amount0() > 0) {
            _settleDeltas(data.sender, data.key, delta);
        } else {
            _takeDeltas(data.sender, data.key, delta);
        }
        return abi.encode(delta);
    }

    function _rebalance(PoolKey calldata key) internal {
        PoolInfo storage position = poolInfo[key.toId()];

        if (block.number > position.blockNumber) {
            position.blockNumber = block.number;

            if (position.tokensOwed1 > 0 || position.tokensOwed0 > 0) {
                BalanceDelta balanceDelta = hookModifyPosition(
                    key,
                    IPoolManager.ModifyPositionParams({
                        tickLower: MIN_TICK,
                        tickUpper: MAX_TICK,
                        liquidityDelta: -int256(int128(position.liquidity))
                    })
                );

                uint160 newSqrtPriceX96 = uint160(
                    FixedPointMathLib.sqrt(
                        FullMath.mulDiv(
                            uint128(-balanceDelta.amount1()), FixedPoint96.Q96, uint128(-balanceDelta.amount0())
                        )
                    ) * FixedPointMathLib.sqrt(FixedPoint96.Q96)
                );

                (uint160 sqrtPriceX96,,,,,) = poolManager.getSlot0(key.toId());

                poolManager.swap(
                    key,
                    IPoolManager.SwapParams({
                        zeroForOne: newSqrtPriceX96 < sqrtPriceX96,
                        amountSpecified: MAX_INT,
                        sqrtPriceLimitX96: newSqrtPriceX96
                    })
                );

                uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                    newSqrtPriceX96,
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
        }
    }
}
