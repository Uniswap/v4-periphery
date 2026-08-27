// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {MockSwapRoute} from "./mocks/MockSwapRoute.sol";
import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";

/// @notice `routeFunding`: zap-in from arbitrary non-pool tokens. Entries feed the route, unconsumed
///         amounts sweep to the resolved recipient, and the core only sees pool-token balances.
contract SwapAndAddRouteFundingTest is PosmTestSetup {
    using CurrencyLibrary for Currency;

    ISwapAndAdd zap;
    MockSwapRoute route;
    MockERC20 tokenX;
    address recipient;

    /// @dev abi.encode(bytes commands, bytes[] inputs), a non-empty route payload the mock ignores.
    bytes ROUTE_PAYLOAD = abi.encode(bytes(""), new bytes[](0));

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        route = new MockSwapRoute(permit2);
        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(address(route))))
        );

        seedBalance(address(this));
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);

        // arbitrary input token, not a pool currency
        tokenX = new MockERC20("Arbitrary", "X", 18);
        tokenX.mint(address(this), 1e30);
        tokenX.approve(address(permit2), type(uint256).max);
        permit2.approve(address(tokenX), address(zap), type(uint160).max, type(uint48).max);

        // route inventory: the mock pays out pool tokens for consumed input
        MockERC20(Currency.unwrap(currency0)).mint(address(route), 1e24);
        MockERC20(Currency.unwrap(currency1)).mint(address(route), 1e24);

        // deep reserve pool backs the flash-take
        (PoolKey memory rk,) = initPool(currency0, currency1, IHooks(address(0)), 10000, int24(200), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            rk,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(1e27), salt: 0}),
            ""
        );

        recipient = makeAddr("recipient");
    }

    // helpers

    function _funding(address token, uint256 amount) internal pure returns (ISwapAndAdd.TokenAmount[] memory f) {
        f = new ISwapAndAdd.TokenAmount[](1);
        f[0] = ISwapAndAdd.TokenAmount({token: Currency.wrap(token), amount: amount});
    }

    function _addP(uint256 a0, uint256 a1, bytes memory routeBytes, ISwapAndAdd.TokenAmount[] memory funding)
        internal
        view
        returns (ISwapAndAdd.AddParams memory)
    {
        return ISwapAndAdd.AddParams({
            poolKey: key,
            tickLower: -600,
            tickUpper: 600,
            amount0In: a0,
            amount1In: a1,
            route: routeBytes,
            routeFunding: funding,
            minLiquidity: 1,
            recipient: recipient,
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    /// @dev route: consume `inputAmount` of X, pay out currency1 1:1
    function _configXRoute(uint256 inputAmount) internal {
        route.config(address(tokenX), Currency.unwrap(currency1), 1 << 96, 10000, inputAmount, true);
    }

    // add: the zap-in-from-X happy paths

    function test_add_funding_xOnly_mintsPosition() public {
        _configXRoute(5e18);
        uint256 xBefore = tokenX.balanceOf(address(this));

        (uint256 tokenId, uint128 liq,,) = zap.add(_addP(0, 0, ROUTE_PAYLOAD, _funding(address(tokenX), 5e18)));

        assertEq(tokenX.balanceOf(address(this)), xBefore - 5e18, "X pulled from caller");
        assertGt(liq, 0, "position funded entirely by routed X");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), recipient, "NFT to recipient");
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
        assertEq(currency0.balanceOf(address(zap)), 0, "no funds at rest (0)");
        assertEq(currency1.balanceOf(address(zap)), 0, "no funds at rest (1)");
    }

    function test_add_funding_leftoverSweptToRecipient() public {
        _configXRoute(1e18); // consume only 1 of the 4 supplied
        zap.add(_addP(0, 0, ROUTE_PAYLOAD, _funding(address(tokenX), 4e18)));
        assertEq(tokenX.balanceOf(recipient), 3e18, "unconsumed X swept to the recipient");
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
    }

    function test_add_funding_duplicateEntriesAllowed() public {
        _configXRoute(3e18);
        ISwapAndAdd.TokenAmount[] memory f = new ISwapAndAdd.TokenAmount[](2);
        f[0] = ISwapAndAdd.TokenAmount({token: Currency.wrap(address(tokenX)), amount: 1e18});
        f[1] = ISwapAndAdd.TokenAmount({token: Currency.wrap(address(tokenX)), amount: 2e18});
        uint256 xBefore = tokenX.balanceOf(address(this));

        (, uint128 liq,,) = zap.add(_addP(0, 0, ROUTE_PAYLOAD, f));

        assertEq(tokenX.balanceOf(address(this)), xBefore - 3e18, "both entries pulled");
        assertGt(liq, 0);
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
    }

    /// @dev a zero-amount entry pulls nothing but wires and sweeps the token (donation claim)
    function test_add_funding_zeroAmountEntry_claimsDonation() public {
        tokenX.transfer(address(zap), 5e18); // donation / stuck tokens
        _configXRoute(2e18); // the route consumes part of the donated balance
        (, uint128 liq,,) = zap.add(_addP(0, 1e18, ROUTE_PAYLOAD, _funding(address(tokenX), 0)));
        assertGt(liq, 0);
        assertEq(tokenX.balanceOf(recipient), 3e18, "unconsumed donation claimed to the recipient");
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
    }

    // add: native funding on a non-native pool

    function test_add_funding_native() public {
        // route: consume 0.6 ETH of the pushed value, pay out currency1 1:1
        route.config(address(0), Currency.unwrap(currency1), 1 << 96, 10000, 0.6 ether, true);

        (, uint128 liq,,) = zap.add{value: 1 ether}(_addP(0, 0, ROUTE_PAYLOAD, _funding(address(0), 1 ether)));

        assertGt(liq, 0, "position funded by routed native");
        assertEq(recipient.balance, 0.4 ether, "unconsumed native reclaimed from the UR and swept");
        assertEq(address(zap).balance, 0, "no native at rest");
        assertEq(address(route).balance, 0, "nothing left in the UR");
    }

    function test_add_funding_native_revertsOnWrongValue() public {
        route.config(address(0), Currency.unwrap(currency1), 1 << 96, 10000, 1 ether, true);
        ISwapAndAdd.AddParams memory p = _addP(0, 0, ROUTE_PAYLOAD, _funding(address(0), 1 ether));
        vm.expectRevert(ISwapAndAdd.InvalidEthValue.selector);
        zap.add{value: 0.5 ether}(p);
    }

    // guards

    function test_add_funding_revertsWithoutRoute() public {
        ISwapAndAdd.AddParams memory p = _addP(0, 1e18, "", _funding(address(tokenX), 1e18));
        vm.expectRevert(ISwapAndAdd.RouteFundingRequiresRoute.selector);
        zap.add(p);
    }

    function test_add_funding_rejectsPoolCurrencies() public {
        ISwapAndAdd.AddParams memory p = _addP(0, 1e18, ROUTE_PAYLOAD, _funding(Currency.unwrap(currency0), 1e18));
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidFundingToken.selector, currency0));
        zap.add(p);

        p = _addP(0, 1e18, ROUTE_PAYLOAD, _funding(Currency.unwrap(currency1), 1e18));
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidFundingToken.selector, currency1));
        zap.add(p);
    }

    /// @dev on a native pool address(0) is currency0 and is rejected as a pool currency
    function test_add_funding_rejectsNativeEntryOnNativePool() public {
        ISwapAndAdd.AddParams memory p = _addP(0, 1e18, ROUTE_PAYLOAD, _funding(address(0), 1 ether));
        p.poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.InvalidFundingToken.selector, CurrencyLibrary.ADDRESS_ZERO));
        zap.add{value: 1 ether}(p);
    }

    // increase: funding must satisfy the nothing-to-deploy gate via the route

    function _mintViaZap() internal returns (uint256 tokenId) {
        _configXRoute(0); // no-op
        ISwapAndAdd.AddParams memory p = _addP(10e18, 10e18, "", new ISwapAndAdd.TokenAmount[](0));
        p.recipient = address(this);
        (tokenId,,,) = zap.add(p);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
    }

    function test_increase_funding_zeroBudgetZeroFees_worksViaRoute() public {
        uint256 tokenId = _mintViaZap(); // fresh position: zero accrued fees
        _configXRoute(5e18);
        (uint128 added,,) = zap.increase(
            ISwapAndAdd.IncreaseParams({
                tokenId: tokenId,
                amount0In: 0,
                amount1In: 0,
                route: ROUTE_PAYLOAD,
                routeFunding: _funding(address(tokenX), 5e18),
                minLiquidityAdded: 1,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
        assertGt(added, 0, "increase funded entirely by routed X (NoFeesToCompound must not fire)");
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
    }

    /// @dev an operator's unconsumed funding is forced to the owner, like any other output
    function test_increase_funding_operatorLeftoverForcedToOwner() public {
        uint256 tokenId = _mintViaZap();
        address operator = makeAddr("operator");
        IERC721(address(lpm)).approve(operator, tokenId);

        tokenX.mint(operator, 3e18);
        vm.startPrank(operator);
        tokenX.approve(address(permit2), type(uint256).max);
        permit2.approve(address(tokenX), address(zap), type(uint160).max, type(uint48).max);
        _configXRoute(1e18); // consume 1 of the operator's 3

        uint256 ownerXBefore = tokenX.balanceOf(address(this));
        zap.increase(
            ISwapAndAdd.IncreaseParams({
                tokenId: tokenId,
                amount0In: 0,
                amount1In: 0,
                route: ROUTE_PAYLOAD,
                routeFunding: _funding(address(tokenX), 3e18),
                minLiquidityAdded: 1,
                recipient: operator, // ignored: caller is an operator
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
        vm.stopPrank();

        assertEq(tokenX.balanceOf(operator), 0, "operator keeps nothing");
        assertEq(tokenX.balanceOf(address(this)) - ownerXBefore, 2e18, "leftover forced to the owner");
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
    }

    // rebalance with funding

    function test_rebalance_funding_topsUpViaRoute() public {
        uint256 tokenId = _mintViaZap();
        _configXRoute(2e18);
        (uint256 newTokenId, uint128 liq,,) = zap.rebalance(
            ISwapAndAdd.RebalanceParams({
                tokenId: tokenId,
                additional0: 0,
                additional1: 0,
                newTickLower: -1200,
                newTickUpper: 1200,
                route: ROUTE_PAYLOAD,
                routeFunding: _funding(address(tokenX), 2e18),
                minLiquidity: 1,
                recipient: address(this),
                hookData: "",
                deadline: block.timestamp + 1
            })
        );
        assertGt(newTokenId, tokenId, "new position minted");
        assertGt(liq, 0);
        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), address(this));
        assertEq(tokenX.balanceOf(address(zap)), 0, "no X at rest");
    }
}
