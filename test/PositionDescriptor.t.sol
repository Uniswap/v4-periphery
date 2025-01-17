// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPositionDescriptor} from "../src/interfaces/IPositionDescriptor.sol";
import {CurrencyRatioSortOrder} from "../src/libraries/CurrencyRatioSortOrder.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionConfig} from "./shared/PositionConfig.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import {Base64} from "./base64.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCurrencyMetadata} from "../src/libraries/SafeCurrencyMetadata.sol";
import {AddressStringUtil} from "../src/libraries/AddressStringUtil.sol";
import {Descriptor} from "../src/libraries/Descriptor.sol";

contract PositionDescriptorTest is Test, PosmTestSetup {
    using Base64 for string;

    address public WETH9 = makeAddr("WETH");
    address public DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public TBTC = 0x8dAEBADE922dF735c38C80C7eBD708Af50815fAa;
    address public WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    string public nativeCurrencyLabel = "ETH";
    bytes32 public nativeCurrencyLabelBytes = "ETH";

    struct Token {
        string description;
        string image;
        string name;
    }

    function setUp() public {
        deployFreshManager();
        (currency0, currency1) = deployAndMint2Currencies();
        (key,) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        deployAndApprovePosm(manager);
    }

    function test_position_descriptor_initcodeHash() public {
        vm.snapshotValue(
            "position descriptor initcode hash (without constructor params, as uint256)",
            uint256(keccak256(abi.encodePacked(vm.getCode("PositionDescriptor.sol:PositionDescriptor"))))
        );
    }

    function test_bytecodeSize_positionDescriptor() public {
        vm.snapshotValue("positionDescriptor bytecode size", address(positionDescriptor).code.length);
    }

    function test_bytecodeSize_proxy() public {
        vm.snapshotValue("proxy bytecode size", address(proxyAsImplementation).code.length);
    }

    function test_setup_succeeds() public view {
        assertEq(address(proxyAsImplementation.poolManager()), address(manager));
        assertEq(proxyAsImplementation.wrappedNative(), WETH9);
    }

    function test_nativeCurrencyLabel_succeeds() public {
        assertEq(proxyAsImplementation.nativeCurrencyLabel(), nativeCurrencyLabel);
        IPositionDescriptor polDescriptor = deployDescriptor(manager, "POL");
        assertEq(polDescriptor.nativeCurrencyLabel(), "POL");
        IPositionDescriptor bnbDescriptor = deployDescriptor(manager, "BNB");
        assertEq(bnbDescriptor.nativeCurrencyLabel(), "BNB");
        IPositionDescriptor avaxDescriptor = deployDescriptor(manager, "AVAX");
        assertEq(avaxDescriptor.nativeCurrencyLabel(), "AVAX");
    }

    function test_currencyRatioPriority_mainnet_succeeds() public {
        vm.chainId(1);
        assertEq(proxyAsImplementation.currencyRatioPriority(WETH9), CurrencyRatioSortOrder.DENOMINATOR);
        assertEq(proxyAsImplementation.currencyRatioPriority(address(0)), CurrencyRatioSortOrder.DENOMINATOR);
        assertEq(proxyAsImplementation.currencyRatioPriority(USDC), CurrencyRatioSortOrder.NUMERATOR_MOST);
        assertEq(proxyAsImplementation.currencyRatioPriority(USDT), CurrencyRatioSortOrder.NUMERATOR_MORE);
        assertEq(proxyAsImplementation.currencyRatioPriority(DAI), CurrencyRatioSortOrder.NUMERATOR);
        assertEq(proxyAsImplementation.currencyRatioPriority(TBTC), CurrencyRatioSortOrder.DENOMINATOR_MORE);
        assertEq(proxyAsImplementation.currencyRatioPriority(WBTC), CurrencyRatioSortOrder.DENOMINATOR_MOST);
        assertEq(proxyAsImplementation.currencyRatioPriority(makeAddr("ALICE")), 0);
    }

    function test_currencyRatioPriority_notMainnet_succeeds() public {
        assertEq(proxyAsImplementation.currencyRatioPriority(WETH9), CurrencyRatioSortOrder.DENOMINATOR);
        assertEq(proxyAsImplementation.currencyRatioPriority(address(0)), CurrencyRatioSortOrder.DENOMINATOR);
        assertEq(proxyAsImplementation.currencyRatioPriority(USDC), 0);
        assertEq(proxyAsImplementation.currencyRatioPriority(USDT), 0);
        assertEq(proxyAsImplementation.currencyRatioPriority(DAI), 0);
        assertEq(proxyAsImplementation.currencyRatioPriority(TBTC), 0);
        assertEq(proxyAsImplementation.currencyRatioPriority(WBTC), 0);
        assertEq(proxyAsImplementation.currencyRatioPriority(makeAddr("ALICE")), 0);
    }

    function test_flipRatio_succeeds() public {
        vm.chainId(1);
        // bc price = token1/token0
        assertTrue(proxyAsImplementation.flipRatio(USDC, WETH9));
        assertFalse(proxyAsImplementation.flipRatio(DAI, USDC));
        assertFalse(proxyAsImplementation.flipRatio(WBTC, WETH9));
        assertFalse(proxyAsImplementation.flipRatio(WBTC, USDC));
        assertFalse(proxyAsImplementation.flipRatio(WBTC, DAI));
    }

    function test_tokenURI_succeeds() public {
        int24 tickLower = int24(key.tickSpacing);
        int24 tickUpper = int24(key.tickSpacing * 2);
        uint256 tokenId = lpm.nextTokenId();
        Token memory token;
        {
            uint256 amount0Desired = 100e18;
            uint256 amount1Desired = 100e18;
            uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
                SQRT_PRICE_1_1,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                amount0Desired,
                amount1Desired
            );

            PositionConfig memory config = PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});
            mint(config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

            // The prefix length is calculated by converting the string to bytes and finding its length
            uint256 prefixLength = bytes("data:application/json;base64,").length;

            string memory uri = proxyAsImplementation.tokenURI(lpm, tokenId);
            // Convert the uri to bytes
            bytes memory uriBytes = bytes(uri);

            // Slice the uri to get only the base64-encoded part
            bytes memory base64Part = new bytes(uriBytes.length - prefixLength);

            for (uint256 i = 0; i < base64Part.length; i++) {
                base64Part[i] = uriBytes[i + prefixLength];
            }

            // Decode the base64-encoded part
            bytes memory decoded = Base64.decode(string(base64Part));
            string memory json = string(decoded);

            // decode json
            bytes memory data = vm.parseJson(json);
            token = abi.decode(data, (Token));
        }

        // quote is currency1, base is currency0
        assertFalse(proxyAsImplementation.flipRatio(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)));

        string memory symbol0 = SafeCurrencyMetadata.currencySymbol(Currency.unwrap(currency0), nativeCurrencyLabel);
        string memory symbol1 = SafeCurrencyMetadata.currencySymbol(Currency.unwrap(currency1), nativeCurrencyLabel);
        string memory fee = Descriptor.feeToPercentString(key.fee);
        {
            string memory tickToDecimal0 = Descriptor.tickToDecimalString(
                tickLower,
                key.tickSpacing,
                SafeCurrencyMetadata.currencyDecimals(Currency.unwrap(currency0)),
                SafeCurrencyMetadata.currencyDecimals(Currency.unwrap(currency1)),
                false
            );
            string memory tickToDecimal1 = Descriptor.tickToDecimalString(
                tickUpper,
                key.tickSpacing,
                SafeCurrencyMetadata.currencyDecimals(Currency.unwrap(currency0)),
                SafeCurrencyMetadata.currencyDecimals(Currency.unwrap(currency1)),
                false
            );

            assertEq(
                token.name,
                string(
                    abi.encodePacked(
                        "Uniswap - ", fee, " - ", symbol1, "/", symbol0, " - ", tickToDecimal0, "<>", tickToDecimal1
                    )
                )
            );
        }
        {
            string memory managerAddress = toHexString(address(manager));
            string memory currency0Address = toHexString(Currency.unwrap(currency0));
            string memory currency1Address = toHexString(Currency.unwrap(currency1));
            string memory id = uintToString(tokenId);
            string memory hookAddress = address(key.hooks) == address(0)
                ? "No Hook"
                : string(abi.encodePacked("0x", toHexString(address(key.hooks))));

            assertEq(
                token.description,
                string(
                    abi.encodePacked(
                        abi.encodePacked(
                            unicode"This NFT represents a liquidity position in a Uniswap v4 ",
                            symbol1,
                            "-",
                            symbol0,
                            " pool. The owner of this NFT can modify or redeem the position.\n\nPool Manager Address: ",
                            managerAddress,
                            "\n",
                            symbol1,
                            " Address: ",
                            currency1Address
                        ),
                        abi.encodePacked(
                            "\n",
                            symbol0,
                            " Address: ",
                            currency0Address,
                            "\nHook Address: ",
                            hookAddress,
                            "\nFee Tier: ",
                            fee,
                            "\nToken ID: ",
                            id,
                            "\n\n",
                            unicode"⚠️ DISCLAIMER: Due diligence is imperative when assessing this NFT. Make sure currency addresses match the expected currencies, as currency symbols may be imitated."
                        )
                    )
                )
            );
        }
    }

    function test_native_tokenURI_succeeds() public {
        (nativeKey,) = initPool(CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        int24 tickLower = int24(nativeKey.tickSpacing);
        int24 tickUpper = int24(nativeKey.tickSpacing * 2);
        Token memory token;
        uint256 tokenId = lpm.nextTokenId();
        {
            uint256 amount0Desired = 100e18;
            uint256 amount1Desired = 100e18;
            uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
                SQRT_PRICE_1_1,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                amount0Desired,
                amount1Desired
            );

            PositionConfig memory config =
                PositionConfig({poolKey: nativeKey, tickLower: tickLower, tickUpper: tickUpper});
            mintWithNative(SQRT_PRICE_1_1, config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);
            // The prefix length is calculated by converting the string to bytes and finding its length
            uint256 prefixLength = bytes("data:application/json;base64,").length;

            string memory uri = proxyAsImplementation.tokenURI(lpm, tokenId);
            // Convert the uri to bytes
            bytes memory uriBytes = bytes(uri);

            // Slice the uri to get only the base64-encoded part
            bytes memory base64Part = new bytes(uriBytes.length - prefixLength);

            for (uint256 i = 0; i < base64Part.length; i++) {
                base64Part[i] = uriBytes[i + prefixLength];
            }

            // Decode the base64-encoded part
            bytes memory decoded = Base64.decode(string(base64Part));
            string memory json = string(decoded);

            // decode json
            bytes memory data = vm.parseJson(json);
            token = abi.decode(data, (Token));
        }

        // quote is currency1, base is currency0
        assertFalse(
            proxyAsImplementation.flipRatio(Currency.unwrap(nativeKey.currency0), Currency.unwrap(nativeKey.currency1))
        );

        string memory symbol0 =
            SafeCurrencyMetadata.currencySymbol(Currency.unwrap(nativeKey.currency0), nativeCurrencyLabel);
        string memory symbol1 =
            SafeCurrencyMetadata.currencySymbol(Currency.unwrap(nativeKey.currency1), nativeCurrencyLabel);
        string memory fee = Descriptor.feeToPercentString(nativeKey.fee);
        {
            string memory tickToDecimal0 = Descriptor.tickToDecimalString(
                tickLower,
                nativeKey.tickSpacing,
                SafeCurrencyMetadata.currencyDecimals(Currency.unwrap(currency0)),
                SafeCurrencyMetadata.currencyDecimals(Currency.unwrap(currency1)),
                false
            );
            string memory tickToDecimal1 = Descriptor.tickToDecimalString(
                tickUpper,
                nativeKey.tickSpacing,
                SafeCurrencyMetadata.currencyDecimals(Currency.unwrap(currency0)),
                SafeCurrencyMetadata.currencyDecimals(Currency.unwrap(currency1)),
                false
            );

            assertEq(
                token.name,
                string(
                    abi.encodePacked(
                        "Uniswap - ", fee, " - ", symbol1, "/", symbol0, " - ", tickToDecimal0, "<>", tickToDecimal1
                    )
                )
            );
        }
        {
            string memory managerAddress = toHexString(address(manager));
            string memory currency0Address = Currency.unwrap(nativeKey.currency0) == address(0)
                ? "Native"
                : toHexString(Currency.unwrap(nativeKey.currency0));
            string memory currency1Address = Currency.unwrap(nativeKey.currency1) == address(0)
                ? "Native"
                : toHexString(Currency.unwrap(nativeKey.currency1));
            string memory id = uintToString(tokenId);
            string memory hookAddress = address(nativeKey.hooks) == address(0)
                ? "No Hook"
                : string(abi.encodePacked("0x", toHexString(address(nativeKey.hooks))));

            assertEq(
                token.description,
                string(
                    abi.encodePacked(
                        abi.encodePacked(
                            unicode"This NFT represents a liquidity position in a Uniswap v4 ",
                            symbol1,
                            "-",
                            symbol0,
                            " pool. The owner of this NFT can modify or redeem the position.\n\nPool Manager Address: ",
                            managerAddress,
                            "\n",
                            symbol1,
                            " Address: ",
                            currency1Address,
                            "\n",
                            symbol0
                        ),
                        abi.encodePacked(
                            " Address: ",
                            currency0Address,
                            "\nHook Address: ",
                            hookAddress,
                            "\nFee Tier: ",
                            fee,
                            "\nToken ID: ",
                            id,
                            "\n\n",
                            unicode"⚠️ DISCLAIMER: Due diligence is imperative when assessing this NFT. Make sure currency addresses match the expected currencies, as currency symbols may be imitated."
                        )
                    )
                )
            );
        }
    }

    function test_tokenURI_revertsWithInvalidTokenId() public {
        int24 tickLower = int24(key.tickSpacing);
        int24 tickUpper = int24(key.tickSpacing * 2);
        uint256 amount0Desired = 100e18;
        uint256 amount1Desired = 100e18;
        uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});
        uint256 tokenId = lpm.nextTokenId();
        mint(config, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        vm.expectRevert(abi.encodeWithSelector(IPositionDescriptor.InvalidTokenId.selector, tokenId + 1));

        proxyAsImplementation.tokenURI(lpm, tokenId + 1);
    }

    // Helper functions for testing purposes
    function toHexString(address account) internal pure returns (string memory) {
        return toHexString(uint256(uint160(account)), 20);
    }

    // different from AddressStringUtil.toHexString. this one is all lowercase hex and includes the 0x prefix
    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            uint8 digit = uint8(value & 0xf);
            buffer[i] = digit < 10 ? bytes1(digit + 48) : bytes1(digit + 87); // Lowercase hex (0x61 is 'a' in ASCII)
            value >>= 4;
        }
        require(value == 0, "Hex length insufficient");
        return string(buffer);
    }

    function uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
