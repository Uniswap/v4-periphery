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

/// @notice A route that swaps in the target pool, like a Universal Router v4 leg through the same pool.
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

/// @notice A route leg through the target pool accrues LP fees to the position mid-operation, which can
///         turn a POSM delta positive. `_deployLiquidity` closes each currency with `CLOSE_CURRENCY`, so
///         the credit is taken and refunded after sizing. Fees accrued before the operation still compound.
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

        // target pool: 10% LP fee, spot above the position's range (tick 1200 > TU), no other liquidity
        (targetKey,) = initPool(
            currency0, currency1, IHooks(address(0)), 100_000, int24(60), TickMath.getSqrtPriceAtTick(int24(1200))
        );

        // deep reserves in an unrelated pool so the flash-take always finds PoolManager-wide liquidity
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

    /// @dev A same-pool route leg drives spot into the range of the position and accrues fees ~13x the
    ///      deficit-side principal. The deploy takes the credit and the surplus is refunded.
    function test_increase_samePoolRouteLeg_completesAndRefundsFeeCredit() public {
        // the position, minted straight through POSM (spot above TU: pure token1)
        PositionConfig memory cfg = PositionConfig({poolKey: targetKey, tickLower: TL, tickUpper: TU});
        uint256 tokenId = lpm.nextTokenId();
        mint(cfg, L_POS, address(this), "");

        // the route sells token0 into the same pool. Spot falls from tick 1200 into the range of the
        // position, so every LP fee on the leg accrues to this position.
        uint256 routeIn = 5.4e20;
        route.config(targetKey, true, routeIn);

        uint256 c0Before = currency0.balanceOf(address(this));
        uint256 c1Before = currency1.balanceOf(address(this));

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

        // 10% LP fee on the whole route input, all of it to this position (it is the pool's only liquidity)
        uint256 accruedFee = routeIn / 10;
        uint256 refunded = routeIn - (c0Before - currency0.balanceOf(address(this)));

        assertGt(added, 0, "increase must complete with a same-pool route leg");
        // the fee credit funds the flash debt first (~1/13 here) and the remainder is refunded, not compounded
        assertLt(refunded, accruedFee, "part of the credit funded the flash debt");
        assertGt(refunded, (accruedFee * 85) / 100, "the bulk of the credit is refunded");
        // no funds at rest, and the position NFT never moved
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
        assertGt(currency1.balanceOf(address(this)), c1Before, "token1 surplus refunded in its own denomination");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), address(this), "owner keeps the NFT");
    }

    /// @dev When the fee credit alone retires the flash debt, the reconcile swap is skipped and the
    ///      token1 surplus comes back in its own denomination.
    function test_increase_creditRetiresDebt_skipsGratuitousSwap() public {
        PositionConfig memory cfg = PositionConfig({poolKey: targetKey, tickLower: TL, tickUpper: TU});
        uint256 tokenId = lpm.nextTokenId();
        mint(cfg, L_POS, address(this), "");

        uint256 routeIn = 5.4e20;
        route.config(targetKey, true, routeIn);
        uint256 c1Before = currency1.balanceOf(address(this));

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
        assertGt(added, 0, "increase completes");

        // the credit retires the flash debt, so no reconcile swap runs and the surplus comes back as token1
        assertGt(currency1.balanceOf(address(this)), c1Before, "surplus refunded in its own denomination");
        assertEq(currency0.balanceOf(address(zap)), 0, "zap token0 == 0");
        assertEq(currency1.balanceOf(address(zap)), 0, "zap token1 == 0");
    }
}
