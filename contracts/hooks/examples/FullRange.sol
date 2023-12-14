// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "../../BaseHook.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ILockCallback} from "@uniswap/v4-core/src/interfaces/callback/ILockCallback.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {UniswapV4ERC20} from "../../libraries/UniswapV4ERC20.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import "../../libraries/LiquidityAmounts.sol";

contract FullRange is BaseHook, ILockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for uint128;

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();
    error TickSpacingNotDefault();
    error LiquidityDoesntMeetMinimum();
    error SenderMustBeHook();
    error ExpiredPastDeadline();
    error TooMuchSlippage();

    bytes internal constant ZERO_BYTES = bytes("");

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    int256 internal constant MAX_INT = type(int256).max;
    uint16 internal constant MINIMUM_LIQUIDITY = 1000;

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyPositionParams params;
    }

    struct PoolInfo {
        bool hasAccruedFees;
        address liquidityToken;
    }

    struct AddLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address to;
        uint256 deadline;
    }

    struct RemoveLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 liquidity;
        uint256 deadline;
    }

    mapping(PoolId => PoolInfo) public poolInfo;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    function getHooksCalls() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeModifyPosition: true,
            afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            noOp: false,
            accessLock: false
        });
    }

    function addLiquidity(AddLiquidityParams calldata params)
        external
        ensure(params.deadline)
        returns (uint128 liquidity)
    {
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        PoolInfo storage pool = poolInfo[poolId];

        uint128 poolLiquidity = poolManager.getLiquidity(poolId);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(MIN_TICK),
            TickMath.getSqrtRatioAtTick(MAX_TICK),
            params.amount0Desired,
            params.amount1Desired
        );

        if (poolLiquidity == 0 && liquidity <= MINIMUM_LIQUIDITY) {
            revert LiquidityDoesntMeetMinimum();
        }
        BalanceDelta addedDelta = modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: liquidity.toInt256()
            })
        );

        if (poolLiquidity == 0) {
            // permanently lock the first MINIMUM_LIQUIDITY tokens
            liquidity -= MINIMUM_LIQUIDITY;
            UniswapV4ERC20(pool.liquidityToken).mint(address(0), MINIMUM_LIQUIDITY);
        }

        UniswapV4ERC20(pool.liquidityToken).mint(params.to, liquidity);

        if (uint128(addedDelta.amount0()) < params.amount0Min || uint128(addedDelta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    function removeLiquidity(RemoveLiquidityParams calldata params)
        public
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        UniswapV4ERC20 erc20 = UniswapV4ERC20(poolInfo[poolId].liquidityToken);

        delta = modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(params.liquidity.toInt256())
            })
        );

        erc20.burn(msg.sender, params.liquidity);
    }

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (key.tickSpacing != 60) revert TickSpacingNotDefault();

        PoolId poolId = key.toId();

        string memory tokenSymbol = string(
            abi.encodePacked(
                "UniV4",
                "-",
                IERC20Metadata(Currency.unwrap(key.currency0)).symbol(),
                "-",
                IERC20Metadata(Currency.unwrap(key.currency1)).symbol(),
                "-",
                Strings.toString(uint256(key.fee))
            )
        );
        address poolToken = address(new UniswapV4ERC20(tokenSymbol, tokenSymbol));

        poolInfo[poolId] = PoolInfo({hasAccruedFees: false, liquidityToken: poolToken});

        return FullRange.beforeInitialize.selector;
    }

    function beforeModifyPosition(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyPositionParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        if (sender != address(this)) revert SenderMustBeHook();

        return FullRange.beforeModifyPosition.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        if (!poolInfo[poolId].hasAccruedFees) {
            PoolInfo storage pool = poolInfo[poolId];
            pool.hasAccruedFees = true;
        }

        return IHooks.beforeSwap.selector;
    }

    function modifyPosition(PoolKey memory key, IPoolManager.ModifyPositionParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            poolManager.lock(address(this), abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta)
        );
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

    function _removeLiquidity(PoolKey memory key, IPoolManager.ModifyPositionParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        PoolId poolId = key.toId();
        PoolInfo storage pool = poolInfo[poolId];

        if (pool.hasAccruedFees) {
            _rebalance(key);
        }

        uint256 liquidityToRemove = FullMath.mulDiv(
            uint256(-params.liquidityDelta),
            poolManager.getLiquidity(poolId),
            UniswapV4ERC20(pool.liquidityToken).totalSupply()
        );

        params.liquidityDelta = -(liquidityToRemove.toInt256());
        delta = poolManager.modifyPosition(key, params, ZERO_BYTES);
        pool.hasAccruedFees = false;
    }

    function lockAcquired(address sender, bytes calldata rawData)
        external
        override(ILockCallback, BaseHook)
        poolManagerOnly
        returns (bytes memory)
    {
        // Now that manager can be called by EOAs with a lock target, it's necessary for lockAcquired to check the original sender if it wants to trust the data passed through.
        if (sender != address(this)) revert SenderMustBeHook();
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        if (data.params.liquidityDelta < 0) {
            delta = _removeLiquidity(data.key, data.params);
            _takeDeltas(data.sender, data.key, delta);
        } else {
            delta = poolManager.modifyPosition(data.key, data.params, ZERO_BYTES);
            _settleDeltas(data.sender, data.key, delta);
        }
        return abi.encode(delta);
    }

    function _rebalance(PoolKey memory key) public {
        PoolId poolId = key.toId();
        BalanceDelta balanceDelta = poolManager.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(poolManager.getLiquidity(poolId).toInt256())
            }),
            ZERO_BYTES
        );

        uint160 newSqrtPriceX96 = (
            FixedPointMathLib.sqrt(
                FullMath.mulDiv(uint128(-balanceDelta.amount1()), FixedPoint96.Q96, uint128(-balanceDelta.amount0()))
            ) * FixedPointMathLib.sqrt(FixedPoint96.Q96)
        ).toUint160();

        (uint160 sqrtPriceX96,,) = poolManager.getSlot0(poolId);

        poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: newSqrtPriceX96 < sqrtPriceX96,
                amountSpecified: MAX_INT,
                sqrtPriceLimitX96: newSqrtPriceX96
            }),
            ZERO_BYTES
        );

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
                liquidityDelta: liquidity.toInt256()
            }),
            ZERO_BYTES
        );

        // Donate any "dust" from the sqrtRatio change as fees
        uint128 donateAmount0 = uint128(-balanceDelta.amount0() - balanceDeltaAfter.amount0());
        uint128 donateAmount1 = uint128(-balanceDelta.amount1() - balanceDeltaAfter.amount1());

        poolManager.donate(key, donateAmount0, donateAmount1, ZERO_BYTES);
    }
}
