// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {Actions} from "../src/libraries/Actions.sol";
import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {SafeCallback} from "../src/base/SafeCallback.sol";
import {DeltaResolver} from "../src/base/DeltaResolver.sol";
import {IPositionManager} from "../src/interfaces/IPositionManager.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Harness proving the option-C load-bearing mechanic: inside ONE poolManager unlock,
///      MINT a position to itself, swap, then DECREASE that SAME just-minted tokenId, and settle.
contract MintTrimHarness is SafeCallback, DeltaResolver {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPositionManager public immutable pm;
    IAllowanceTransfer public immutable permit2;
    uint256 public mintedTokenId;

    constructor(IPoolManager _pm, IPositionManager _posm, IAllowanceTransfer _p2) SafeCallback(_pm) {
        pm = _posm;
        permit2 = _p2;
    }

    /// @param flashTake0 token0 to flash-`take` before the mint (simulates the deficit borrow)
    /// @param swapAmt    same-pool swap amountSpecified (negative = exact-in token0->token1); 0 to skip
    function run(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 mintL,
        uint256 flashTake0,
        int256 swapAmt,
        uint128 trimL
    ) external {
        poolManager.unlock(abi.encode(key, tickLower, tickUpper, mintL, flashTake0, swapAmt, trimL));
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (
            PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            uint128 mintL,
            uint256 flashTake0,
            int256 swapAmt,
            uint128 trimL
        ) = abi.decode(data, (PoolKey, int24, int24, uint128, uint256, int256, uint128));

        Currency c0 = key.currency0;
        Currency c1 = key.currency1;
        _approve(c0);
        _approve(c1);

        // (pre) optionally flash-take the deficit token0 — exactly what option C does to mint optimistically.
        if (flashTake0 > 0) _take(c0, address(this), flashTake0);

        // (a) MINT to SELF
        uint256 tokenId = pm.nextTokenId();
        mintedTokenId = tokenId;
        {
            bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(key, tickLower, tickUpper, mintL, type(uint128).max, type(uint128).max, address(this), bytes(""));
            params[1] = abi.encode(c0, c1);
            pm.modifyLiquiditiesWithoutUnlock(actions, params);
        }

        // (b) same-pool swap
        if (swapAmt != 0) {
            poolManager.swap(
                key,
                SwapParams({zeroForOne: true, amountSpecified: swapAmt, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
                ""
            );
        }

        // (c) DECREASE the SAME just-minted tokenId
        {
            bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(tokenId, uint256(trimL), uint128(0), uint128(0), bytes(""));
            params[1] = abi.encode(c0, c1, ActionConstants.MSG_SENDER);
            pm.modifyLiquiditiesWithoutUnlock(actions, params);
        }

        // (d) resolve any net deltas (the swap, and the flash-take repaid from freed/held balances)
        _resolve(c0);
        _resolve(c1);
        return "";
    }

    function _resolve(Currency c) internal {
        int256 d = poolManager.currencyDelta(address(this), c);
        if (d < 0) _settle(c, address(this), uint256(-d));
        else if (d > 0) _take(c, address(this), uint256(d));
    }

    function _approve(Currency c) internal {
        address t = Currency.unwrap(c);
        IERC20Min(t).approve(address(permit2), type(uint256).max);
        permit2.approve(t, address(pm), type(uint160).max, type(uint48).max);
    }

    function _pay(Currency currency, address, uint256 amount) internal override {
        currency.transfer(address(poolManager), amount);
    }
}

contract MintTrimProbeTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    MintTrimHarness harness;
    int24 constant TL = -600;
    int24 constant TU = 600;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);
        seedMoreLiquidity(key, 1_000e18, 1_000e18);

        harness = new MintTrimHarness(manager, lpm, permit2);
        // fund the harness generously with both tokens
        MockERC20(Currency.unwrap(currency0)).mint(address(harness), 1_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(harness), 1_000e18);
    }

    function _liq(uint256 a0, uint256 a1) internal view returns (uint128) {
        (uint160 sp,,,) = manager.getSlot0(key.toId());
        return LiquidityAmounts.getLiquidityForAmounts(
            sp, TickMath.getSqrtPriceAtTick(TL), TickMath.getSqrtPriceAtTick(TU), a0, a1
        );
    }

    /// Core proof: MINT-to-self -> swap -> DECREASE-same-id -> settle, all in one unlock.
    function test_sameUnlock_mint_swap_decrease() public {
        uint128 mintL = _liq(10e18, 10e18);
        uint128 trimL = mintL / 4;

        harness.run(key, TL, TU, mintL, 0, -1e15, trimL);

        uint256 id = harness.mintedTokenId();
        assertEq(IERC721(address(lpm)).ownerOf(id), address(harness), "harness owns minted NFT");
        assertEq(lpm.getPositionLiquidity(id), mintL - trimL, "position reduced by trimL");
        // unlock closed without revert => deltas settled. Harness should hold no negative position.
        assertGt(currency0.balanceOf(address(harness)), 0, "still holds token0");
        assertGt(currency1.balanceOf(address(harness)), 0, "still holds token1");
    }

    /// Faithful option-C shape: flash-take the token0 deficit, optimistic-mint, swap to fund,
    /// then trim the SAME id to free what the swap fell short by, and settle.
    function test_sameUnlock_flashTake_mint_swap_trim() public {
        uint128 mintL = _liq(10e18, 10e18);
        // flash-take roughly the token0 the mint needs (deficit side), then swap token1->? to (under)fund,
        // and trim to cover the rest. Numbers chosen so the unlock must net out via the trim.
        harness.run(key, TL, TU, mintL, 9e18, -2e18, mintL / 5);

        uint256 id = harness.mintedTokenId();
        assertEq(IERC721(address(lpm)).ownerOf(id), address(harness), "owns NFT");
        assertEq(lpm.getPositionLiquidity(id), mintL - mintL / 5, "reduced by trim");
    }
}
