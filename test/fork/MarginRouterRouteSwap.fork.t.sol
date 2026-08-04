// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {RouterParameters} from "universal-router/contracts/types/RouterParameters.sol";

import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {IComet} from "../../src/interfaces/external/compound-v3/IComet.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {CompoundV3LendingAdapter} from "../../src/CompoundV3LendingAdapter.sol";
import {MarginActions} from "../../src/libraries/MarginActions.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv, raw} from "../../src/types/Ltv.sol";

/// @notice Fork test proving the `ROUTE_SWAP` action opens a leveraged long-WETH position on Compound
///         v3 by routing the debt->collateral swap through a real Universal Router over a live Uniswap
///         v3 pool. Exercises the flash-take envelope end to end: the router flash-takes USDC from a
///         local PoolManager, funds UR via a scoped Permit2 allowance, UR buys WETH exact-output on the
///         mainnet USDC/WETH 0.05% pool and delivers it to the account, the router settles the unspent
///         take, and the composed supply/borrow/settle nets to zero. Driven through the generalized
///         `execute` entrypoint (the account-scoped plan a curated entry will later build internally).
import {MarginRouteHelpers} from "../shared/MarginRouteHelpers.sol";

contract MarginRouterRouteSwapForkTest is Test, MarginRouteHelpers {
    IComet internal constant COMET = IComet(0xc3d688B66703497DAA19211EEdff47f25384cdc3); // cUSDCv3
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // collateral (18 dec)
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // debt/base (6 dec)
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    bytes32 internal constant V3_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address internal constant V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    bytes32 internal constant V2_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
    uint24 internal constant V3_FEE = 500; // USDC/WETH 0.05% pool (deep)
    uint8 internal constant V3_SWAP_EXACT_OUT = 0x01; // Universal Router command
    uint256 internal constant FORK_BLOCK = 25_598_384;

    PoolManager internal manager;
    IMarginRouter internal router;
    CompoundV3LendingAdapter internal adapter;
    address internal universalRouter;
    Market internal market;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);

        market = Market({collateral: Currency.wrap(WETH), debt: Currency.wrap(USDC)});

        // local PoolManager as the flash-take source; seed it with USDC so ROUTE_SWAP can take
        manager = new PoolManager(address(this));
        deal(USDC, address(manager), 100_000e6);

        universalRouter = _deployUniversalRouter();

        adapter = new CompoundV3LendingAdapter(COMET, address(this));
        address impl = address(new MarginAccount());
        router = IMarginRouter(
            deployMarginRouter(
                IPoolManager(address(manager)), IAllowanceTransfer(PERMIT2), IWETH9(WETH), impl, address(this)
            )
        );
        router.setAdapterAllowed(adapter, true);
        adapter.setMarket(Currency.wrap(WETH), Currency.wrap(USDC), true);
    }

    function test_fork_routeSwap_opensLongWethViaV3() public {
        address account = router.accountOf(address(this), 0);

        // 1 WETH equity pre-funded to the account; buy 1 WETH more with borrowed USDC (~2x)
        uint256 equity = 1 ether;
        uint128 collateralToBuy = 1 ether;
        uint256 maxIn = 10_000e6; // USDC flash-take cap
        deal(WETH, account, equity);

        uint256 pmUsdcBefore = IERC20(USDC).balanceOf(address(manager));

        bytes memory unlockData = _buildOpenPlan(account, collateralToBuy, maxIn);
        router.execute(unlockData, block.timestamp + 1 hours);

        // position opened on Compound: ~2 WETH collateral, USDC borrowed, healthy
        (uint256 coll, uint256 debt) = adapter.positionOf(account, market);
        assertApproxEqAbs(coll, equity + collateralToBuy, 1, "collateral = equity + bought");
        assertGt(debt, 0, "USDC borrowed against WETH on Comet");
        assertEq(COMET.borrowBalanceOf(account), debt, "positionOf debt matches Comet");

        Ltv ltv = adapter.currentLtvWad(account, market);
        assertGt(raw(ltv), 0, "ltv positive");
        assertLt(raw(ltv), Ltv.unwrap(adapter.maxLtvWad(market)), "ltv under liquidation");

        // everything nets: the flash-take was fully returned to the local PoolManager, and no dust
        // is left on the router or the account
        assertEq(IERC20(USDC).balanceOf(address(manager)), pmUsdcBefore, "PoolManager made whole");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router holds no USDC");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router holds no WETH");
        assertEq(IERC20(WETH).balanceOf(account), 0, "account collateral fully supplied");
        console2.log("WETH collateral:", coll);
        console2.log("USDC debt:", debt);
    }

    /// @dev Builds the `execute` plan: bind the account, route the USDC->WETH swap through UR, supply
    ///      the account's full WETH, borrow the USDC the swap cost to the router, settle the flash-take,
    ///      then assert health. Supply/borrow/settle all resolve via OPEN_DELTA exactly as they would
    ///      behind a native v4 swap.
    function _buildOpenPlan(address account, uint128 collateralToBuy, uint256 maxIn)
        internal
        view
        returns (bytes memory)
    {
        // Universal Router: single V3 exact-output command, buying `collateralToBuy` WETH for <= maxIn
        // USDC, delivered to the account, input pulled from the router (payer) via Permit2.
        bytes memory commands = abi.encodePacked(V3_SWAP_EXACT_OUT);
        bytes[] memory urInputs = new bytes[](1);
        // v3 exact-output path is encoded output->input: (WETH, fee, USDC)
        bytes memory path = abi.encodePacked(WETH, V3_FEE, USDC);
        // per-hop price limit array (one entry per pool; 0 = no limit)
        uint256[] memory minHopPriceX36 = new uint256[](1);
        urInputs[0] = abi.encode(account, uint256(collateralToBuy), maxIn, path, true, minHopPriceX36);

        bytes memory actions = abi.encodePacked(
            uint8(MarginActions.SET_ACCOUNT),
            uint8(MarginActions.ROUTE_SWAP),
            uint8(MarginActions.ACCOUNT_SUPPLY_COLLATERAL),
            uint8(MarginActions.ACCOUNT_BORROW),
            uint8(Actions.SETTLE),
            uint8(MarginActions.ASSERT_HEALTH)
        );
        bytes[] memory params = new bytes[](6);
        params[0] = abi.encode(uint256(0)); // subId
        params[1] = abi.encode(universalRouter, Currency.wrap(USDC), maxIn, commands, urInputs);
        params[2] = abi.encode(adapter, market, uint256(ActionConstants.OPEN_DELTA)); // supply full WETH balance
        params[3] = abi.encode(adapter, market, uint256(ActionConstants.OPEN_DELTA), address(router)); // borrow to router
        params[4] = abi.encode(Currency.wrap(USDC), uint256(ActionConstants.OPEN_DELTA), false); // settle from router
        params[5] = abi.encode(adapter, market, toLtv(0.85e18)); // health bound
        return abi.encode(actions, params);
    }

    function _deployUniversalRouter() internal returns (address ur) {
        RouterParameters memory p;
        p.permit2 = PERMIT2;
        p.weth9 = WETH;
        p.v2Factory = V2_FACTORY;
        p.v3Factory = V3_FACTORY;
        p.pairInitCodeHash = V2_INIT_CODE_HASH;
        p.poolInitCodeHash = V3_INIT_CODE_HASH;
        p.v4PoolManager = address(manager);
        bytes memory initcode = abi.encodePacked(vm.getCode("UniversalRouter.sol:UniversalRouter"), abi.encode(p));
        assembly {
            ur := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(ur != address(0), "UR deploy failed");
    }
}
