// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IWstETH, IStETH} from "../interfaces/external/IWstETH.sol";
import {WstETHHook, BaseTokenWrapperHook, IPoolManager, Currency} from "./WstETHHook.sol";

/// @title WstETHRoutingHook
/// @notice A hook that allows simulating the WstETHHook with the v4 Quoter
/// @dev The WstETHHook takes the amount deposited by the swapper into the PoolManager and wraps it to wstETH. When simulating the WstETHHook, no underlying stETH are deposited into the PoolManager and the WstETHHook reverts. This hook acts as a replacement for the WstETHHook in the Quoter and calculates the amount of wstETH that would be minted by the WstETHHook, without executing the actual wrapping.
/// @dev The withdraw function doesn't need to be overridden, as the PoolManager has a sufficient balance of WstETH to cover the withdrawal in the simulation.
contract WstETHRoutingHook is WstETHHook {
    constructor(IPoolManager _poolManager, IWstETH _wstETH) WstETHHook(_poolManager, _wstETH) {}

    /// @inheritdoc BaseTokenWrapperHook
    function _deposit(uint256 underlyingAmount)
        internal
        view
        override
        returns (uint256 actualUnderlyingAmount, uint256 wrappedAmount)
    {
        // simulate taking stETH from the PoolManager
        // _take(underlyingCurrency, address(this), underlyingAmount);
        // actualUnderlyingAmount = stETH.balanceOf(address(this));
        //
        // when calling take on the PoolManager the amount is rounded down to the nearest share
        // the following code calculates the amount of shares that would be transferred by the PoolManager and their corresponding amount of ETH
        IStETH stETH = IStETH(Currency.unwrap(underlyingCurrency));
        uint256 transferredShares = stETH.getSharesByPooledEth(underlyingAmount);
        actualUnderlyingAmount = stETH.getPooledEthByShares(transferredShares);

        // simulate wrapping stETH to wstETH
        // wrappedAmount = wstETH.wrap(actualUnderlyingAmount);
        // _settle(wrapperCurrency, address(this), wrappedAmount);
        //
        // when wrapping stETH to wstETH the amount of wstETH minted is calculated by the current stETH/wstETH exchange rate
        wrappedAmount = wstETH.getWstETHByStETH(actualUnderlyingAmount);
    }
}
