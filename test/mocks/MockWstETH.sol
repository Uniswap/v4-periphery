// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IWstETH} from "../../src/interfaces/external/IWstETH.sol";

/// @title Mock Wrapped Staked ETH
/// @notice Mock implementation of wstETH for testing
/// @dev Uses a fixed 1.1 stETH/wstETH exchange rate
contract MockWstETH is MockERC20, IWstETH {
    /// @notice The underlying stETH token
    address public immutable stETH;

    /// @notice Fixed exchange rate: 1 wstETH = 1.1 stETH
    uint256 public constant EXCHANGE_RATE = 11e17;

    /// @notice Creates a new mock wstETH
    /// @param _stETH Address of the mock stETH token
    constructor(address _stETH) MockERC20("Wrapped Staked ETH", "wstETH", 18) {
        stETH = _stETH;
    }

    /// @notice Wraps stETH to wstETH
    /// @param _stETHAmount Amount of stETH to wrap
    /// @return Amount of wstETH received
    function wrap(uint256 _stETHAmount) external returns (uint256) {
        // Transfer stETH from sender
        MockERC20(stETH).transferFrom(msg.sender, address(this), _stETHAmount);

        // Calculate wstETH amount using exchange rate
        uint256 wstETHAmount = getWstETHByStETH(_stETHAmount);

        // Mint wstETH to sender
        _mint(msg.sender, wstETHAmount);

        return wstETHAmount;
    }

    /// @notice Unwraps wstETH to stETH
    /// @param _wstETHAmount Amount of wstETH to unwrap
    /// @return Amount of stETH received
    function unwrap(uint256 _wstETHAmount) external returns (uint256) {
        // Burn wstETH from sender
        _burn(msg.sender, _wstETHAmount);

        // Calculate stETH amount using exchange rate
        uint256 stETHAmount = getStETHByWstETH(_wstETHAmount);

        // Transfer stETH to sender
        MockERC20(stETH).transfer(msg.sender, stETHAmount);

        return stETHAmount;
    }

    function getWstETHByStETH(uint256 _stETHAmount) public pure returns (uint256) {
        if (_stETHAmount == 0) return 0;
        // Multiply first to maintain precision
        uint256 numerator = _stETHAmount * 1e18;
        // Add half the denominator for proper rounding
        uint256 rounded = (numerator + EXCHANGE_RATE / 2) / EXCHANGE_RATE;
        return rounded;
    }

    function getStETHByWstETH(uint256 _wstETHAmount) public pure returns (uint256) {
        if (_wstETHAmount == 0) return 0;
        // Multiply first to maintain precision
        uint256 numerator = _wstETHAmount * EXCHANGE_RATE;
        // Add half the denominator for proper rounding
        uint256 rounded = (numerator + 1e18 / 2) / 1e18;
        return rounded;
    }

    /// @notice Returns stETH per wstETH exchange rate
    /// @return Exchange rate with 18 decimals
    function stEthPerToken() external pure returns (uint256) {
        return EXCHANGE_RATE;
    }

    /// @notice Returns wstETH per stETH exchange rate
    /// @return Exchange rate with 18 decimals
    function tokensPerStEth() external pure returns (uint256) {
        return 1e36 / EXCHANGE_RATE;
    }
}
