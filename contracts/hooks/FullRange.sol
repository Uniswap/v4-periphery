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
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import "@uniswap/v4-core/contracts/libraries/FixedPoint128.sol";
import {FixedPoint96} from "@uniswap/v4-core/contracts/libraries/FixedPoint96.sol";

import "forge-std/console2.sol";

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

    modifier ensure(uint256 deadline)
     {
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

    function beforeInitialize(address, IPoolManager.PoolKey calldata key, uint160) external override returns (bytes4) {
        require(key.tickSpacing == 60, "Tick spacing must be default");

        // deploy erc20 contract

        // TODO: name, symbol for the ERC20 contract
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

    function beforeModifyPosition(
        address sender,
        IPoolManager.PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params
    ) external override returns (bytes4) {
        // check msg.sender
        require(sender == address(this), "sender must be hook");
        _rebalance(key);

        return FullRange.beforeModifyPosition.selector;
    }

    function beforeSwap(address, IPoolManager.PoolKey calldata key, IPoolManager.SwapParams calldata)
        external
        override
        returns (bytes4)
    {
        // TODO: maybe don't sload the entire struct
        PoolInfo storage position = poolInfo[key.toId()];
        _rebalance(key);
        return IHooks.beforeSwap.selector;
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

        delta = abi.decode(poolManager.lock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));

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

        delta = abi.decode(poolManager.lock(abi.encode(CallbackData(address(this), key, params))), (BalanceDelta));

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
            poolManager.take(data.key.currency0, data.sender, uint256(uint128(-delta.amount0())));

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
            poolManager.take(data.key.currency1, data.sender, uint256(uint128(-delta.amount1())));

            if (data.key.currency1.isNative()) {
                poolManager.settle{value: uint128(-delta.amount1())}(data.key.currency1);
            } else {
                poolManager.settle(data.key.currency1);
            }
        }

        return abi.encode(delta);
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

        PoolInfo storage poolInfo = poolInfo[key.toId()];

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

        UniswapV4ERC20(poolInfo.liquidityToken).mint(to, liquidity);
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
        UniswapV4ERC20 erc20 = UniswapV4ERC20(poolInfo[key.toId()].liquidityToken);

        erc20.burn(msg.sender, liquidity);

        modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -int256(liquidity)
            })
        );

        // here, all of the necessary liquidity should have been removed, this portion is just to update fees and feeGrowth
        PoolInfo storage poolInfo = poolInfo[key.toId()];

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

    function sqrt(uint256 x) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            let y := x // We start y at x, which will help us make our initial estimate.

            z := 181 // The "correct" value is 1, but this saves a multiplication later.

            // This segment is to get a reasonable initial estimate for the Babylonian method. With a bad
            // start, the correct # of bits increases ~linearly each iteration instead of ~quadratically.

            // We check y >= 2^(k + 8) but shift right by k bits
            // each branch to ensure that if x >= 256, then y >= 256.
            if iszero(lt(y, 0x10000000000000000000000000000000000)) {
                y := shr(128, y)
                z := shl(64, z)
            }
            if iszero(lt(y, 0x1000000000000000000)) {
                y := shr(64, y)
                z := shl(32, z)
            }
            if iszero(lt(y, 0x10000000000)) {
                y := shr(32, y)
                z := shl(16, z)
            }
            if iszero(lt(y, 0x1000000)) {
                y := shr(16, y)
                z := shl(8, z)
            }

            // Goal was to get z*z*y within a small factor of x. More iterations could
            // get y in a tighter range. Currently, we will have y in [256, 256*2^16).
            // We ensured y >= 256 so that the relative difference between y and y+1 is small.
            // That's not possible if x < 256 but we can just verify those cases exhaustively.

            // Now, z*z*y <= x < z*z*(y+1), and y <= 2^(16+8), and either y >= 256, or x < 256.
            // Correctness can be checked exhaustively for x < 256, so we assume y >= 256.
            // Then z*sqrt(y) is within sqrt(257)/sqrt(256) of sqrt(x), or about 20bps.

            // For s in the range [1/256, 256], the estimate f(s) = (181/1024) * (s+1) is in the range
            // (1/2.84 * sqrt(s), 2.84 * sqrt(s)), with largest error when s = 1 and when s = 256 or 1/256.

            // Since y is in [256, 256*2^16), let a = y/65536, so that a is in [1/256, 256). Then we can estimate
            // sqrt(y) using sqrt(65536) * 181/1024 * (a + 1) = 181/4 * (y + 65536)/65536 = 181 * (y + 65536)/2^18.

            // There is no overflow risk here since y < 2^136 after the first branch above.
            z := shr(18, mul(z, add(y, 65536))) // A mul() is saved from starting z at 181.

            // Given the worst case multiplicative error of 2.84 above, 7 iterations should be enough.
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))

            // If x+1 is a perfect square, the Babylonian method cycles between
            // floor(sqrt(x)) and ceil(sqrt(x)). This statement ensures we return floor.
            // See: https://en.wikipedia.org/wiki/Integer_square_root#Using_only_integer_division
            // Since the ceil is rare, we save gas on the assignment and repeat division in the rare case.
            // If you don't care whether the floor or ceil square root is returned, you can remove this statement.
            z := sub(z, lt(div(x, z), z))
        }
    }

    function getSqrtPrice(IPoolManager.PoolKey calldata key, BalanceDelta delta) public returns (uint160 newSqrtPriceX96){
        newSqrtPriceX96 = uint160(sqrt(FullMath.mulDiv(
                    uint128(delta.amount1()),
                    FixedPoint96.Q96,
                    uint128(delta.amount0())
                )) * sqrt(FixedPoint96.Q96));
        
        console2.log(newSqrtPriceX96);
    }

    function _rebalance(IPoolManager.PoolKey calldata key) internal {
        PoolInfo storage position = poolInfo[key.toId()];

        if (block.number > position.blockNumber) {
            position.blockNumber = block.number;

            if (position.tokensOwed1 > 0 || position.tokensOwed0 > 0) {
                uint256 prevBal0 = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(this));
                uint256 prevBal1 = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(this));

                BalanceDelta balanceDelta = hookModifyPosition(
                    key,
                    IPoolManager.ModifyPositionParams({
                        tickLower: MIN_TICK,
                        tickUpper: MAX_TICK,
                        liquidityDelta: -int256(int128(position.liquidity))
                    })
                );

                uint160 newSqrtPriceX96 = uint160(sqrt(FullMath.mulDiv(
                    uint128(balanceDelta.amount1()),
                    FixedPoint96.Q96,
                    uint128(balanceDelta.amount0())
                )) * sqrt(FixedPoint96.Q96));

                // TODO: change this max
                BalanceDelta swapDelta = poolManager.swap(
                    key,
                    IPoolManager.SwapParams({
                        zeroForOne: balanceDelta.amount0() > 0,
                        amountSpecified: 100000000 ether,
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

                // make sure there is no dust
                // require(IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(this)) == prevBal0);
                // require(IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(this)) == prevBal1);

                console2.log("new balance 0", IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(this)));
                console2.log("new balance 1", IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(this)));
                console2.log("prev balance 0", prevBal0);
                console2.log("prev balance 1", prevBal1);

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
