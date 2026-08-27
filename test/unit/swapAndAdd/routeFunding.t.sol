// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";

/// @notice `routeFunding` end to end: zap-in from arbitrary non-pool tokens. Entries feed the route,
///         unconsumed amounts sweep to the resolved recipient, and the core only sees pool tokens.
///         The `_pull` validation branches are covered in pull.t.sol.
contract RouteFundingTest is BttBase {
    using CurrencyLibrary for Currency;

    MockERC20 internal tokenX;
    address internal recipient;

    function setUp() public override {
        super.setUp();

        // an arbitrary input token, not a pool currency
        tokenX = new MockERC20("Arbitrary", "X", 18);
        tokenX.mint(address(this), 1e30);
        tokenX.approve(address(permit2), type(uint256).max);
        permit2.approve(address(tokenX), address(zap), type(uint160).max, type(uint48).max);

        // a deep reserve pool backs the flash-take
        (PoolKey memory rk,) = initPool(currency0, currency1, IHooks(address(0)), 10000, int24(200), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            rk,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(1e27), salt: 0}),
            ""
        );

        recipient = makeAddr("recipient");
    }

    function _funding(address token, uint256 amount) internal pure returns (ISwapAndAdd.TokenAmount[] memory f) {
        f = new ISwapAndAdd.TokenAmount[](1);
        f[0] = ISwapAndAdd.TokenAmount({token: Currency.wrap(token), amount: amount});
    }

    function _addP(uint256 a0, uint256 a1, bytes memory routeBytes, ISwapAndAdd.TokenAmount[] memory funding)
        internal
        view
        returns (ISwapAndAdd.AddParams memory p)
    {
        p = _addParams(a0, a1);
        p.route = routeBytes;
        p.routeFunding = funding;
        p.minLiquidity = 1;
        p.recipient = recipient;
    }

    /// @dev The route consumes `inputAmount` of X and pays out currency1 1:1.
    function _configXRoute(uint256 inputAmount) internal {
        route.config(address(tokenX), Currency.unwrap(currency1), 1 << 96, 10000, inputAmount, true);
    }

    function _mintViaZap() internal returns (uint256 tokenId) {
        _configXRoute(0); // no-op
        ISwapAndAdd.AddParams memory p = _addP(10e18, 10e18, "", _emptyFunding());
        p.recipient = address(this);
        (tokenId,,,) = zap.add(p);
        _approvePosmForZap();
    }

    // add

    function test_WhenFundedOnlyByX_MintsPosition() public {
        // it funds the whole position from the routed X
        _configXRoute(5e18);
        uint256 xBefore = tokenX.balanceOf(address(this));

        (uint256 tokenId, uint128 liq,,) = zap.add(_addP(0, 0, ROUTE_PAYLOAD, _funding(address(tokenX), 5e18)));

        assertEq(tokenX.balanceOf(address(this)), xBefore - 5e18, "X pulled from the caller");
        assertGt(liq, 0, "position funded entirely by routed X");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), recipient, "NFT to the recipient");
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
        _assertZapIdle();
    }

    function test_WhenTheRouteLeavesSome_LeftoverSweepsToRecipient() public {
        // it sweeps the unconsumed funding to the resolved recipient
        _configXRoute(1e18); // consume only 1 of the 4 supplied
        zap.add(_addP(0, 0, ROUTE_PAYLOAD, _funding(address(tokenX), 4e18)));
        assertEq(tokenX.balanceOf(recipient), 3e18, "unconsumed X swept to the recipient");
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
    }

    function test_WhenEntriesAreDuplicated_BothArePulled() public {
        // it pulls every entry
        _configXRoute(3e18);
        ISwapAndAdd.TokenAmount[] memory f = new ISwapAndAdd.TokenAmount[](2);
        f[0] = ISwapAndAdd.TokenAmount({token: Currency.wrap(address(tokenX)), amount: 1e18});
        f[1] = ISwapAndAdd.TokenAmount({token: Currency.wrap(address(tokenX)), amount: 2e18});
        uint256 xBefore = tokenX.balanceOf(address(this));

        (, uint128 liq,,) = zap.add(_addP(0, 0, ROUTE_PAYLOAD, f));

        assertEq(tokenX.balanceOf(address(this)), xBefore - 3e18, "both entries pulled");
        assertGt(liq, 0, "liquidity");
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
    }

    function test_WhenEntryAmountIsZero_ClaimsTheDonation() public {
        // it pulls nothing but wires and sweeps the donated balance
        tokenX.transfer(address(zap), 5e18); // donation / stuck tokens
        _configXRoute(2e18); // the route consumes part of the donated balance
        (, uint128 liq,,) = zap.add(_addP(0, 1e18, ROUTE_PAYLOAD, _funding(address(tokenX), 0)));
        assertGt(liq, 0, "liquidity");
        assertEq(tokenX.balanceOf(recipient), 3e18, "unconsumed donation claimed to the recipient");
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
    }

    function test_WhenFundingIsNativeOnAnErc20Pool_RoutesTheValue() public {
        // it routes the pushed value and reclaims the remainder from the router
        route.config(address(0), Currency.unwrap(currency1), 1 << 96, 10000, 0.6 ether, true);

        (, uint128 liq,,) = zap.add{value: 1 ether}(_addP(0, 0, ROUTE_PAYLOAD, _funding(address(0), 1 ether)));

        assertGt(liq, 0, "position funded by routed native");
        assertEq(recipient.balance, 0.4 ether, "unconsumed native reclaimed from the UR and swept");
        assertEq(address(route).balance, 0, "nothing left in the UR");
        _assertZapIdle();
    }

    /// @dev On a native pool address(0) is currency0, so the same entry is a pool currency.
    function test_WhenFundingIsNativeOnANativePool_Reverts() public {
        // it reverts with {InvalidFundingToken}
        ISwapAndAdd.AddParams memory p = _addP(0, 1e18, ROUTE_PAYLOAD, _funding(address(0), 1 ether));
        p.poolKey = nativeKey;
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidFundingToken.selector, CurrencyLibrary.ADDRESS_ZERO));
        zap.add{value: 1 ether}(p);
    }

    // increase

    function test_WhenIncreaseHasNoBudgetAndNoFees_FundingSatisfiesTheGate() public {
        // it deploys the routed funding instead of reverting with {NoFeesToCompound}
        uint256 tokenId = _mintViaZap(); // a fresh position: zero accrued fees
        _configXRoute(5e18);
        ISwapAndAdd.IncreaseParams memory p = _increaseParams(tokenId, 0, 0);
        p.route = ROUTE_PAYLOAD;
        p.routeFunding = _funding(address(tokenX), 5e18);
        p.minLiquidityAdded = 1;

        (uint128 added,,) = zap.increase(p);

        assertGt(added, 0, "increase funded entirely by routed X");
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
    }

    function test_WhenOperatorFundsAnIncrease_LeftoverGoesToOwner() public {
        // it forces the unconsumed funding to the owner
        uint256 tokenId = _mintViaZap();
        address operator = makeAddr("operator");
        IERC721(address(lpm)).approve(operator, tokenId);

        tokenX.mint(operator, 3e18);
        vm.startPrank(operator);
        tokenX.approve(address(permit2), type(uint256).max);
        permit2.approve(address(tokenX), address(zap), type(uint160).max, type(uint48).max);
        _configXRoute(1e18); // consume 1 of the 3 of the operator

        ISwapAndAdd.IncreaseParams memory p = _increaseParams(tokenId, 0, 0);
        p.route = ROUTE_PAYLOAD;
        p.routeFunding = _funding(address(tokenX), 3e18);
        p.minLiquidityAdded = 1;
        p.recipient = operator; // ignored: the caller is an operator

        uint256 ownerXBefore = tokenX.balanceOf(address(this));
        zap.increase(p);
        vm.stopPrank();

        assertEq(tokenX.balanceOf(operator), 0, "operator keeps nothing");
        assertEq(tokenX.balanceOf(address(this)) - ownerXBefore, 2e18, "leftover forced to the owner");
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
    }

    // rebalance

    function test_WhenRebalanceIsFunded_TopsUpViaRoute() public {
        // it adds the routed funding to the redeployed position
        uint256 tokenId = _mintViaZap();
        _configXRoute(2e18);
        ISwapAndAdd.RebalanceParams memory p = _rebalanceParams(tokenId, 0, 0);
        p.route = ROUTE_PAYLOAD;
        p.routeFunding = _funding(address(tokenX), 2e18);
        p.minLiquidity = 1;

        (uint256 newTokenId, uint128 liq,,) = zap.rebalance(p);

        assertGt(newTokenId, tokenId, "new position minted");
        assertGt(liq, 0, "liquidity");
        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this), "NFT to the owner");
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
    }
}
