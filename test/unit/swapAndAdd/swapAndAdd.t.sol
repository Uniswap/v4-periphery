// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";

contract SwapAndAddCoreTest is BttBase {
    function test_WhenHookHasReturnsDeltaPermission_Reverts() public {
        // it reverts with {UnsupportedHookPermissions}
        uint160[4] memory flagged = [
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG,
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG,
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        ];
        ISwapAndAdd.AddParams memory p = _addParams(1e18, 1e18);
        for (uint256 i = 0; i < flagged.length; i++) {
            p.poolKey.hooks = IHooks(address(flagged[i]));
            vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.UnsupportedHookPermissions.selector, p.poolKey.hooks));
            zap.add(p);
        }

        p.poolKey.hooks = IHooks(address(uint160(Hooks.BEFORE_SWAP_FLAG)));
        vm.expectRevert(IPoolManager.PoolNotInitialized.selector);
        zap.add(p);
    }

    function test_WhenRouteIsEmpty_SizesFromPulledBudgets() public {
        // it sizes from the pulled budgets
        (uint256 tokenId, uint128 liq,,) = zap.add(_addParams(5e18, 5e18));
        assertGt(liq, 0, "liquidity");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT to recipient");
        _assertZapIdle();
    }

    function test_WhenRouteIsNonEmpty_OverwritesBudgetsFromPostRouteBalances() public {
        // it overwrites budgets from post-route balances
        _configRoute(10000, 5e18);
        ISwapAndAdd.AddParams memory p = _routeAdd(10e18);
        (uint256 tokenId, uint128 liq,,) = zap.add(p);
        assertGt(liq, 0, "routed add minted");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT to recipient");
        _assertZapIdle();
    }

    function test_WhenOptimisticLiquidityIsZeroOnMint_RevertsInsufficientLiquidity() public {
        // it reverts with {InsufficientLiquidity}
        ISwapAndAdd.AddParams memory p = _addParams(-887_220, 887_220, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InsufficientLiquidity.selector, 0, 0));
        zap.add(p);
    }

    function test_WhenPostTrimLiquidityLtMinLiquidity_Reverts() public {
        // it reverts with {InsufficientLiquidity}
        ISwapAndAdd.AddParams memory p = _addParams(0, 10e18);
        uint256 snap = vm.snapshotState();
        (, uint128 liq,,) = zap.add(p);
        vm.revertToState(snap);
        p.minLiquidity = liq + 1;
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InsufficientLiquidity.selector, liq + 1, liq));
        zap.add(p);
    }

    function test_WhenOpSucceeds_ZapIsIdle() public {
        // it leaves the zap idle (no pool tokens, no ETH)
        zap.add(_addParams(3e18, 10e18));
        _assertZapIdle();
    }
}
