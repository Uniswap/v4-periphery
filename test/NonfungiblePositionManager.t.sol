// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TokenFixture} from "@uniswap/v4-core/test/foundry-tests/utils/TokenFixture.sol";
import {PoolManager, IPoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {NonfungiblePositionManager, INonfungiblePositionManager} from "../contracts/NonfungiblePositionManager.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {MockERC20} from "@uniswap/v4-core/test/foundry-tests/utils/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";

contract NonfungiblePositionManagerTest is Test, TokenFixture {
    using PoolIdLibrary for PoolKey;

    event ModifyPosition(
        PoolId indexed poolId, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta
    );
    event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    PoolManager manager;
    NonfungiblePositionManager nonfungiblePositionManager;
    PoolSwapTest swapRouter;

    // Ratio of token0 / token1
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;
    uint160 constant SQRT_RATIO_1_2 = 56022770974786139918731938227;
    uint160 constant SQRT_RATIO_2_1 = 158456325028528675187087900672;
    uint256 constant MAX_UINT256 = type(uint256).max;

    function setUp() public {
        initializeTokens();
        manager = new PoolManager(500000);
        nonfungiblePositionManager = new NonfungiblePositionManager(manager, address(1));
        swapRouter = new PoolSwapTest(manager);

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 10 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 10 ether);
        MockERC20(Currency.unwrap(currency0)).approve(address(nonfungiblePositionManager), 10 ether);
        MockERC20(Currency.unwrap(currency1)).approve(address(nonfungiblePositionManager), 10 ether);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), 10 ether);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), 10 ether);
    }

    // Add 1 currency0 of liquidity.
    function testMintCurrency0() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        manager.initialize(key, SQRT_RATIO_1_1);

        vm.expectEmit(true, true, true, true);
        emit ModifyPosition(key.toId(), address(nonfungiblePositionManager), 0, 60, 333850249709699449134);
        vm.expectEmit(true, true, true, true);
        emit IncreaseLiquidity(1, 333850249709699449134, 1 ether, 0);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = nonfungiblePositionManager.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: 0,
                tickUpper: 60,
                amount0Desired: 1 ether,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: MAX_UINT256
            })
        );
        assertEq(tokenId, 1);
        assertEq(liquidity, 333850249709699449134);
        assertEq(amount0, 1 ether);
        assertEq(amount1, 0);

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(this)), 9 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(this)), 10 ether);
        assertEq(IERC721(nonfungiblePositionManager).ownerOf(1), address(this));
        (PoolKey memory poolkey,,,, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,,) =
            nonfungiblePositionManager.positions(1);
        assertEq(PoolId.unwrap(poolkey.toId()), PoolId.unwrap(key.toId()));
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);

        Position.Info memory info = manager.getPosition(key.toId(), address(nonfungiblePositionManager), 0, 60);
        assertEq(info.liquidity, 333850249709699449134);
        assertEq(info.feeGrowthInside0LastX128, 0);
        assertEq(info.feeGrowthInside1LastX128, 0);
    }

    // Add 1 currency1 of liquidity.
    function testMintCurrency1() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        manager.initialize(key, SQRT_RATIO_1_1);

        vm.expectEmit(true, true, true, true);
        emit ModifyPosition(key.toId(), address(nonfungiblePositionManager), -60, 0, 333850249709699449134);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = nonfungiblePositionManager.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: -60,
                tickUpper: 0,
                amount0Desired: 0,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: MAX_UINT256
            })
        );
        assertEq(tokenId, 1);
        assertEq(liquidity, 333850249709699449134);
        assertEq(amount0, 0);
        assertEq(amount1, 1 ether);

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(this)), 10 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(this)), 9 ether);
        assertEq(IERC721(nonfungiblePositionManager).ownerOf(1), address(this));
        (PoolKey memory poolkey,,,, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,,) =
            nonfungiblePositionManager.positions(1);
        assertEq(PoolId.unwrap(poolkey.toId()), PoolId.unwrap(key.toId()));
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
    }

    // Add 1 currency0 and 1 currency1 of liquidity.
    function testMintCurrency0AndCurrency1() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        manager.initialize(key, SQRT_RATIO_1_1);

        vm.expectEmit(true, true, true, true);
        emit ModifyPosition(key.toId(), address(nonfungiblePositionManager), -60, 60, 333850249709699449134);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = nonfungiblePositionManager.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: -60,
                tickUpper: 60,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: MAX_UINT256
            })
        );
        assertEq(tokenId, 1);
        assertEq(liquidity, 333850249709699449134);
        assertEq(amount0, 1 ether);
        assertEq(amount1, 1 ether);

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(this)), 9 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(this)), 9 ether);
        assertEq(IERC721(nonfungiblePositionManager).ownerOf(1), address(this));
        (PoolKey memory poolkey,,,, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,,) =
            nonfungiblePositionManager.positions(1);
        assertEq(PoolId.unwrap(poolkey.toId()), PoolId.unwrap(key.toId()));
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
    }

    // Mint 2 positions.
    function test2Mints() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        manager.initialize(key, SQRT_RATIO_1_1);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = nonfungiblePositionManager.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: 0,
                tickUpper: 60,
                amount0Desired: 1 ether,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: MAX_UINT256
            })
        );
        assertEq(tokenId, 1);
        assertEq(liquidity, 333850249709699449134);
        assertEq(amount0, 1 ether);
        assertEq(amount1, 0);

        (tokenId, liquidity, amount0, amount1) = nonfungiblePositionManager.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: 0,
                tickUpper: 60,
                amount0Desired: 1 ether,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: MAX_UINT256
            })
        );
        assertEq(tokenId, 2);
        assertEq(liquidity, 333850249709699449134);
        assertEq(amount0, 1 ether);
        assertEq(amount1, 0);

        Position.Info memory info = manager.getPosition(key.toId(), address(nonfungiblePositionManager), 0, 60);
        // This is twice of the liquidity in `testMintCurrency0`.
        assertEq(info.liquidity, 667700499419398898268);
        assertEq(info.feeGrowthInside0LastX128, 0);
        assertEq(info.feeGrowthInside1LastX128, 0);
    }

    function testFeesAccrue() public {
        PoolKey memory key =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, hooks: IHooks(address(0)), tickSpacing: 60});

        manager.initialize(key, SQRT_RATIO_1_1);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = nonfungiblePositionManager.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: 0,
                tickUpper: 60,
                amount0Desired: 1 ether,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: MAX_UINT256
            })
        );

        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 1 ether / 2, sqrtPriceLimitX96: SQRT_RATIO_2_1});
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});
        swapRouter.swap(key, params, testSettings);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(this)), 10 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(this)), 9 ether);
    }
}
