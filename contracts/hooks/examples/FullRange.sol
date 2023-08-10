// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {BaseHook} from "../../BaseHook.sol";
import {SafeCast} from "@uniswap/v4-core/contracts/libraries/SafeCast.sol";
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
import {IERC20Metadata} from "../../interfaces/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import "../../libraries/LiquidityAmounts.sol";

contract FullRange is BaseHook, ILockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

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
        bool owed;
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

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,,,) = poolManager.getSlot0(poolId);

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
        PoolInfo storage pool = poolInfo[poolId];

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

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,,,) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        UniswapV4ERC20 erc20 = UniswapV4ERC20(poolInfo[poolId].liquidityToken);

        erc20.burn(msg.sender, liquidity);

        delta = modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -int256(liquidity)
            })
        );
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external override returns (bytes4) {
        require(key.tickSpacing == 60, "Tick spacing must be default");

        PoolId poolId = key.toId();

        string memory tokenSymbol = string(
            abi.encodePacked(
                IERC20Metadata(Currency.unwrap(key.currency0)).symbol(),
                "-",
                IERC20Metadata(Currency.unwrap(key.currency1)).symbol(),
                "-",
                Strings.toString(uint256(key.fee))
            )
        );
        address poolToken = address(new UniswapV4ERC20(tokenSymbol, tokenSymbol));

        poolInfo[poolId] = PoolInfo({owed: false, liquidityToken: poolToken});

        return FullRange.beforeInitialize.selector;
    }

    function beforeModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params
    ) external override returns (bytes4) {
        require(sender == address(this), "Sender must be hook");
        _rebalance(key, params.liquidityDelta);

        return FullRange.beforeModifyPosition.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata)
        external
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        bool tokensOwed = poolInfo[poolId].owed;

        if (!tokensOwed) {
            PoolInfo storage pool = poolInfo[poolId];
            pool.owed = true;
        }

        return IHooks.beforeSwap.selector;
    }

    function modifyPosition(PoolKey memory key, IPoolManager.ModifyPositionParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(poolManager.lock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));
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

    function _rebalance(PoolKey calldata key, int256 paramsLiquidity) internal {
        PoolId poolId = key.toId();
        PoolInfo storage pool = poolInfo[poolId];
        if (pool.owed && paramsLiquidity < 0) {
            pool.owed = false;

            BalanceDelta balanceDelta = poolManager.modifyPosition(
                key,
                IPoolManager.ModifyPositionParams({
                    tickLower: MIN_TICK,
                    tickUpper: MAX_TICK,
                    liquidityDelta: -int256(int128(poolManager.getLiquidity(poolId)))
                })
            );

            uint160 newSqrtPriceX96 = (
                FixedPointMathLib.sqrt(
                    FullMath.mulDiv(
                        uint128(-balanceDelta.amount1()), FixedPoint96.Q96, uint128(-balanceDelta.amount0())
                    )
                ) * FixedPointMathLib.sqrt(FixedPoint96.Q96)
            ).toUint160();

            (uint160 sqrtPriceX96,,,,,) = poolManager.getSlot0(poolId);

            poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: newSqrtPriceX96 < sqrtPriceX96,
                    amountSpecified: MAX_INT,
                    sqrtPriceLimitX96: newSqrtPriceX96
                })
            );

            pool.owed = false;

            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                newSqrtPriceX96,
                TickMath.getSqrtRatioAtTick(MIN_TICK),
                TickMath.getSqrtRatioAtTick(MAX_TICK),
                uint256(uint128(-balanceDelta.amount0())),
                uint256(uint128(-balanceDelta.amount1()))
            );

            BalanceDelta balanceDeltaAfter = poolManager.modifyPosition(
                key,
                IPoolManager.ModifyPositionParams({
                    tickLower: MIN_TICK,
                    tickUpper: MAX_TICK,
                    liquidityDelta: int256(int128(liquidity))
                })
            );

            // Donate any "dust" from the sqrtRatio change as fees
            uint128 donateAmount0 = uint128(-balanceDelta.amount0() - balanceDeltaAfter.amount0());
            uint128 donateAmount1 = uint128(-balanceDelta.amount1() - balanceDeltaAfter.amount1());

            poolManager.donate(key, donateAmount0, donateAmount1);
        }
    }
}
