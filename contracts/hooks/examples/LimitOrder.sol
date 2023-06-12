// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/contracts/libraries/SafeCast.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {BaseHook} from "../../BaseHook.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";

type Epoch is uint232;

library EpochLibrary {
    function equals(Epoch a, Epoch b) internal pure returns (bool) {
        return Epoch.unwrap(a) == Epoch.unwrap(b);
    }

    function unsafeIncrement(Epoch a) internal pure returns (Epoch) {
        unchecked {
            return Epoch.wrap(Epoch.unwrap(a) + 1);
        }
    }
}

contract LimitOrder is BaseHook {
    using EpochLibrary for Epoch;
    using PoolId for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    error ZeroLiquidity();
    error InRange();
    error CrossedRange();
    error Filled();
    error NotFilled();
    error NotPoolManagerToken();

    event Place(
        address indexed owner,
        Epoch indexed epoch,
        IPoolManager.PoolKey key,
        int24 tickLower,
        bool zeroForOne,
        uint128 liquidity
    );

    event Fill(Epoch indexed epoch, IPoolManager.PoolKey key, int24 tickLower, bool zeroForOne);

    event Kill(
        address indexed owner,
        Epoch indexed epoch,
        IPoolManager.PoolKey key,
        int24 tickLower,
        bool zeroForOne,
        uint128 liquidity
    );

    event Withdraw(address indexed owner, Epoch indexed epoch, uint128 liquidity);

    Epoch private constant EPOCH_DEFAULT = Epoch.wrap(0);

    mapping(bytes32 => int24) public tickLowerLasts;
    Epoch public epochNext = Epoch.wrap(1);

    struct EpochInfo {
        bool filled;
        Currency currency0;
        Currency currency1;
        uint256 token0Total;
        uint256 token1Total;
        uint128 liquidityTotal;
        mapping(address => uint128) liquidity;
    }

    mapping(bytes32 => Epoch) public epochs;
    mapping(Epoch => EpochInfo) public epochInfos;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function getTickLowerLast(bytes32 poolId) public view returns (int24) {
        return tickLowerLasts[poolId];
    }

    function setTickLowerLast(bytes32 poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function getEpoch(IPoolManager.PoolKey memory key, int24 tickLower, bool zeroForOne) public view returns (Epoch) {
        return epochs[keccak256(abi.encode(key, tickLower, zeroForOne))];
    }

    function setEpoch(IPoolManager.PoolKey memory key, int24 tickLower, bool zeroForOne, Epoch epoch) private {
        epochs[keccak256(abi.encode(key, tickLower, zeroForOne))] = epoch;
    }

    function getEpochLiquidity(Epoch epoch, address owner) external view returns (uint256) {
        return epochInfos[epoch].liquidity[owner];
    }

    function getTick(bytes32 poolId) private view returns (int24 tick) {
        (, tick,) = poolManager.getSlot0(poolId);
    }

    function getTickLower(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }

    function afterInitialize(address, IPoolManager.PoolKey calldata key, uint160, int24 tick)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        setTickLowerLast(key.toId(), getTickLower(tick, key.tickSpacing));
        return LimitOrder.afterInitialize.selector;
    }

    function afterSwap(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta
    ) external override poolManagerOnly returns (bytes4) {
        (int24 tickLower, int24 lower, int24 upper) = _getCrossedTicks(key.toId(), key.tickSpacing);
        if (lower > upper) return LimitOrder.afterSwap.selector;

        // note that a zeroForOne swap means that the pool is actually gaining token0, so limit
        // order fills are the opposite of swap fills, hence the inversion below
        bool zeroForOne = !params.zeroForOne;
        for (; lower <= upper; lower += key.tickSpacing) {
            Epoch epoch = getEpoch(key, lower, zeroForOne);
            if (!epoch.equals(EPOCH_DEFAULT)) {
                EpochInfo storage epochInfo = epochInfos[epoch];

                epochInfo.filled = true;

                (uint256 amount0, uint256 amount1) = abi.decode(
                    poolManager.lock(
                        abi.encodeCall(this.lockAcquiredFill, (key, lower, -int256(uint256(epochInfo.liquidityTotal))))
                    ),
                    (uint256, uint256)
                );

                unchecked {
                    epochInfo.token0Total += amount0;
                    epochInfo.token1Total += amount1;
                }

                setEpoch(key, lower, zeroForOne, EPOCH_DEFAULT);

                emit Fill(epoch, key, lower, zeroForOne);
            }
        }

        setTickLowerLast(key.toId(), tickLower);
        return LimitOrder.afterSwap.selector;
    }

    function _getCrossedTicks(bytes32 poolId, int24 tickSpacing)
        internal
        view
        returns (int24 tickLower, int24 lower, int24 upper)
    {
        tickLower = getTickLower(getTick(poolId), tickSpacing);
        int24 tickLowerLast = getTickLowerLast(poolId);

        if (tickLower < tickLowerLast) {
            lower = tickLower + tickSpacing;
            upper = tickLowerLast;
        } else {
            lower = tickLowerLast;
            upper = tickLower - tickSpacing;
        }
    }

    function lockAcquiredFill(IPoolManager.PoolKey calldata key, int24 tickLower, int256 liquidityDelta)
        external
        selfOnly
        returns (uint128 amount0, uint128 amount1)
    {
        BalanceDelta delta = poolManager.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: liquidityDelta
            })
        );

        if (delta.amount0() < 0) poolManager.mint(key.currency0, address(this), amount0 = uint128(-delta.amount0()));
        if (delta.amount1() < 0) poolManager.mint(key.currency1, address(this), amount1 = uint128(-delta.amount1()));
    }

    function place(IPoolManager.PoolKey calldata key, int24 tickLower, bool zeroForOne, uint128 liquidity)
        external
        onlyValidPools(key.hooks)
    {
        if (liquidity == 0) revert ZeroLiquidity();

        poolManager.lock(
            abi.encodeCall(this.lockAcquiredPlace, (key, tickLower, zeroForOne, int256(uint256(liquidity)), msg.sender))
        );

        EpochInfo storage epochInfo;
        Epoch epoch = getEpoch(key, tickLower, zeroForOne);
        if (epoch.equals(EPOCH_DEFAULT)) {
            unchecked {
                setEpoch(key, tickLower, zeroForOne, epoch = epochNext);
                // since epoch was just assigned the current value of epochNext,
                // this is equivalent to epochNext++, which is what's intended,
                // and it saves an SLOAD
                epochNext = epoch.unsafeIncrement();
            }
            epochInfo = epochInfos[epoch];
            epochInfo.currency0 = key.currency0;
            epochInfo.currency1 = key.currency1;
        } else {
            epochInfo = epochInfos[epoch];
        }

        unchecked {
            epochInfo.liquidityTotal += liquidity;
            epochInfo.liquidity[msg.sender] += liquidity;
        }

        emit Place(msg.sender, epoch, key, tickLower, zeroForOne, liquidity);
    }

    function lockAcquiredPlace(
        IPoolManager.PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne,
        int256 liquidityDelta,
        address owner
    ) external selfOnly {
        BalanceDelta delta = poolManager.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.tickSpacing,
                liquidityDelta: liquidityDelta
            })
        );

        if (delta.amount0() > 0) {
            if (delta.amount1() != 0) revert InRange();
            if (!zeroForOne) revert CrossedRange();
            // TODO use safeTransferFrom
            IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(
                owner, address(poolManager), uint256(uint128(delta.amount0()))
            );
            poolManager.settle(key.currency0);
        } else {
            if (delta.amount0() != 0) revert InRange();
            if (zeroForOne) revert CrossedRange();
            // TODO use safeTransferFrom
            IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(
                owner, address(poolManager), uint256(uint128(delta.amount1()))
            );
            poolManager.settle(key.currency1);
        }
    }

    function kill(IPoolManager.PoolKey calldata key, int24 tickLower, bool zeroForOne, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Epoch epoch = getEpoch(key, tickLower, zeroForOne);
        EpochInfo storage epochInfo = epochInfos[epoch];

        if (epochInfo.filled) revert Filled();

        uint128 liquidity = epochInfo.liquidity[msg.sender];
        if (liquidity == 0) revert ZeroLiquidity();
        delete epochInfo.liquidity[msg.sender];
        uint128 liquidityTotal = epochInfo.liquidityTotal;
        epochInfo.liquidityTotal = liquidityTotal - liquidity;

        uint256 amount0Fee;
        uint256 amount1Fee;
        (amount0, amount1, amount0Fee, amount1Fee) = abi.decode(
            poolManager.lock(
                abi.encodeCall(
                    this.lockAcquiredKill,
                    (key, tickLower, -int256(uint256(liquidity)), to, liquidity == liquidityTotal)
                )
            ),
            (uint256, uint256, uint256, uint256)
        );

        unchecked {
            epochInfo.token0Total += amount0Fee;
            epochInfo.token1Total += amount1Fee;
        }

        emit Kill(msg.sender, epoch, key, tickLower, zeroForOne, liquidity);
    }

    function lockAcquiredKill(
        IPoolManager.PoolKey calldata key,
        int24 tickLower,
        int256 liquidityDelta,
        address to,
        bool removingAllLiquidity
    ) external selfOnly returns (uint256 amount0, uint256 amount1, uint128 amount0Fee, uint128 amount1Fee) {
        int24 tickUpper = tickLower + key.tickSpacing;

        // because `modifyPosition` includes not just principal value but also fees, we cannot allocate
        // the proceeds pro-rata. if we were to do so, users who have been in a limit order that's partially filled
        // could be unfairly diluted by a user sychronously placing then killing a limit order to skim off fees.
        // to prevent this, we allocate all fee revenue to remaining limit order placers, unless this is the last order.
        if (!removingAllLiquidity) {
            BalanceDelta deltaFee = poolManager.modifyPosition(
                key, IPoolManager.ModifyPositionParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0})
            );

            if (deltaFee.amount0() < 0) {
                poolManager.mint(key.currency0, address(this), amount0Fee = uint128(-deltaFee.amount0()));
            }
            if (deltaFee.amount1() < 0) {
                poolManager.mint(key.currency1, address(this), amount1Fee = uint128(-deltaFee.amount1()));
            }
        }

        BalanceDelta delta = poolManager.modifyPosition(
            key,
            IPoolManager.ModifyPositionParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta
            })
        );

        if (delta.amount0() < 0) poolManager.take(key.currency0, to, amount0 = uint128(-delta.amount0()));
        if (delta.amount1() < 0) poolManager.take(key.currency1, to, amount1 = uint128(-delta.amount1()));
    }

    function withdraw(Epoch epoch, address to) external returns (uint256 amount0, uint256 amount1) {
        EpochInfo storage epochInfo = epochInfos[epoch];

        if (!epochInfo.filled) revert NotFilled();

        uint128 liquidity = epochInfo.liquidity[msg.sender];
        if (liquidity == 0) revert ZeroLiquidity();
        delete epochInfo.liquidity[msg.sender];

        uint256 token0Total = epochInfo.token0Total;
        uint256 token1Total = epochInfo.token1Total;
        uint128 liquidityTotal = epochInfo.liquidityTotal;

        amount0 = FullMath.mulDiv(token0Total, liquidity, liquidityTotal);
        amount1 = FullMath.mulDiv(token1Total, liquidity, liquidityTotal);

        epochInfo.token0Total = token0Total - amount0;
        epochInfo.token1Total = token1Total - amount1;
        epochInfo.liquidityTotal = liquidityTotal - liquidity;

        poolManager.lock(
            abi.encodeCall(this.lockAcquiredWithdraw, (epochInfo.currency0, epochInfo.currency1, amount0, amount1, to))
        );

        emit Withdraw(msg.sender, epoch, liquidity);
    }

    function lockAcquiredWithdraw(
        Currency currency0,
        Currency currency1,
        uint256 token0Amount,
        uint256 token1Amount,
        address to
    ) external selfOnly {
        if (token0Amount > 0) {
            poolManager.safeTransferFrom(
                address(this), address(poolManager), uint256(uint160(Currency.unwrap(currency0))), token0Amount, ""
            );
            poolManager.take(currency0, to, token0Amount);
        }
        if (token1Amount > 0) {
            poolManager.safeTransferFrom(
                address(this), address(poolManager), uint256(uint160(Currency.unwrap(currency1))), token1Amount, ""
            );
            poolManager.take(currency1, to, token1Amount);
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManagerToken();
        return IERC1155Receiver.onERC1155Received.selector;
    }
}
