// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PositionDescriptor} from "../src/PositionDescriptor.sol";
import {CurrencyRatioSortOrder} from "../src/libraries/CurrencyRatioSortOrder.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionConfig} from "./shared/PositionConfig.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import {Base64} from "./base64.sol";

contract PositionDescriptorTest is Test, PosmTestSetup {
    using Base64 for string;

    address public WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public TBTC = 0x8dAEBADE922dF735c38C80C7eBD708Af50815fAa;
    address public WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    bytes32 public nativeCurrencyLabel = "ETH";

    struct Token {
        string description;
        string image;
        string name;
    }

    function setUp() public {
        deployFreshManager();
        (currency0, currency1) = deployAndMint2Currencies();
        (key,) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);
        deployAndApprovePosm(manager);
    }

    function test_setup_succeeds() public view {
        assertEq(address(positionDescriptor.poolManager()), address(manager));
        assertEq(positionDescriptor.WETH9(), WETH9);
        assertEq(positionDescriptor.nativeCurrencyLabelBytes(), nativeCurrencyLabel);
    }

    function test_nativeCurrencyLabel_succeeds() public view {
        assertEq(positionDescriptor.nativeCurrencyLabel(), "ETH");
    }

    function test_currencyRatioPriority_mainnet_succeeds() public {
        vm.chainId(1);
        assertEq(positionDescriptor.currencyRatioPriority(WETH9), CurrencyRatioSortOrder.DENOMINATOR_2);
        assertEq(positionDescriptor.currencyRatioPriority(USDC), CurrencyRatioSortOrder.NUMERATOR_MOST);
        assertEq(positionDescriptor.currencyRatioPriority(USDT), CurrencyRatioSortOrder.NUMERATOR_MORE);
        assertEq(positionDescriptor.currencyRatioPriority(DAI), CurrencyRatioSortOrder.NUMERATOR);
        assertEq(positionDescriptor.currencyRatioPriority(TBTC), CurrencyRatioSortOrder.DENOMINATOR_MORE);
        assertEq(positionDescriptor.currencyRatioPriority(WBTC), CurrencyRatioSortOrder.DENOMINATOR_MOST);
        assertEq(positionDescriptor.currencyRatioPriority(makeAddr("ALICE")), 0);
    }

    function test_currencyRatioPriority_notMainnet_succeeds() public {
        assertEq(positionDescriptor.currencyRatioPriority(WETH9), CurrencyRatioSortOrder.DENOMINATOR_2);
        assertEq(positionDescriptor.currencyRatioPriority(USDC), 0);
        assertEq(positionDescriptor.currencyRatioPriority(USDT), 0);
        assertEq(positionDescriptor.currencyRatioPriority(DAI), 0);
        assertEq(positionDescriptor.currencyRatioPriority(TBTC), 0);
        assertEq(positionDescriptor.currencyRatioPriority(WBTC), 0);
        assertEq(positionDescriptor.currencyRatioPriority(makeAddr("ALICE")), 0);
    }

    function test_flipRatio_succeeds() public {
        vm.chainId(1);
        // bc price = token1/token0
        assertTrue(positionDescriptor.flipRatio(USDC, WETH9));
        assertFalse(positionDescriptor.flipRatio(DAI, USDC));
        assertFalse(positionDescriptor.flipRatio(WBTC, WETH9));
        assertFalse(positionDescriptor.flipRatio(WBTC, USDC));
        assertFalse(positionDescriptor.flipRatio(WBTC, DAI));
    }

    function test_tokenURI_succeeds() public {
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

        // The prefix length is calculated by converting the string to bytes and finding its length
        uint256 prefixLength = bytes("data:application/json;base64,").length;

        string memory uri = positionDescriptor.tokenURI(lpm, tokenId);
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
        Token memory token = abi.decode(data, (Token));
    }
}
