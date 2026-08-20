// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";
import {PositionConfig} from "./shared/PositionConfig.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";

interface IERC20Min {
    function transfer(address to, uint256 amt) external returns (bool);
}

/// @notice A route that swaps in the TARGET pool (exactly what a real Universal Router v4 leg does when the
///         off-chain router picks the same pool). Pulls its declared input from the caller via Permit2, swaps,
///         settles its own input debt and takes its own output straight to the caller.
contract MockSamePoolRoute {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable manager;
    IAllowanceTransfer public immutable permit2;

    PoolKey internal key;
    bool internal zeroForOne;
    uint256 internal inputAmount;

    constructor(IPoolManager _manager, IAllowanceTransfer _permit2) {
        manager = _manager;
        permit2 = _permit2;
    }

    function config(PoolKey memory k, bool z, uint256 amt) external {
        key = k;
        zeroForOne = z;
        inputAmount = amt;
    }

    function execute(bytes calldata, bytes[] calldata) external payable {
        Currency cIn = zeroForOne ? key.currency0 : key.currency1;
        Currency cOut = zeroForOne ? key.currency1 : key.currency0;
        permit2.transferFrom(msg.sender, address(this), uint160(inputAmount), Currency.unwrap(cIn));

        BalanceDelta d = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(inputAmount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 inDelta = zeroForOne ? d.amount0() : d.amount1();
        int128 outDelta = zeroForOne ? d.amount1() : d.amount0();

        manager.sync(cIn);
        IERC20Min(Currency.unwrap(cIn)).transfer(address(manager), uint256(uint128(-inDelta)));
        manager.settle();
        manager.take(cOut, msg.sender, uint256(uint128(outDelta)));
    }
}

/// @notice Regression: `increase`/`compound` with a route leg through the SAME pool re-accrues LP fees to the
///         position between the callback's first collect prologue and `_deploy`'s INCREASE_LIQUIDITY. POSM
///         credits the whole accrued fee balance on the increase; a credit exceeding the increase's principal
///         on either side would flip POSM's delta positive and make SETTLE_PAIR revert DeltaNotNegative. The
///         fix re-collects after the route (see `_addCore`), so route-accrued fees join the budget instead.
contract SwapAndAddSamePoolRouteTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    ISwapAndAdd zap;
    MockSamePoolRoute route;
    PoolKey targetKey;

    int24 constant TL = -600;
    int24 constant TU = 600;
    uint256 constant L_POS = 1e24;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        MockERC20(Currency.unwrap(currency0)).mint(address(this), 1e40);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e40);
        seedBalance(address(this));
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);

        // target pool: 10% LP fee, spot ABOVE the position's range (tick 1200 > TU), no other liquidity
        (targetKey,) = initPool(
            currency0, currency1, IHooks(address(0)), 100_000, int24(60), TickMath.getSqrtPriceAtTick(int24(1200))
        );

        // deep reserve pool in an UNRELATED pool so the flash-take always finds PoolManager reserves (K-05)
        (PoolKey memory rk,) = initPool(currency0, currency1, IHooks(address(0)), 500, int24(10), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            rk,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(1e30), salt: 0}),
            ""
        );

        route = new MockSamePoolRoute(manager, permit2);
        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(address(route))))
        );
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
    }

    function _encodedRoute() internal pure returns (bytes memory) {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = "";
        return abi.encode(bytes(hex"00"), inputs);
    }

    /// @dev A route leg that trades the target pool and drives spot into the position's own range accrues LP
    ///      fees far exceeding the increase's principal on the deficit side. Before the fix this reverted
    ///      DeltaNotNegative(currency0); the post-route re-collect folds those fees into the budget so the
    ///      increase completes and the fees are reinvested (never leaked to the wallet).
    function test_increase_samePoolRouteLeg_reinvestsAccruedFees() public {
        // 1. the position, minted straight through POSM (spot is above TU: pure token1)
        PositionConfig memory cfg = PositionConfig({poolKey: targetKey, tickLower: TL, tickUpper: TU});
        uint256 tokenId = lpm.nextTokenId();
        mint(cfg, L_POS, address(this), "");

        // 2. the caller's route: sell token0 into the same pool. Spot free-falls from tick 1200 to TU=600
        //    (no liquidity in between), then eats ~10 ticks into the position's own range: every wei of LP fee
        //    on that leg accrues to THIS position — ~13x the increase's token0 principal pull.
        uint256 routeIn = 5.4e20;
        route.config(targetKey, true, routeIn);

        uint256 c0Before = currency0.balanceOf(address(this));
        uint256 c1Before = currency1.balanceOf(address(this));

        // same budget, same pool, swap leg runs through the target pool: the pre-fix DeltaNotNegative case.
        (uint128 added,,) = zap.increase(
            ISwapAndAdd.IncreaseParams({
                tokenId: tokenId,
                amount0In: routeIn,
                amount1In: 0,
                route: _encodedRoute(),
                routeFunding: new ISwapAndAdd.TokenAmount[](0),
                minLiquidityAdded: 1,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );

        assertGt(added, 0, "increase must complete with a same-pool route leg");
        // no funds at rest, and the position NFT never moved
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "owner keeps the NFT");
        // the caller spent token0 (the route input) and got only dust back — fees were reinvested, not paid out
        assertLt(currency0.balanceOf(address(this)), c0Before, "token0 budget consumed");
        assertLe(currency1.balanceOf(address(this)) - c1Before, routeIn / 100, "no material payout to the wallet");
    }
}
