// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {SwapAndAdd} from "../src/SwapAndAdd.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";

/// @notice V1 SwapAndAdd tests (option C: optimistic-mint-and-trim). Same-pool path (empty route) — exercises
///         optimistic sizing, flash-take, mint-to-contract, same-pool funding swap, the trim, dust sweep, and
///         the post-unlock NFT transfer to the recipient. UR-route integration is tested separately.
contract SwapAndAddTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    SwapAndAdd zap;
    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        seedMoreLiquidity(key, 1_000e18, 1_000e18);

        zap = new SwapAndAdd(manager, permit2, lpm, IUniversalRouter(address(0xdead)));

        seedBalance(address(this));
        _approveZap(currency0);
        _approveZap(currency1);

        // native pool (currency0 == native ETH) with depth for the native add test.
        vm.deal(address(this), 1_000 ether);
        (nativeKey,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, 1 ether
        );
        modifyLiquidityRouter.modifyLiquidity{value: 50 ether}(
            nativeKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: int256(uint256(200e18)), salt: 0}),
            ""
        );
    }

    function _approveZap(Currency c) internal {
        MockERC20(Currency.unwrap(c)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(c), address(zap), type(uint160).max, type(uint48).max);
    }

    function _addParams(uint256 amount0In, uint256 amount1In)
        internal
        view
        returns (ISwapAndAdd.AddParams memory)
    {
        return ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: amount0In,
            amount1In: amount1In,
            route: "",
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    function test_add_singleToken1() public {
        uint256 amountIn = 10e18;
        uint256 c0Before = currency0.balanceOf(address(this));

        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = zap.add(_addParams(0, amountIn));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertGt(a0, 0, "token0 deployed");
        assertGt(a1, 0, "token1 deployed");
        // dust lands in the input token (token1); the swapped-into token0 returns ~nothing.
        assertApproxEqAbs(currency0.balanceOf(address(this)), c0Before, 5, "no token0 dust to user");
        // contract holds nothing
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_add_singleToken0() public {
        uint256 amountIn = 10e18;
        uint256 c1Before = currency1.balanceOf(address(this));

        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(amountIn, 0));

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        // dust lands in the input token (token0); the swapped-into token1 returns ~nothing.
        assertApproxEqAbs(currency1.balanceOf(address(this)), c1Before, 5, "no token1 dust to user");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_add_mixedRatio() public {
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(3e18, 10e18));
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    /// @notice Option C deploys the *actual* max the budget supports, so returned dust is tiny (the genuine
    ///         slippage shortfall), in the input token.
    function test_add_lowDust() public {
        uint256 amountIn = 10e18;
        uint256 c0Before = currency0.balanceOf(address(this));
        uint256 c1Before = currency1.balanceOf(address(this));

        zap.add(_addParams(0, amountIn));

        // net token1 spent = pulled budget - swept dust. dust returned should be a small fraction of the budget.
        uint256 dust1 = currency1.balanceOf(address(this)) + amountIn - c1Before;
        // measured ~15 bps of budget here (0.3% fee pool, ~half the budget swapped) — the genuine slippage shortfall.
        assertLt(dust1, amountIn / 50, "token1 dust < 2% of budget");
        assertApproxEqAbs(currency0.balanceOf(address(this)), c0Before, 5, "no token0 dust");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_add_revertsOnMinLiquidity() public {
        ISwapAndAdd.AddParams memory p = _addParams(0, 10e18);
        p.minLiquidity = type(uint128).max; // impossible floor
        vm.expectRevert();
        zap.add(p);
    }

    function _rebalanceParams(uint256 tokenId, uint128 liquidityToMove)
        internal
        view
        returns (ISwapAndAdd.RebalanceParams memory)
    {
        return ISwapAndAdd.RebalanceParams({
            tokenId: tokenId,
            liquidityToMove: liquidityToMove,
            newTickLower: -1200,
            newTickUpper: 1200,
            route: "",
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    function test_rebalance_full() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);

        uint128 posLiq = lpm.getPositionLiquidity(tokenId);
        (uint256 newTokenId, uint128 newLiq,,) = zap.rebalance(_rebalanceParams(tokenId, posLiq));

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "user owns new NFT");
        assertGt(newLiq, 0, "new liquidity minted");
        assertEq(lpm.getPositionLiquidity(tokenId), 0, "old position fully emptied");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_rebalance_partial() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);

        uint128 posLiq = lpm.getPositionLiquidity(tokenId);
        uint128 half = posLiq / 2;
        (uint256 newTokenId, uint128 newLiq,,) = zap.rebalance(_rebalanceParams(tokenId, half));

        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "user owns new NFT");
        assertGt(newLiq, 0, "new liquidity minted");
        // original position keeps roughly the remaining half
        assertApproxEqAbs(lpm.getPositionLiquidity(tokenId), posLiq - half, 1, "old keeps remainder");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_add_native() public {
        uint256 nativeIn = 1e17; // 0.1 ETH, native is currency0
        uint256 c1Before = currency1.balanceOf(address(this));

        ISwapAndAdd.AddParams memory p = ISwapAndAdd.AddParams({
            poolKey: nativeKey,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0In: nativeIn,
            amount1In: 0,
            route: "",
            minLiquidity: 0,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });

        (uint256 tokenId, uint128 liq,,) = zap.add{value: nativeIn}(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "user owns NFT");
        assertGt(liq, 0, "liquidity minted");
        // dust lands in the input token (native); the swapped-into currency1 returns ~nothing.
        assertApproxEqAbs(currency1.balanceOf(address(this)), c1Before, 5, "no token1 dust to user");
        // contract strands nothing
        assertEq(address(zap).balance, 0, "zap eth == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }

    function test_rebalance_revertsIfNotAuthorized() public {
        (uint256 tokenId,,,) = zap.add(_addParams(0, 10e18));
        // do NOT approve the zap; call from a stranger
        uint128 posLiq = lpm.getPositionLiquidity(tokenId);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        zap.rebalance(_rebalanceParams(tokenId, posLiq));
    }
}
