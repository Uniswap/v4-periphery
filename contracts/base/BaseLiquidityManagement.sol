// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityPosition, LiquidityPositionId, LiquidityPositionIdLibrary} from "../types/LiquidityPositionId.sol";
import {IBaseLiquidityManagement} from "../interfaces/IBaseLiquidityManagement.sol";
import {SafeCallback} from "./SafeCallback.sol";
import {ImmutableState} from "./ImmutableState.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {CurrencySettleTake} from "../libraries/CurrencySettleTake.sol";

abstract contract BaseLiquidityManagement is SafeCallback, IBaseLiquidityManagement {
    using LiquidityPositionIdLibrary for LiquidityPosition;
    using CurrencyLibrary for Currency;
    using CurrencySettleTake for Currency;

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bool claims;
        bytes hookData;
    }

    mapping(address owner => mapping(LiquidityPositionId positionId => uint256 liquidity)) public liquidityOf;

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    // NOTE: handles add/remove/collect
    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes calldata hookData,
        address owner
    ) public payable override returns (BalanceDelta delta) {
        // if removing liquidity, check that the owner is the sender?
        if (params.liquidityDelta < 0) require(msg.sender == owner, "Cannot redeem position");

        delta = abi.decode(
            poolManager.lock(address(this), abi.encode(CallbackData(msg.sender, key, params, false, hookData))),
            (BalanceDelta)
        );

        params.liquidityDelta < 0
            ? liquidityOf[owner][LiquidityPosition(key, params.tickLower, params.tickUpper).toId()] -=
                uint256(-params.liquidityDelta)
            : liquidityOf[owner][LiquidityPosition(key, params.tickLower, params.tickUpper).toId()] +=
                uint256(params.liquidityDelta);

        // TODO: handle & test
        // uint256 ethBalance = address(this).balance;
        // if (ethBalance > 0) {
        //     CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        // }
    }

    function collect(LiquidityPosition memory position, bytes calldata hookData)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            poolManager.lock(
                address(this),
                abi.encode(
                    CallbackData(
                        address(this),
                        position.key,
                        IPoolManager.ModifyLiquidityParams({
                            tickLower: position.tickLower,
                            tickUpper: position.tickUpper,
                            liquidityDelta: 0
                        }),
                        true,
                        hookData
                    )
                )
            ),
            (BalanceDelta)
        );
    }

    function _lockAcquired(bytes calldata rawData) internal override returns (bytes memory result) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = poolManager.modifyLiquidity(data.key, data.params, data.hookData);

        if (data.params.liquidityDelta <= 0) {
            // removing liquidity/fees so take tokens
            data.key.currency0.take(poolManager, data.sender, uint128(-delta.amount0()), data.claims);
            data.key.currency1.take(poolManager, data.sender, uint128(-delta.amount1()), data.claims);
        } else {
            // adding liquidity so pay tokens
            data.key.currency0.settle(poolManager, data.sender, uint128(delta.amount0()), data.claims);
            data.key.currency1.settle(poolManager, data.sender, uint128(delta.amount1()), data.claims);
        }

        result = abi.encode(delta);
    }
}
