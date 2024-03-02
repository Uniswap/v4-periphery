// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {LiquidityPosition, LiquidityPositionId, LiquidityPositionIdLibrary} from "../types/LiquidityPositionId.sol";
import {IBaseLiquidityManagement} from "../interfaces/IBaseLiquidityManagement.sol";
import {SafeCallback} from "./SafeCallback.sol";
import {ImmutableState} from "./ImmutableState.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

abstract contract BaseLiquidityManagement is SafeCallback, IBaseLiquidityManagement {
    using LiquidityPositionIdLibrary for LiquidityPosition;
    using CurrencyLibrary for Currency;

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyPositionParams params;
        bytes hookData;
    }

    mapping(address owner => mapping(LiquidityPositionId positionId => uint256 liquidity)) public liquidityOf;

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    // NOTE: handles add/remove/collect
    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyPositionParams memory params,
        bytes calldata hookData,
        address owner
    ) public payable override returns (BalanceDelta delta) {
        // if removing liquidity, check that the owner is the sender?
        if (params.liquidityDelta < 0) require(msg.sender == owner, "Cannot redeem position");

        delta =
            abi.decode(poolManager.lock(abi.encode(CallbackData(msg.sender, key, params, hookData))), (BalanceDelta));

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

    function _lockAcquired(bytes calldata rawData) internal override returns (bytes memory result) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta = poolManager.modifyPosition(data.key, data.params, data.hookData);

        if (data.params.liquidityDelta <= 0) {
            // removing liquidity/fees so take tokens
            poolManager.take(data.key.currency0, data.sender, uint128(-delta.amount0()));
            poolManager.take(data.key.currency1, data.sender, uint128(-delta.amount1()));
        } else {
            // adding liquidity so pay tokens
            _settle(data.sender, data.key.currency0, uint128(delta.amount0()));
            _settle(data.sender, data.key.currency1, uint128(delta.amount1()));
        }

        result = abi.encode(delta);
    }

    function _settle(address payer, Currency currency, uint256 amount) internal {
        if (currency.isNative()) {
            poolManager.settle{value: uint128(amount)}(currency);
        } else {
            IERC20(Currency.unwrap(currency)).transferFrom(payer, address(poolManager), uint128(amount));
            poolManager.settle(currency);
        }
    }
}
