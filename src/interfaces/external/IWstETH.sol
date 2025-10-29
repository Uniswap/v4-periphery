// SPDX-FileCopyrightText: 2021 Lido <info@lido.fi>
// https://github.com/lidofinance/core/blob/master/contracts/0.6.12/WstETH.sol

// SPDX-License-Identifier: GPL-3.0

/* See contracts/COMPILERS.md */
pragma solidity ^0.8.0;

interface IWstETH {
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _wstETHAmount) external returns (uint256);
    function getStETHByWstETH(uint256 _wstETHAmount) external view returns (uint256);
    function getWstETHByStETH(uint256 _stETHAmount) external view returns (uint256);
    function tokensPerStEth() external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
    function stETH() external view returns (address);
}

interface IStETH {
    function getSharesByPooledEth(uint256 stEthAmount) external view returns (uint256);
    function getPooledEthByShares(uint256 _sharesAmount) external view returns (uint256);
    function sharesOf(address _account) external view returns (uint256);
    function transferShares(address recipient, uint256 shares) external;
    function balanceOf(address _account) external view returns (uint256);
}
