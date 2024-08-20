// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PositionDescriptor} from "../src/PositionDescriptor.sol";
import {CurrencyRatioSortOrder} from "../src/libraries/CurrencyRatioSortOrder.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionConfig} from "../src/libraries/PositionConfig.sol";

import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import "forge-std/console2.sol";

contract PositionDescriptorTest is Test, Deployers, PosmTestSetup {
    PositionDescriptor public positionDescriptor;
    address public WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public TBTC = 0x8dAEBADE922dF735c38C80C7eBD708Af50815fAa;
    address public WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    bytes32 public nativeCurrencyLabel = "ETH";

    function setUp() public {
        deployFreshManager();
        // need to pass in WETH address and native currency label
        positionDescriptor = new PositionDescriptor(manager, WETH9, nativeCurrencyLabel);

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
        assertEq(positionDescriptor.currencyRatioPriority(WETH9), CurrencyRatioSortOrder.DENOMINATOR);
        assertEq(positionDescriptor.currencyRatioPriority(USDC), CurrencyRatioSortOrder.NUMERATOR_MOST);
        assertEq(positionDescriptor.currencyRatioPriority(USDT), CurrencyRatioSortOrder.NUMERATOR_MORE);
        assertEq(positionDescriptor.currencyRatioPriority(DAI), CurrencyRatioSortOrder.NUMERATOR);
        assertEq(positionDescriptor.currencyRatioPriority(TBTC), CurrencyRatioSortOrder.DENOMINATOR_MORE);
        assertEq(positionDescriptor.currencyRatioPriority(WBTC), CurrencyRatioSortOrder.DENOMINATOR_MOST);
        assertEq(positionDescriptor.currencyRatioPriority(makeAddr("ALICE")), 0);
    }

    function test_currencyRatioPriority_notMainnet_succeeds() public {
        assertEq(positionDescriptor.currencyRatioPriority(WETH9), CurrencyRatioSortOrder.DENOMINATOR);
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
        assertTrue(positionDescriptor.flipRatio(USDC, DAI));
        assertTrue(positionDescriptor.flipRatio(WETH9, WBTC));
        assertTrue(positionDescriptor.flipRatio(DAI, WBTC));
        assertFalse(positionDescriptor.flipRatio(WBTC, DAI));
    }

    function test_tokenURI_succeeds() public {
        // create v4 pool (already created in setup)
        // mint a position
        int24 tickLower = -int24(key.tickSpacing);
        int24 tickUpper = int24(key.tickSpacing);
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
        // call tokenURI
        console2.log("tokenURI", positionDescriptor.tokenURI(tokenId, config));
        // decode json
        // check that name and description are correct
    }
}
