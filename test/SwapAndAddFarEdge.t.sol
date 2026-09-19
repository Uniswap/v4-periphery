// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";

/// @notice The reconcile sell must never land the price on or past the range's far edge with debt still
///         owed, which raw-reverts in `_trim`. Worse-than-spot execution on a spot-sized surplus keeps
///         the post-sell price strictly inside the far edge on hookless pools.
contract SwapAndAddFarEdgeTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    ISwapAndAdd zap;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);
        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(makeAddr("ur"))))
        );
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e40);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e40);

        // deep unrelated reserve pool backs the flash-take. Its key never collides with the probe pools.
        (PoolKey memory rk,) = initPool(currency0, currency1, IHooks(address(0)), 500_000, int24(200), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            rk,
            ModifyLiquidityParams({tickLower: -887_200, tickUpper: 887_200, liquidityDelta: int256(1e30), salt: 0}),
            ""
        );
    }

    /// @dev fresh pool at tick 0. The zap's own mint is (near-)all the liquidity, the config that gets
    ///      the sell closest to the far edge.
    function _pool(uint24 fee, int24 spacing, uint128 extLiquidity) internal returns (PoolKey memory k) {
        k = PoolKey({
            currency0: currency0, currency1: currency1, fee: fee, tickSpacing: spacing, hooks: IHooks(address(0))
        });
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
        if (extLiquidity > 0) {
            // a dust-thin full-domain band breaks the scale-invariance so budget size varies the landing point
            modifyLiquidityRouter.modifyLiquidity(
                k,
                ModifyLiquidityParams({
                    tickLower: -887_200, tickUpper: 887_200, liquidityDelta: int256(uint256(extLiquidity)), salt: 0
                }),
                ""
            );
        }
    }

    function _addP(PoolKey memory k, int24 tl, int24 tu, uint256 b0, uint256 b1)
        internal
        view
        returns (ISwapAndAdd.AddParams memory)
    {
        return ISwapAndAdd.AddParams({
            poolKey: k,
            tickLower: tl,
            tickUpper: tu,
            amount0In: b0,
            amount1In: b1,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 1,
            recipient: address(this),
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    /// @dev run one add. On success the post-op price must sit strictly inside both edges.
    function _probe(PoolKey memory k, int24 tl, int24 tu, uint256 b0, uint256 b1) internal {
        try zap.add(_addP(k, tl, tu, b0, b1)) returns (uint256, uint128 liq, uint256, uint256) {
            assertGt(liq, 0);
            (uint160 sp,,,) = manager.getSlot0(k.toId());
            assertGt(sp, TickMath.getSqrtPriceAtTick(tl), "price reached/passed the LOWER edge");
            assertLt(sp, TickMath.getSqrtPriceAtTick(tu), "price reached/passed the UPPER edge");
        } catch (bytes memory reason) {
            bytes4 sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            assertTrue(
                sel == ISwapAndAdd.InsufficientLiquidity.selector || sel == bytes4(keccak256("CurrencyNotSettled()")),
                "raw revert from the reconcile/trim: far-edge state reached"
            );
        }
    }

    uint24 private feeNonce;

    /// @dev grid over the tightest configs (zero fee has no fee cushion). The fee nonce keeps the pool
    ///      keys unique.
    function test_farEdge_gridSweep_neverRawReverts() public {
        uint24[3] memory fees = [uint24(0), 500, 3000];
        int24[3] memory widths = [int24(60), 600, 6000];
        uint128[2] memory ext = [uint128(0), 1e6];
        for (uint256 f = 0; f < 3; f++) {
            for (uint256 w = 0; w < 3; w++) {
                for (uint256 e = 0; e < 2; e++) {
                    PoolKey memory k = _pool(fees[f] + feeNonce++, int24(10), ext[e]);
                    _probe(k, -widths[w], widths[w], 1e20, 0); // token1 deficit: sell descends toward tl
                    k = _pool(fees[f] + feeNonce++, int24(10), ext[e]);
                    _probe(k, -widths[w], widths[w], 0, 1e20); // token0 deficit: sell ascends toward tu
                }
            }
        }

        // narrowest legal geometry (tickSpacing 1, 1..5 ticks per side), where the impact margin is smallest
        int24[3] memory narrow = [int24(1), 2, 5];
        for (uint256 n = 0; n < 3; n++) {
            for (uint256 e = 0; e < 2; e++) {
                PoolKey memory k = _pool(feeNonce++, int24(1), ext[e]);
                _probe(k, -narrow[n], narrow[n], 1e20, 0);
                k = _pool(feeNonce++, int24(1), ext[e]);
                _probe(k, -narrow[n], narrow[n], 0, 1e20);
            }
        }
    }

    /// @dev fuzzed budgets, widths, and fees. A far-edge landing shows up as a raw revert.
    function testFuzz_farEdge_neverRawReverts(
        uint256 b0,
        uint256 b1,
        uint8 widthMul,
        uint8 feeIdx,
        bool ext,
        bool thin
    ) public {
        uint24[4] memory fees = [uint24(0), 100, 3000, 100_000];
        int24 spacing = thin ? int24(1) : int24(10);
        int24 width = spacing * int24(uint24(bound(widthMul, 1, 200))); // down to a single tick each side
        b0 = bound(b0, 0, 1e22);
        b1 = bound(b1, 0, 1e22);
        vm.assume(b0 + b1 >= 1e12);

        PoolKey memory k = _pool(fees[feeIdx % 4], spacing, ext ? uint128(1e6) : uint128(0));
        _probe(k, -width, width, b0, b1);
    }
}
