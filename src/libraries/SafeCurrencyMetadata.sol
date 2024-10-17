// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {AddressStringUtil} from "./AddressStringUtil.sol";

/// @title SafeCurrencyMetadata
/// @notice can produce symbols and decimals from inconsistent or absent ERC20 implementations
/// @dev Reference: https://github.com/Uniswap/solidity-lib/blob/master/contracts/libraries/SafeERC20Namer.sol
library SafeCurrencyMetadata {
    using CurrencyLibrary for Currency;

    /// @notice attempts to extract the token symbol. if it does not implement symbol, returns a symbol derived from the address
    /// @param currency The currency
    /// @param nativeLabel The native label
    /// @return the token symbol
    function currencySymbol(Currency currency, string memory nativeLabel) internal view returns (string memory) {
        if (currency.isAddressZero()) {
            return nativeLabel;
        }
        address currencyAddress = Currency.unwrap(currency);
        string memory symbol = callAndParseStringReturn(currencyAddress, IERC20Metadata.symbol.selector);
        if (bytes(symbol).length == 0) {
            // fallback to 6 uppercase hex of address
            return addressToSymbol(currencyAddress);
        }
        return symbol;
    }

    /// @notice attempts to extract the token decimals, returns 0 if not implemented or not a uint8
    /// @param currency The currency
    /// @return the token decimals
    function currencyDecimals(Currency currency) internal view returns (uint8) {
        if (currency.isAddressZero()) {
            return 18;
        }
        (bool success, bytes memory data) =
            Currency.unwrap(currency).staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (!success) {
            return 0;
        }
        if (data.length == 32) {
            uint256 decimals = abi.decode(data, (uint256));
            if (decimals <= type(uint8).max) {
                return uint8(decimals);
            }
        }
        return 0;
    }

    function bytes32ToString(bytes32 x) private pure returns (string memory) {
        bytes memory bytesString = new bytes(32);
        uint256 charCount = 0;
        for (uint256 j = 0; j < 32; j++) {
            bytes1 char = x[j];
            if (char != 0) {
                bytesString[charCount] = char;
                charCount++;
            }
        }
        bytes memory bytesStringTrimmed = new bytes(charCount);
        for (uint256 j = 0; j < charCount; j++) {
            bytesStringTrimmed[j] = bytesString[j];
        }
        return string(bytesStringTrimmed);
    }

    /// @notice produces a symbol from the address - the first 6 hex of the address string in upper case
    /// @param currencyAddress the address of the currency
    /// @return the symbol
    function addressToSymbol(address currencyAddress) private pure returns (string memory) {
        return AddressStringUtil.toAsciiString(currencyAddress, 6);
    }

    /// @notice calls an external view contract method that returns a symbol, and parses the output into a string
    /// @param currencyAddress the address of the currency
    /// @param selector the selector of the symbol method
    /// @return the symbol
    function callAndParseStringReturn(address currencyAddress, bytes4 selector) private view returns (string memory) {
        (bool success, bytes memory data) = currencyAddress.staticcall(abi.encodeWithSelector(selector));
        // if not implemented, return empty string
        if (!success) {
            return "";
        }
        // bytes32 data always has length 32
        if (data.length == 32) {
            bytes32 decoded = abi.decode(data, (bytes32));
            return bytes32ToString(decoded);
        } else if (data.length > 64) {
            return abi.decode(data, (string));
        }
        return "";
    }
}
