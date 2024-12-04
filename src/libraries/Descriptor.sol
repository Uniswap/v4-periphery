// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {SVG} from "./SVG.sol";
import {HexStrings} from "./HexStrings.sol";

/// @title Descriptor
/// @notice Describes NFT token positions
/// @dev Reference: https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/NFTDescriptor.sol
library Descriptor {
    using TickMath for int24;
    using Strings for uint256;
    using HexStrings for uint256;
    using LPFeeLibrary for uint24;

    uint256 constant sqrt10X128 = 1076067327063303206878105757264492625226;

    struct ConstructTokenURIParams {
        uint256 tokenId;
        address quoteCurrency;
        address baseCurrency;
        string quoteCurrencySymbol;
        string baseCurrencySymbol;
        uint8 quoteCurrencyDecimals;
        uint8 baseCurrencyDecimals;
        bool flipRatio;
        int24 tickLower;
        int24 tickUpper;
        int24 tickCurrent;
        int24 tickSpacing;
        uint24 fee;
        address poolManager;
        address hooks;
    }

    /// @notice Constructs the token URI for a Uniswap v4 NFT
    /// @param params Parameters needed to construct the token URI
    /// @return The token URI as a string
    function constructTokenURI(ConstructTokenURIParams memory params) internal pure returns (string memory) {
        string memory name = generateName(params, feeToPercentString(params.fee));
        string memory descriptionPartOne = generateDescriptionPartOne(
            escapeSpecialCharacters(params.quoteCurrencySymbol),
            escapeSpecialCharacters(params.baseCurrencySymbol),
            addressToString(params.poolManager)
        );
        string memory descriptionPartTwo = generateDescriptionPartTwo(
            params.tokenId.toString(),
            escapeSpecialCharacters(params.baseCurrencySymbol),
            params.quoteCurrency == address(0) ? "Native" : addressToString(params.quoteCurrency),
            params.baseCurrency == address(0) ? "Native" : addressToString(params.baseCurrency),
            params.hooks == address(0) ? "No Hook" : addressToString(params.hooks),
            feeToPercentString(params.fee)
        );
        string memory image = Base64.encode(bytes(generateSVGImage(params)));

        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            '{"name":"',
                            name,
                            '", "description":"',
                            descriptionPartOne,
                            descriptionPartTwo,
                            '", "image": "',
                            "data:image/svg+xml;base64,",
                            image,
                            '"}'
                        )
                    )
                )
            )
        );
    }

    /// @notice Escapes special characters in a string if they are present
    function escapeSpecialCharacters(string memory symbol) internal pure returns (string memory) {
        bytes memory symbolBytes = bytes(symbol);
        uint8 specialCharCount = 0;
        // count the amount of double quotes, form feeds, new lines, carriage returns, or tabs in the symbol
        for (uint8 i = 0; i < symbolBytes.length; i++) {
            if (isSpecialCharacter(symbolBytes[i])) {
                specialCharCount++;
            }
        }
        if (specialCharCount > 0) {
            // create a new bytes array with enough space to hold the original bytes plus space for the backslashes to escape the special characters
            bytes memory escapedBytes = new bytes(symbolBytes.length + specialCharCount);
            uint256 index;
            for (uint8 i = 0; i < symbolBytes.length; i++) {
                // add a '\' before any double quotes, form feeds, new lines, carriage returns, or tabs
                if (isSpecialCharacter(symbolBytes[i])) {
                    escapedBytes[index++] = "\\";
                }
                // copy each byte from original string to the new array
                escapedBytes[index++] = symbolBytes[i];
            }
            return string(escapedBytes);
        }
        return symbol;
    }

    /// @notice Generates the first part of the description for a Uniswap v4 NFT
    /// @param quoteCurrencySymbol The symbol of the quote currency
    /// @param baseCurrencySymbol The symbol of the base currency
    /// @param poolManager The address of the pool manager
    /// @return The first part of the description
    function generateDescriptionPartOne(
        string memory quoteCurrencySymbol,
        string memory baseCurrencySymbol,
        string memory poolManager
    ) private pure returns (string memory) {
        // displays quote currency first, then base currency
        return string(
            abi.encodePacked(
                "This NFT represents a liquidity position in a Uniswap v4 ",
                quoteCurrencySymbol,
                "-",
                baseCurrencySymbol,
                " pool. ",
                "The owner of this NFT can modify or redeem the position.\\n",
                "\\nPool Manager Address: ",
                poolManager,
                "\\n",
                quoteCurrencySymbol
            )
        );
    }

    /// @notice Generates the second part of the description for a Uniswap v4 NFTs
    /// @param tokenId The token ID
    /// @param baseCurrencySymbol The symbol of the base currency
    /// @param quoteCurrency The address of the quote currency
    /// @param baseCurrency The address of the base currency
    /// @param hooks The address of the hooks contract
    /// @param feeTier The fee tier of the pool
    /// @return The second part of the description
    function generateDescriptionPartTwo(
        string memory tokenId,
        string memory baseCurrencySymbol,
        string memory quoteCurrency,
        string memory baseCurrency,
        string memory hooks,
        string memory feeTier
    ) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                " Address: ",
                quoteCurrency,
                "\\n",
                baseCurrencySymbol,
                " Address: ",
                baseCurrency,
                "\\nHook Address: ",
                hooks,
                "\\nFee Tier: ",
                feeTier,
                "\\nToken ID: ",
                tokenId,
                "\\n\\n",
                unicode"⚠️ DISCLAIMER: Due diligence is imperative when assessing this NFT. Make sure currency addresses match the expected currencies, as currency symbols may be imitated."
            )
        );
    }

    /// @notice Generates the name for a Uniswap v4 NFT
    /// @param params Parameters needed to generate the name
    /// @param feeTier The fee tier of the pool
    /// @return The name of the NFT
    function generateName(ConstructTokenURIParams memory params, string memory feeTier)
        private
        pure
        returns (string memory)
    {
        // image shows in terms of price, ie quoteCurrency/baseCurrency
        return string(
            abi.encodePacked(
                "Uniswap - ",
                feeTier,
                " - ",
                escapeSpecialCharacters(params.quoteCurrencySymbol),
                "/",
                escapeSpecialCharacters(params.baseCurrencySymbol),
                " - ",
                tickToDecimalString(
                    !params.flipRatio ? params.tickLower : params.tickUpper,
                    params.tickSpacing,
                    params.baseCurrencyDecimals,
                    params.quoteCurrencyDecimals,
                    params.flipRatio
                ),
                "<>",
                tickToDecimalString(
                    !params.flipRatio ? params.tickUpper : params.tickLower,
                    params.tickSpacing,
                    params.baseCurrencyDecimals,
                    params.quoteCurrencyDecimals,
                    params.flipRatio
                )
            )
        );
    }

    struct DecimalStringParams {
        // significant figures of decimal
        uint256 sigfigs;
        // length of decimal string
        uint8 bufferLength;
        // ending index for significant figures (funtion works backwards when copying sigfigs)
        uint8 sigfigIndex;
        // index of decimal place (0 if no decimal)
        uint8 decimalIndex;
        // start index for trailing/leading 0's for very small/large numbers
        uint8 zerosStartIndex;
        // end index for trailing/leading 0's for very small/large numbers
        uint8 zerosEndIndex;
        // true if decimal number is less than one
        bool isLessThanOne;
        // true if string should include "%"
        bool isPercent;
    }

    function generateDecimalString(DecimalStringParams memory params) private pure returns (string memory) {
        bytes memory buffer = new bytes(params.bufferLength);
        if (params.isPercent) {
            buffer[buffer.length - 1] = "%";
        }
        if (params.isLessThanOne) {
            buffer[0] = "0";
            buffer[1] = ".";
        }

        // add leading/trailing 0's
        for (uint256 zerosCursor = params.zerosStartIndex; zerosCursor < params.zerosEndIndex + 1; zerosCursor++) {
            // converts the ASCII code for 0 (which is 48) into a bytes1 to store in the buffer
            buffer[zerosCursor] = bytes1(uint8(48));
        }
        // add sigfigs
        while (params.sigfigs > 0) {
            if (params.decimalIndex > 0 && params.sigfigIndex == params.decimalIndex) {
                buffer[params.sigfigIndex--] = ".";
            }
            buffer[params.sigfigIndex] = bytes1(uint8(48 + (params.sigfigs % 10)));
            // can overflow when sigfigIndex = 0
            unchecked {
                params.sigfigIndex--;
            }
            params.sigfigs /= 10;
        }
        return string(buffer);
    }

    /// @notice Gets the price (quote/base) at a specific tick in decimal form
    /// MIN or MAX are returned if tick is at the bottom or top of the price curve
    /// @param tick The tick (either tickLower or tickUpper)
    /// @param tickSpacing The tick spacing of the pool
    /// @param baseCurrencyDecimals The decimals of the base currency
    /// @param quoteCurrencyDecimals The decimals of the quote currency
    /// @param flipRatio True if the ratio was flipped
    /// @return The ratio value as a string
    function tickToDecimalString(
        int24 tick,
        int24 tickSpacing,
        uint8 baseCurrencyDecimals,
        uint8 quoteCurrencyDecimals,
        bool flipRatio
    ) internal pure returns (string memory) {
        if (tick == (TickMath.MIN_TICK / tickSpacing) * tickSpacing) {
            return !flipRatio ? "MIN" : "MAX";
        } else if (tick == (TickMath.MAX_TICK / tickSpacing) * tickSpacing) {
            return !flipRatio ? "MAX" : "MIN";
        } else {
            uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);
            if (flipRatio) {
                sqrtRatioX96 = uint160(uint256(1 << 192) / sqrtRatioX96);
            }
            return fixedPointToDecimalString(sqrtRatioX96, baseCurrencyDecimals, quoteCurrencyDecimals);
        }
    }

    function sigfigsRounded(uint256 value, uint8 digits) private pure returns (uint256, bool) {
        bool extraDigit;
        if (digits > 5) {
            value = value / (10 ** (digits - 5));
        }
        bool roundUp = value % 10 > 4;
        value = value / 10;
        if (roundUp) {
            value = value + 1;
        }
        // 99999 -> 100000 gives an extra sigfig
        if (value == 100000) {
            value /= 10;
            extraDigit = true;
        }
        return (value, extraDigit);
    }

    /// @notice Adjusts the sqrt price for different currencies with different decimals
    /// @param sqrtRatioX96 The sqrt price at a specific tick
    /// @param baseCurrencyDecimals The decimals of the base currency
    /// @param quoteCurrencyDecimals The decimals of the quote currency
    /// @return adjustedSqrtRatioX96 The adjusted sqrt price
    function adjustForDecimalPrecision(uint160 sqrtRatioX96, uint8 baseCurrencyDecimals, uint8 quoteCurrencyDecimals)
        private
        pure
        returns (uint256 adjustedSqrtRatioX96)
    {
        uint256 difference = abs(int256(uint256(baseCurrencyDecimals)) - (int256(uint256(quoteCurrencyDecimals))));
        if (difference > 0 && difference <= 18) {
            if (baseCurrencyDecimals > quoteCurrencyDecimals) {
                adjustedSqrtRatioX96 = sqrtRatioX96 * (10 ** (difference / 2));
                if (difference % 2 == 1) {
                    adjustedSqrtRatioX96 = FullMath.mulDiv(adjustedSqrtRatioX96, sqrt10X128, 1 << 128);
                }
            } else {
                adjustedSqrtRatioX96 = sqrtRatioX96 / (10 ** (difference / 2));
                if (difference % 2 == 1) {
                    adjustedSqrtRatioX96 = FullMath.mulDiv(adjustedSqrtRatioX96, 1 << 128, sqrt10X128);
                }
            }
        } else {
            adjustedSqrtRatioX96 = uint256(sqrtRatioX96);
        }
    }

    /// @notice Absolute value of a signed integer
    /// @param x The signed integer
    /// @return The absolute value of x
    function abs(int256 x) private pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    function fixedPointToDecimalString(uint160 sqrtRatioX96, uint8 baseCurrencyDecimals, uint8 quoteCurrencyDecimals)
        internal
        pure
        returns (string memory)
    {
        uint256 adjustedSqrtRatioX96 =
            adjustForDecimalPrecision(sqrtRatioX96, baseCurrencyDecimals, quoteCurrencyDecimals);
        uint256 value = FullMath.mulDiv(adjustedSqrtRatioX96, adjustedSqrtRatioX96, 1 << 64);

        bool priceBelow1 = adjustedSqrtRatioX96 < 2 ** 96;
        if (priceBelow1) {
            // 10 ** 43 is precision needed to retreive 5 sigfigs of smallest possible price + 1 for rounding
            value = FullMath.mulDiv(value, 10 ** 44, 1 << 128);
        } else {
            // leave precision for 4 decimal places + 1 place for rounding
            value = FullMath.mulDiv(value, 10 ** 5, 1 << 128);
        }

        // get digit count
        uint256 temp = value;
        uint8 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        // don't count extra digit kept for rounding
        digits = digits - 1;

        // address rounding
        (uint256 sigfigs, bool extraDigit) = sigfigsRounded(value, digits);
        if (extraDigit) {
            digits++;
        }

        DecimalStringParams memory params;
        if (priceBelow1) {
            // 7 bytes ( "0." and 5 sigfigs) + leading 0's bytes
            params.bufferLength = uint8(uint8(7) + (uint8(43) - digits));
            params.zerosStartIndex = 2;
            params.zerosEndIndex = uint8(uint256(43) - digits + 1);
            params.sigfigIndex = uint8(params.bufferLength - 1);
        } else if (digits >= 9) {
            // no decimal in price string
            params.bufferLength = uint8(digits - 4);
            params.zerosStartIndex = 5;
            params.zerosEndIndex = uint8(params.bufferLength - 1);
            params.sigfigIndex = 4;
        } else {
            // 5 sigfigs surround decimal
            params.bufferLength = 6;
            params.sigfigIndex = 5;
            params.decimalIndex = uint8(digits - 5 + 1);
        }
        params.sigfigs = sigfigs;
        params.isLessThanOne = priceBelow1;
        params.isPercent = false;

        return generateDecimalString(params);
    }

    /// @notice Converts fee amount in pips to decimal string with percent sign
    /// @param fee fee amount
    /// @return fee as a decimal string with percent sign
    function feeToPercentString(uint24 fee) internal pure returns (string memory) {
        if (fee.isDynamicFee()) {
            return "Dynamic";
        }
        if (fee == 0) {
            return "0%";
        }
        uint24 temp = fee;
        uint256 digits;
        uint8 numSigfigs;
        // iterates over each digit of fee by dividing temp by 10 in each iteration until temp becomes 0
        // calculates number of digits and number of significant figures (non-zero digits)
        while (temp != 0) {
            if (numSigfigs > 0) {
                // count all digits preceding least significant figure
                numSigfigs++;
            } else if (temp % 10 != 0) {
                numSigfigs++;
            }
            digits++;
            temp /= 10;
        }

        DecimalStringParams memory params;
        uint256 nZeros;
        if (digits >= 5) {
            // represents fee greater than or equal to 1%
            // if decimal > 1 (5th digit is the ones place)
            uint256 decimalPlace = digits - numSigfigs >= 4 ? 0 : 1;
            nZeros = digits - 5 < numSigfigs - 1 ? 0 : digits - 5 - (numSigfigs - 1);
            params.zerosStartIndex = numSigfigs;
            params.zerosEndIndex = uint8(params.zerosStartIndex + nZeros - 1);
            params.sigfigIndex = uint8(params.zerosStartIndex - 1 + decimalPlace);
            params.bufferLength = uint8(nZeros + numSigfigs + 1 + decimalPlace);
        } else {
            // represents fee less than 1%
            // else if decimal < 1
            nZeros = 5 - digits; // number of zeros, inlcuding the zero before decimal
            params.zerosStartIndex = 2; // leading zeros will start after the decimal point
            params.zerosEndIndex = uint8(nZeros + params.zerosStartIndex - 1); // end index for leading zeros
            params.bufferLength = uint8(nZeros + numSigfigs + 2); // total length of string buffer, including "0." and "%"
            params.sigfigIndex = uint8(params.bufferLength - 2); // index of starting signficant figure
            params.isLessThanOne = true;
        }
        params.sigfigs = uint256(fee) / (10 ** (digits - numSigfigs)); // the signficant figures of the fee
        params.isPercent = true;
        params.decimalIndex = digits > 4 ? uint8(digits - 4) : 0; // based on total number of digits in the fee

        return generateDecimalString(params);
    }

    function addressToString(address addr) internal pure returns (string memory) {
        return (uint256(uint160(addr))).toHexString(20);
    }

    /// @notice Generates the SVG image for a Uniswap v4 NFT
    /// @param params Parameters needed to generate the SVG image
    /// @return svg The SVG image as a string
    function generateSVGImage(ConstructTokenURIParams memory params) internal pure returns (string memory svg) {
        SVG.SVGParams memory svgParams = SVG.SVGParams({
            quoteCurrency: addressToString(params.quoteCurrency),
            baseCurrency: addressToString(params.baseCurrency),
            hooks: params.hooks,
            quoteCurrencySymbol: params.quoteCurrencySymbol,
            baseCurrencySymbol: params.baseCurrencySymbol,
            feeTier: feeToPercentString(params.fee),
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            tickSpacing: params.tickSpacing,
            overRange: overRange(params.tickLower, params.tickUpper, params.tickCurrent),
            tokenId: params.tokenId,
            color0: currencyToColorHex(uint256(uint160(params.quoteCurrency)), 136),
            color1: currencyToColorHex(uint256(uint160(params.baseCurrency)), 136),
            color2: currencyToColorHex(uint256(uint160(params.quoteCurrency)), 0),
            color3: currencyToColorHex(uint256(uint160(params.baseCurrency)), 0),
            x1: scale(getCircleCoord(uint256(uint160(params.quoteCurrency)), 16, params.tokenId), 0, 255, 16, 274),
            y1: scale(getCircleCoord(uint256(uint160(params.baseCurrency)), 16, params.tokenId), 0, 255, 100, 484),
            x2: scale(getCircleCoord(uint256(uint160(params.quoteCurrency)), 32, params.tokenId), 0, 255, 16, 274),
            y2: scale(getCircleCoord(uint256(uint160(params.baseCurrency)), 32, params.tokenId), 0, 255, 100, 484),
            x3: scale(getCircleCoord(uint256(uint160(params.quoteCurrency)), 48, params.tokenId), 0, 255, 16, 274),
            y3: scale(getCircleCoord(uint256(uint160(params.baseCurrency)), 48, params.tokenId), 0, 255, 100, 484)
        });

        return SVG.generateSVG(svgParams);
    }

    /// @notice Checks if the current price is within your position range, above, or below
    /// @param tickLower The lower tick
    /// @param tickUpper The upper tick
    /// @param tickCurrent The current tick
    /// @return 0 if the current price is within the position range, -1 if below, 1 if above
    function overRange(int24 tickLower, int24 tickUpper, int24 tickCurrent) private pure returns (int8) {
        if (tickCurrent < tickLower) {
            return -1;
        } else if (tickCurrent > tickUpper) {
            return 1;
        } else {
            return 0;
        }
    }

    function isSpecialCharacter(bytes1 b) private pure returns (bool) {
        return b == '"' || b == "\u000c" || b == "\n" || b == "\r" || b == "\t";
    }

    function scale(uint256 n, uint256 inMn, uint256 inMx, uint256 outMn, uint256 outMx)
        private
        pure
        returns (string memory)
    {
        return ((n - inMn) * (outMx - outMn) / (inMx - inMn) + outMn).toString();
    }

    function currencyToColorHex(uint256 currency, uint256 offset) internal pure returns (string memory str) {
        return string((currency >> offset).toHexStringNoPrefix(3));
    }

    function getCircleCoord(uint256 currency, uint256 offset, uint256 tokenId) internal pure returns (uint256) {
        return (sliceCurrencyHex(currency, offset) * tokenId) % 255;
    }

    function sliceCurrencyHex(uint256 currency, uint256 offset) internal pure returns (uint256) {
        return uint256(uint8(currency >> offset));
    }
}
