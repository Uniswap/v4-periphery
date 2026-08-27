// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {MockERC20ApproveNoReturn} from "../../mocks/MockERC20ApproveNoReturn.sol";
import {MockERC20Permit2Native} from "../../mocks/MockERC20Permit2Native.sol";
import {MockERC20ApproveRace} from "../../mocks/MockERC20ApproveRace.sol";
import {BttBase} from "./BttBase.sol";

/// @notice `_ensureApproved` against tokens whose approve() breaks the plain ERC20 contract.
contract EnsureApprovedTest is BttBase {
    using CurrencyLibrary for Currency;

    /// @dev A native/token pool with depth, so an add against the weird token has somewhere to land.
    function _initWeirdTokenPool(address token) internal returns (PoolKey memory k) {
        (k,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(token), IHooks(address(0)), 3000, SQRT_PRICE_1_1, 1 ether
        );
        modifyLiquidityRouter.modifyLiquidity{value: 50 ether}(
            k,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: int256(uint256(200e18)), salt: 0}),
            ""
        );
    }

    function test_WhenApproveReturnsNothing_AddCompletes() public {
        // it treats the call as a success and the add completes
        MockERC20ApproveNoReturn usdt = new MockERC20ApproveNoReturn();
        usdt.mint(address(this), 1_000e18);
        usdt.approve(address(permit2), type(uint256).max);
        permit2.approve(address(usdt), address(zap), type(uint160).max, type(uint48).max);
        usdt.approve(address(modifyLiquidityRouter), type(uint256).max);

        ISwapAndAdd.AddParams memory p = _addParams(0, 5e18);
        p.poolKey = _initWeirdTokenPool(address(usdt));
        (uint256 tokenId, uint128 liq,,) = zap.add(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "minted on an approve-no-return token pool");
        assertEq(usdt.balanceOf(address(zap)), 0, "no token at rest");
        assertEq(address(zap).balance, 0, "no eth at rest");
    }

    function test_WhenApproveTowardPermit2Reverts_SkipsItAndWiresPermit2() public {
        // it skips that call and still grants the Permit2 allowances
        MockERC20Permit2Native token = new MockERC20Permit2Native(address(permit2));
        token.mint(address(this), 1_000e18);
        // the token hardcodes its Permit2 allowance, so there is no token.approve(permit2) here
        permit2.approve(address(token), address(zap), type(uint160).max, type(uint48).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        ISwapAndAdd.AddParams memory p = _addParams(0, 5e18);
        p.poolKey = _initWeirdTokenPool(address(token));
        (uint256 tokenId, uint128 liq,,) = zap.add(p);

        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "NFT owner");
        assertGt(liq, 0, "minted on a permit2-native token pool");
        (uint160 posmAmount,,) = permit2.allowance(address(zap), address(token), address(lpm));
        (uint160 urAmount,,) = permit2.allowance(address(zap), address(token), address(route));
        assertEq(posmAmount, type(uint160).max, "POSM permit2 allowance granted");
        assertEq(urAmount, type(uint160).max, "UR permit2 allowance granted");

        // it never touches approve again once the token is wired
        (, liq,,) = zap.add(p);
        assertGt(liq, 0, "second add on an already-wired token");
    }

    function test_WhenAllowanceDegraded_ReapprovesZeroFirst() public {
        // it re-approves zero-first and heals back to max
        MockERC20ApproveRace token = new MockERC20ApproveRace();
        token.mint(address(this), 1_000e18);
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(zap), type(uint160).max, type(uint48).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        ISwapAndAdd.AddParams memory p = _addParams(0, 5e18);
        p.poolKey = _initWeirdTokenPool(address(token));
        zap.add(p); // wires the token to the max allowance
        assertEq(token.allowance(address(zap), address(permit2)), type(uint256).max, "wired to max");

        // degrade to a non-zero value, so a heal that is not zero-first trips the approve race
        token.setAllowance(address(zap), address(permit2), 1e18);

        (, uint128 liq,,) = zap.add(p);

        assertGt(liq, 0, "add succeeded after the self-heal");
        assertEq(token.allowance(address(zap), address(permit2)), type(uint256).max, "allowance healed to max");
    }

    /// @dev No pool can hold native as currency1, so the key must fail and unwind.
    function test_WhenNativeIsCurrency1_RevertsAtomically() public {
        // it reverts and unwinds atomically
        ISwapAndAdd.AddParams memory p = _addParams(0, 5e18);
        p.poolKey = PoolKey({
            currency0: currency0,
            currency1: CurrencyLibrary.ADDRESS_ZERO,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, 0));
        zap.add(p);

        permit2.approve(address(0), address(zap), type(uint160).max, type(uint48).max);
        vm.expectRevert(Pool.PoolNotInitialized.selector);
        zap.add(p);
    }
}
