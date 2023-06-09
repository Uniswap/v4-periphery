// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.15;
//
// import {TWAMMHook} from '../../../contracts/hooks/TWAMMHook.sol';
// import {TwammMath} from '../../../contracts/libraries/TWAMM/TwammMath.sol';
// import {OrderPool} from '../../../contracts/libraries/TWAMM/OrderPool.sol';
// import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
// import {Pool} from "@uniswap/v4-core/contracts/libraries/Pool.sol";
// import {TickBitmap} from "@uniswap/v4-core/contracts/libraries/TickBitmap.sol";
// import {ABDKMathQuad} from '../../../contracts/libraries/TWAMM/ABDKMathQuad.sol';
// import {FixedPoint96} from "@uniswap/v4-core/contracts/libraries/FixedPoint96.sol";
//
// contract TWAMMTest is TWAMMHook {
//     using ABDKMathQuad for *;
//     using TickBitmap for mapping(int16 => uint256);
//
//     mapping(int24 => Pool.TickInfo) mockTicks;
//     mapping(int16 => uint256) mockTickBitmap;
//
//     function flipTick(int24 tick, int24 tickSpacing) external {
//         mockTickBitmap.flipTick(tick, tickSpacing);
//     }
//
//     constructor(uint256 _expirationInterval) {
//         expirationInterval = _expirationInterval;
//     }
//
//     function initialize() external {
//         twamm.initialize();
//     }
//
//     function lastVirtualOrderTimestamp() external view returns (uint256) {
//         return twamm.lastVirtualOrderTimestamp;
//     }
//
//     function submitOrder(OrderKey calldata orderKey, uint256 amountIn)
//         external
//         returns (bytes32 orderId)
//     {
//         unchecked {
//             orderId = twamm.submitOrder(
//                 orderKey,
//                 amountIn / (orderKey.expiration - block.timestamp),
//                 expirationInterval
//             );
//         }
//     }
//
//     function updateOrder(OrderKey calldata orderKey, int128 amountDelta)
//         external
//         returns (
//             uint256 buyTokensOwed,
//             uint256 sellTokensOwed,
//             uint256 newSellRate,
//             uint256 earningsFactorLast
//         )
//     {
//         return twamm.updateOrder(orderKey, amountDelta);
//     }
//
//     // dont return true if the init tick is directly after the target price
//     function isCrossingInitializedTick(
//         PoolParamsOnExecute memory pool,
//         IPoolManager.PoolKey calldata poolKey,
//         uint160 nextSqrtPriceX96
//     ) external view returns (bool initialized, int24 nextTickInit) {
//         (initialized, nextTickInit) = TWAMM.isCrossingInitializedTick(
//             pool,
//             IPoolManager(address(this)),
//             poolKey,
//             nextSqrtPriceX96
//         );
//     }
//
//     function executeTWAMMOrders(IPoolManager.PoolKey calldata poolKey, PoolParamsOnExecute memory poolParams)
//         external
//     {
//         twamm.executeTWAMMOrders(IPoolManager(address(this)), poolKey, poolParams, expirationInterval);
//     }
//
//     function calculateExecutionUpdates(TwammMath.ExecutionUpdateParams memory params)
//         external
//         pure
//         returns (
//             uint160 sqrtPriceX96,
//             uint256 earningsFactorPool0,
//             uint256 earningsFactorPool1
//         )
//     {
//         uint160 finalSqrtPriceX96 = TwammMath.getNewSqrtPriceX96(params);
//         (earningsFactorPool0, earningsFactorPool1) = TwammMath.calculateEarningsUpdates(params, finalSqrtPriceX96);
//
//         return (finalSqrtPriceX96, earningsFactorPool0, earningsFactorPool1);
//     }
//
//     function gasSnapshotCalculateExecutionUpdates(TwammMath.ExecutionUpdateParams memory params)
//         external
//         view
//         returns (uint256)
//     {
//         uint256 gasLeftBefore = gasleft();
//         uint160 finalSqrtPriceX96 = TwammMath.getNewSqrtPriceX96(params);
//         TwammMath.calculateEarningsUpdates(params, finalSqrtPriceX96);
//         return gasLeftBefore - gasleft();
//     }
//
//     function calculateTimeBetweenTicks(
//         uint256 liquidity,
//         uint160 sqrtPriceStartX96,
//         uint160 sqrtPriceEndX96,
//         uint256 sellRate0,
//         uint256 sellRate1
//     ) external pure returns (uint256) {
//         return TwammMath.calculateTimeBetweenTicks(liquidity, sqrtPriceStartX96, sqrtPriceEndX96, sellRate0, sellRate1);
//     }
//
//     function gasSnapshotCalculateTimeBetweenTicks(
//         uint256 liquidity,
//         uint160 sqrtPriceStartX96,
//         uint160 sqrtPriceEndX96,
//         uint256 sellRate0,
//         uint256 sellRate1
//     ) external view returns (uint256) {
//         uint256 gasLeftBefore = gasleft();
//         TwammMath.calculateTimeBetweenTicks(liquidity, sqrtPriceStartX96, sqrtPriceEndX96, sellRate0, sellRate1);
//         return gasLeftBefore - gasleft();
//     }
//
//     function getOrder(OrderKey calldata orderKey) external view returns (Order memory) {
//         return twamm.getOrder(orderKey);
//     }
//
//     function getOrderPool(bool zeroForOne) external view returns (uint256 sellRate, uint256 earningsFactor) {
//         if (zeroForOne) return (twamm.orderPool0For1.sellRateCurrent, twamm.orderPool0For1.earningsFactorCurrent);
//         else return (twamm.orderPool1For0.sellRateCurrent, twamm.orderPool1For0.earningsFactorCurrent);
//     }
//
//     function getOrderPoolSellRateEndingPerInterval(bool zeroForOne, uint256 timestamp)
//         external
//         view
//         returns (uint256 sellRate)
//     {
//         if (zeroForOne) return twamm.orderPool0For1.sellRateEndingAtInterval[timestamp];
//         else return twamm.orderPool1For0.sellRateEndingAtInterval[timestamp];
//     }
//
//     function getOrderPoolEarningsFactorAtInterval(bool zeroForOne, uint256 timestamp)
//         external
//         view
//         returns (uint256 earningsFactor)
//     {
//         if (zeroForOne) return twamm.orderPool0For1.earningsFactorAtInterval[timestamp];
//         else return twamm.orderPool1For0.earningsFactorAtInterval[timestamp];
//     }
//
//     //////////////////////////////////////////////////////
//     // Mocking IPoolManager functions here
//     //////////////////////////////////////////////////////
//
//     function getTickNetLiquidity(IPoolManager.PoolKey memory, int24 tick) external view returns (Pool.TickInfo memory) {
//         return mockTicks[tick];
//     }
//
//     function getNextInitializedTickWithinOneWord(
//         IPoolManager.PoolKey memory key,
//         int24 tick,
//         bool lte
//     ) external view returns (int24 next, bool initialized) {
//         return mockTickBitmap.nextInitializedTickWithinOneWord(tick, key.tickSpacing, lte);
//     }
// }
