// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";

/// @title SVG
/// @notice Provides a function for generating an SVG associated with a Uniswap NFT
/// @dev Reference: https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/NFTSVG.sol
library SVG {
    using Strings for uint256;

    // SVG path commands for the curve that represent the steepness of the position
    // defined using the Cubic Bezier Curve syntax
    // curve1 is the smallest (linear) curve, curve8 is the largest curve
    string constant curve1 = "M1 1C41 41 105 105 145 145";
    string constant curve2 = "M1 1C33 49 97 113 145 145";
    string constant curve3 = "M1 1C33 57 89 113 145 145";
    string constant curve4 = "M1 1C25 65 81 121 145 145";
    string constant curve5 = "M1 1C17 73 73 129 145 145";
    string constant curve6 = "M1 1C9 81 65 137 145 145";
    string constant curve7 = "M1 1C1 89 57.5 145 145 145";
    string constant curve8 = "M1 1C1 97 49 145 145 145";

    struct SVGParams {
        string quoteCurrency;
        string baseCurrency;
        address hooks;
        string quoteCurrencySymbol;
        string baseCurrencySymbol;
        string feeTier;
        int24 tickLower;
        int24 tickUpper;
        int24 tickSpacing;
        int8 overRange;
        uint256 tokenId;
        string color0;
        string color1;
        string color2;
        string color3;
        string x1;
        string y1;
        string x2;
        string y2;
        string x3;
        string y3;
    }

    /// @notice Generate the SVG associated with a Uniswap v4 NFT
    /// @param params The SVGParams struct containing the parameters for the SVG
    /// @return svg The SVG string associated with the NFT
    function generateSVG(SVGParams memory params) internal pure returns (string memory svg) {
        return string(
            abi.encodePacked(
                generateSVGDefs(params),
                generateSVGBorderText(
                    params.quoteCurrency, params.baseCurrency, params.quoteCurrencySymbol, params.baseCurrencySymbol
                ),
                generateSVGCardMantle(params.quoteCurrencySymbol, params.baseCurrencySymbol, params.feeTier),
                generageSvgCurve(params.tickLower, params.tickUpper, params.tickSpacing, params.overRange),
                generateSVGPositionDataAndLocationCurve(
                    params.tokenId.toString(), params.hooks, params.tickLower, params.tickUpper
                ),
                generateSVGRareSparkle(params.tokenId, params.hooks),
                "</svg>"
            )
        );
    }

    /// @notice Generate the SVG defs that create the color scheme for the SVG
    /// @param params The SVGParams struct containing the parameters to generate the SVG defs
    /// @return svg The SVG defs string
    function generateSVGDefs(SVGParams memory params) private pure returns (string memory svg) {
        svg = string(
            abi.encodePacked(
                '<svg width="290" height="500" viewBox="0 0 290 500" xmlns="http://www.w3.org/2000/svg"',
                " xmlns:xlink='http://www.w3.org/1999/xlink'>",
                "<defs>",
                '<filter id="f1"><feImage result="p0" xlink:href="data:image/svg+xml;base64,',
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            "<svg width='290' height='500' viewBox='0 0 290 500' xmlns='http://www.w3.org/2000/svg'><rect width='290px' height='500px' fill='#",
                            params.color0,
                            "'/></svg>"
                        )
                    )
                ),
                '"/><feImage result="p1" xlink:href="data:image/svg+xml;base64,',
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            "<svg width='290' height='500' viewBox='0 0 290 500' xmlns='http://www.w3.org/2000/svg'><circle cx='",
                            params.x1,
                            "' cy='",
                            params.y1,
                            "' r='120px' fill='#",
                            params.color1,
                            "'/></svg>"
                        )
                    )
                ),
                '"/><feImage result="p2" xlink:href="data:image/svg+xml;base64,',
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            "<svg width='290' height='500' viewBox='0 0 290 500' xmlns='http://www.w3.org/2000/svg'><circle cx='",
                            params.x2,
                            "' cy='",
                            params.y2,
                            "' r='120px' fill='#",
                            params.color2,
                            "'/></svg>"
                        )
                    )
                ),
                '" />',
                '<feImage result="p3" xlink:href="data:image/svg+xml;base64,',
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            "<svg width='290' height='500' viewBox='0 0 290 500' xmlns='http://www.w3.org/2000/svg'><circle cx='",
                            params.x3,
                            "' cy='",
                            params.y3,
                            "' r='100px' fill='#",
                            params.color3,
                            "'/></svg>"
                        )
                    )
                ),
                '" /><feBlend mode="overlay" in="p0" in2="p1" /><feBlend mode="exclusion" in2="p2" /><feBlend mode="overlay" in2="p3" result="blendOut" /><feGaussianBlur ',
                'in="blendOut" stdDeviation="42" /></filter> <clipPath id="corners"><rect width="290" height="500" rx="42" ry="42" /></clipPath>',
                '<path id="text-path-a" d="M40 12 H250 A28 28 0 0 1 278 40 V460 A28 28 0 0 1 250 488 H40 A28 28 0 0 1 12 460 V40 A28 28 0 0 1 40 12 z" />',
                '<path id="minimap" d="M234 444C234 457.949 242.21 463 253 463" />',
                '<filter id="top-region-blur"><feGaussianBlur in="SourceGraphic" stdDeviation="24" /></filter>',
                '<linearGradient id="grad-up" x1="1" x2="0" y1="1" y2="0"><stop offset="0.0" stop-color="white" stop-opacity="1" />',
                '<stop offset=".9" stop-color="white" stop-opacity="0" /></linearGradient>',
                '<linearGradient id="grad-down" x1="0" x2="1" y1="0" y2="1"><stop offset="0.0" stop-color="white" stop-opacity="1" /><stop offset="0.9" stop-color="white" stop-opacity="0" /></linearGradient>',
                '<mask id="fade-up" maskContentUnits="objectBoundingBox"><rect width="1" height="1" fill="url(#grad-up)" /></mask>',
                '<mask id="fade-down" maskContentUnits="objectBoundingBox"><rect width="1" height="1" fill="url(#grad-down)" /></mask>',
                '<mask id="none" maskContentUnits="objectBoundingBox"><rect width="1" height="1" fill="white" /></mask>',
                '<linearGradient id="grad-symbol"><stop offset="0.7" stop-color="white" stop-opacity="1" /><stop offset=".95" stop-color="white" stop-opacity="0" /></linearGradient>',
                '<mask id="fade-symbol" maskContentUnits="userSpaceOnUse"><rect width="290px" height="200px" fill="url(#grad-symbol)" /></mask></defs>',
                '<g clip-path="url(#corners)">',
                '<rect fill="',
                params.color0,
                '" x="0px" y="0px" width="290px" height="500px" />',
                '<rect style="filter: url(#f1)" x="0px" y="0px" width="290px" height="500px" />',
                ' <g style="filter:url(#top-region-blur); transform:scale(1.5); transform-origin:center top;">',
                '<rect fill="none" x="0px" y="0px" width="290px" height="500px" />',
                '<ellipse cx="50%" cy="0px" rx="180px" ry="120px" fill="#000" opacity="0.85" /></g>',
                '<rect x="0" y="0" width="290" height="500" rx="42" ry="42" fill="rgba(0,0,0,0)" stroke="rgba(255,255,255,0.2)" /></g>'
            )
        );
    }

    /// @notice Generate the SVG for the moving border text displaying the quote and base currency addresses with their symbols
    /// @param quoteCurrency The quote currency
    /// @param baseCurrency The base currency
    /// @param quoteCurrencySymbol The quote currency symbol
    /// @param baseCurrencySymbol The base currency symbol
    /// @return svg The SVG for the border NFT's border text
    function generateSVGBorderText(
        string memory quoteCurrency,
        string memory baseCurrency,
        string memory quoteCurrencySymbol,
        string memory baseCurrencySymbol
    ) private pure returns (string memory svg) {
        svg = string(
            abi.encodePacked(
                '<text text-rendering="optimizeSpeed">',
                '<textPath startOffset="-100%" fill="white" font-family="\'Courier New\', monospace" font-size="10px" xlink:href="#text-path-a">',
                baseCurrency,
                unicode" • ",
                baseCurrencySymbol,
                ' <animate additive="sum" attributeName="startOffset" from="0%" to="100%" begin="0s" dur="30s" repeatCount="indefinite" />',
                '</textPath> <textPath startOffset="0%" fill="white" font-family="\'Courier New\', monospace" font-size="10px" xlink:href="#text-path-a">',
                baseCurrency,
                unicode" • ",
                baseCurrencySymbol,
                ' <animate additive="sum" attributeName="startOffset" from="0%" to="100%" begin="0s" dur="30s" repeatCount="indefinite" /> </textPath>',
                '<textPath startOffset="50%" fill="white" font-family="\'Courier New\', monospace" font-size="10px" xlink:href="#text-path-a">',
                quoteCurrency,
                unicode" • ",
                quoteCurrencySymbol,
                ' <animate additive="sum" attributeName="startOffset" from="0%" to="100%" begin="0s" dur="30s"',
                ' repeatCount="indefinite" /></textPath><textPath startOffset="-50%" fill="white" font-family="\'Courier New\', monospace" font-size="10px" xlink:href="#text-path-a">',
                quoteCurrency,
                unicode" • ",
                quoteCurrencySymbol,
                ' <animate additive="sum" attributeName="startOffset" from="0%" to="100%" begin="0s" dur="30s" repeatCount="indefinite" /></textPath></text>'
            )
        );
    }

    /// @notice Generate the SVG for the card mantle displaying the quote and base currency symbols and fee tier
    /// @param quoteCurrencySymbol The quote currency symbol
    /// @param baseCurrencySymbol The base currency symbol
    /// @param feeTier The fee tier
    /// @return svg The SVG for the card mantle
    function generateSVGCardMantle(
        string memory quoteCurrencySymbol,
        string memory baseCurrencySymbol,
        string memory feeTier
    ) private pure returns (string memory svg) {
        svg = string(
            abi.encodePacked(
                '<g mask="url(#fade-symbol)"><rect fill="none" x="0px" y="0px" width="290px" height="200px" /> <text y="70px" x="32px" fill="white" font-family="\'Courier New\', monospace" font-weight="200" font-size="36px">',
                quoteCurrencySymbol,
                "/",
                baseCurrencySymbol,
                '</text><text y="115px" x="32px" fill="white" font-family="\'Courier New\', monospace" font-weight="200" font-size="36px">',
                feeTier,
                "</text></g>",
                '<rect x="16" y="16" width="258" height="468" rx="26" ry="26" fill="rgba(0,0,0,0)" stroke="rgba(255,255,255,0.2)" />'
            )
        );
    }

    /// @notice Generate the SVG for the curve that represents the position. Fade up (top is faded) if current price is above your position range, fade down (bottom is faded) if current price is below your position range
    /// Circles are generated at the ends of the curve if the position is in range, or at one end of the curve it is on if not in range
    /// @param tickLower The lower tick
    /// @param tickUpper The upper tick
    /// @param tickSpacing The tick spacing
    /// @param overRange Whether the current tick is in range, over range, or under range
    /// @return svg The SVG for the curve
    function generageSvgCurve(int24 tickLower, int24 tickUpper, int24 tickSpacing, int8 overRange)
        private
        pure
        returns (string memory svg)
    {
        string memory fade = overRange == 1 ? "#fade-up" : overRange == -1 ? "#fade-down" : "#none";
        string memory curve = getCurve(tickLower, tickUpper, tickSpacing);
        svg = string(
            abi.encodePacked(
                '<g mask="url(',
                fade,
                ')"',
                ' style="transform:translate(72px,189px)">'
                '<rect x="-16px" y="-16px" width="180px" height="180px" fill="none" />' '<path d="',
                curve,
                '" stroke="rgba(0,0,0,0.3)" stroke-width="32px" fill="none" stroke-linecap="round" />',
                '</g><g mask="url(',
                fade,
                ')"',
                ' style="transform:translate(72px,189px)">',
                '<rect x="-16px" y="-16px" width="180px" height="180px" fill="none" />',
                '<path d="',
                curve,
                '" stroke="rgba(255,255,255,1)" fill="none" stroke-linecap="round" /></g>',
                generateSVGCurveCircle(overRange)
            )
        );
    }

    /// @notice Get the curve based on the tick range
    /// The smaller the tick range, the smaller/more linear the curve
    /// @param tickLower The lower tick
    /// @param tickUpper The upper tick
    /// @param tickSpacing The tick spacing
    /// @return curve The curve path
    function getCurve(int24 tickLower, int24 tickUpper, int24 tickSpacing) internal pure returns (string memory curve) {
        int24 tickRange = (tickUpper - tickLower) / tickSpacing;
        if (tickRange <= 4) {
            curve = curve1;
        } else if (tickRange <= 8) {
            curve = curve2;
        } else if (tickRange <= 16) {
            curve = curve3;
        } else if (tickRange <= 32) {
            curve = curve4;
        } else if (tickRange <= 64) {
            curve = curve5;
        } else if (tickRange <= 128) {
            curve = curve6;
        } else if (tickRange <= 256) {
            curve = curve7;
        } else {
            curve = curve8;
        }
    }

    /// @notice Generate the SVG for the circles on the curve
    /// @param overRange 0 if the current tick is in range, 1 if the current tick is over range, -1 if the current tick is under range
    /// @return svg The SVG for the circles
    function generateSVGCurveCircle(int8 overRange) internal pure returns (string memory svg) {
        string memory curvex1 = "73";
        string memory curvey1 = "190";
        string memory curvex2 = "217";
        string memory curvey2 = "334";
        /// If the position is over or under range, generate one circle at the end of the curve on the side of the range it is on with a larger circle around it
        if (overRange == 1 || overRange == -1) {
            svg = string(
                abi.encodePacked(
                    '<circle cx="',
                    overRange == -1 ? curvex1 : curvex2,
                    'px" cy="',
                    overRange == -1 ? curvey1 : curvey2,
                    'px" r="4px" fill="white" /><circle cx="',
                    overRange == -1 ? curvex1 : curvex2,
                    'px" cy="',
                    overRange == -1 ? curvey1 : curvey2,
                    'px" r="24px" fill="none" stroke="white" />'
                )
            );
        } else {
            /// If the position is in range, generate two circles at the ends of the curve
            svg = string(
                abi.encodePacked(
                    '<circle cx="',
                    curvex1,
                    'px" cy="',
                    curvey1,
                    'px" r="4px" fill="white" />',
                    '<circle cx="',
                    curvex2,
                    'px" cy="',
                    curvey2,
                    'px" r="4px" fill="white" />'
                )
            );
        }
    }

    /// @notice Generate the SVG for the position data (token ID, hooks address, min tick, max tick) and the location curve (where your position falls on the curve)
    /// @param tokenId The token ID
    /// @param hook The hooks address
    /// @param tickLower The lower tick
    /// @param tickUpper The upper tick
    /// @return svg The SVG for the position data and location curve
    function generateSVGPositionDataAndLocationCurve(
        string memory tokenId,
        address hook,
        int24 tickLower,
        int24 tickUpper
    ) private pure returns (string memory svg) {
        string memory hookStr = (uint256(uint160(hook))).toHexString(20);
        string memory tickLowerStr = tickToString(tickLower);
        string memory tickUpperStr = tickToString(tickUpper);
        uint256 str1length = bytes(tokenId).length + 4;
        string memory hookSlice = hook == address(0)
            ? "No Hook"
            : string(abi.encodePacked(substring(hookStr, 0, 5), "...", substring(hookStr, 39, 42)));
        uint256 str2length = bytes(hookSlice).length + 5;
        uint256 str3length = bytes(tickLowerStr).length + 10;
        uint256 str4length = bytes(tickUpperStr).length + 10;
        (string memory xCoord, string memory yCoord) = rangeLocation(tickLower, tickUpper);
        svg = string(
            abi.encodePacked(
                ' <g style="transform:translate(29px, 354px)">',
                '<rect width="',
                uint256(7 * (str1length + 4)).toString(),
                'px" height="26px" rx="8px" ry="8px" fill="rgba(0,0,0,0.6)" />',
                '<text x="12px" y="17px" font-family="\'Courier New\', monospace" font-size="11px" fill="white"><tspan fill="rgba(255,255,255,0.6)">ID: </tspan>',
                tokenId,
                "</text></g>",
                ' <g style="transform:translate(29px, 384px)">',
                '<rect width="',
                uint256(7 * (str2length + 4)).toString(),
                'px" height="26px" rx="8px" ry="8px" fill="rgba(0,0,0,0.6)" />',
                '<text x="12px" y="17px" font-family="\'Courier New\', monospace" font-size="11px" fill="white"><tspan fill="rgba(255,255,255,0.6)">Hook: </tspan>',
                hookSlice,
                "</text></g>",
                ' <g style="transform:translate(29px, 414px)">',
                '<rect width="',
                uint256(7 * (str3length + 4)).toString(),
                'px" height="26px" rx="8px" ry="8px" fill="rgba(0,0,0,0.6)" />',
                '<text x="12px" y="17px" font-family="\'Courier New\', monospace" font-size="11px" fill="white"><tspan fill="rgba(255,255,255,0.6)">Min Tick: </tspan>',
                tickLowerStr,
                "</text></g>",
                ' <g style="transform:translate(29px, 444px)">',
                '<rect width="',
                uint256(7 * (str4length + 4)).toString(),
                'px" height="26px" rx="8px" ry="8px" fill="rgba(0,0,0,0.6)" />',
                '<text x="12px" y="17px" font-family="\'Courier New\', monospace" font-size="11px" fill="white"><tspan fill="rgba(255,255,255,0.6)">Max Tick: </tspan>',
                tickUpperStr,
                "</text></g>" '<g style="transform:translate(226px, 433px)">',
                '<rect width="36px" height="36px" rx="8px" ry="8px" fill="none" stroke="rgba(255,255,255,0.2)" />',
                '<path stroke-linecap="round" d="M8 9C8.00004 22.9494 16.2099 28 27 28" fill="none" stroke="white" />',
                '<circle style="transform:translate3d(',
                xCoord,
                "px, ",
                yCoord,
                'px, 0px)" cx="0px" cy="0px" r="4px" fill="white"/></g>'
            )
        );
    }

    function substring(string memory str, uint256 startIndex, uint256 endIndex) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }

    function tickToString(int24 tick) private pure returns (string memory) {
        string memory sign = "";
        if (tick < 0) {
            tick = tick * -1;
            sign = "-";
        }
        return string(abi.encodePacked(sign, uint256(uint24(tick)).toString()));
    }

    /// @notice Get the location of where your position falls on the curve
    /// @param tickLower The lower tick
    /// @param tickUpper The upper tick
    /// @return The x and y coordinates of the location of the liquidity
    function rangeLocation(int24 tickLower, int24 tickUpper) internal pure returns (string memory, string memory) {
        int24 midPoint = (tickLower + tickUpper) / 2;
        if (midPoint < -125_000) {
            return ("8", "7");
        } else if (midPoint < -75_000) {
            return ("8", "10.5");
        } else if (midPoint < -25_000) {
            return ("8", "14.25");
        } else if (midPoint < -5_000) {
            return ("10", "18");
        } else if (midPoint < 0) {
            return ("11", "21");
        } else if (midPoint < 5_000) {
            return ("13", "23");
        } else if (midPoint < 25_000) {
            return ("15", "25");
        } else if (midPoint < 75_000) {
            return ("18", "26");
        } else if (midPoint < 125_000) {
            return ("21", "27");
        } else {
            return ("24", "27");
        }
    }

    /// @notice Generates the SVG for a rare sparkle if the NFT is rare. Else, returns an empty string
    /// @param tokenId The token ID
    /// @param hooks The hooks address
    /// @return svg The SVG for the rare sparkle
    function generateSVGRareSparkle(uint256 tokenId, address hooks) private pure returns (string memory svg) {
        if (isRare(tokenId, hooks)) {
            svg = string(
                abi.encodePacked(
                    '<g style="transform:translate(226px, 392px)"><rect width="36px" height="36px" rx="8px" ry="8px" fill="none" stroke="rgba(255,255,255,0.2)" />',
                    '<g><path style="transform:translate(6px,6px)" d="M12 0L12.6522 9.56587L18 1.6077L13.7819 10.2181L22.3923 6L14.4341 ',
                    "11.3478L24 12L14.4341 12.6522L22.3923 18L13.7819 13.7819L18 22.3923L12.6522 14.4341L12 24L11.3478 14.4341L6 22.39",
                    '23L10.2181 13.7819L1.6077 18L9.56587 12.6522L0 12L9.56587 11.3478L1.6077 6L10.2181 10.2181L6 1.6077L11.3478 9.56587L12 0Z" fill="white" />',
                    '<animateTransform attributeName="transform" type="rotate" from="0 18 18" to="360 18 18" dur="10s" repeatCount="indefinite"/></g></g>'
                )
            );
        } else {
            svg = "";
        }
    }

    /// @notice Determines if an NFT is rare based on the token ID and hooks address
    /// @param tokenId The token ID
    /// @param hooks The hooks address
    /// @return Whether the NFT is rare or not
    function isRare(uint256 tokenId, address hooks) internal pure returns (bool) {
        bytes32 h = keccak256(abi.encodePacked(tokenId, hooks));
        return uint256(h) < type(uint256).max / (1 + BitMath.mostSignificantBit(tokenId) * 2);
    }
}
