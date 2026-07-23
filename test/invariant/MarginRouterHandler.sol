// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";

import {MarginRouter} from "../../src/MarginRouter.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {MarginActions} from "../../src/libraries/MarginActions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";
import {Plan, Planner} from "../shared/Planner.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";

/// @notice Bounded action handler for MarginRouter invariant fuzzing. Exposes one action per
///         router entry point, bounds all fuzz inputs, pre-funds accounts directly (equity=0 path
///         to avoid Permit2), and maintains ghost state tracking every deployed account.
///
/// @dev Stack-depth kept low throughout: each action is split into small helpers so the compiler
///      does not need via_ir. No local frame exceeds ~10 variables.
contract MarginRouterHandler is CommonBase, StdCheats, StdUtils {
    using Planner for Plan;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant NUM_ACTORS = 3;
    uint256 internal constant NUM_SUB_IDS = 2;

    // Generous slippage caps: the pool is deep so most swaps succeed well within these bounds.
    uint128 internal constant MAX_DEBT_CAP = 5 ether;
    uint128 internal constant MAX_COLLATERAL_CAP = 5 ether;

    // Equity range supplied to accounts directly.
    uint256 internal constant EQUITY_MIN = 0.01 ether;
    uint256 internal constant EQUITY_MAX = 1 ether;

    // collateralToBuy range kept small so the deep pool always fills.
    uint128 internal constant BUY_MIN = 0.01 ether;
    uint128 internal constant BUY_MAX = 1 ether;

    // debtToRepay range for decrease (must be less than a typical open's debt).
    uint256 internal constant REPAY_MIN = 0.005 ether;
    uint256 internal constant REPAY_MAX = 0.5 ether;

    // -------------------------------------------------------------------------
    // Immutable system under test
    // -------------------------------------------------------------------------

    MarginRouter public marginRouter;
    MockLendingAdapter public adapter;
    MockLendingProtocol public protocol;
    MockERC20 public collateralToken;
    MockERC20 public debtToken;
    PoolKey public poolKey;
    Market public market;

    // -------------------------------------------------------------------------
    // Ghost variables
    // -------------------------------------------------------------------------

    /// @notice Every (owner, subId) pair whose account has been created at least once.
    address[] public ghost_accounts;
    /// @notice Tracks whether a given account address is already in ghost_accounts.
    mapping(address account => bool known) public ghost_knownAccount;

    /// @notice Aggregate collateral supplied across all successful opens / addCollateral calls.
    uint256 public ghost_totalCollateralIn;
    /// @notice Aggregate collateral returned across all successful close calls.
    uint256 public ghost_totalCollateralOut;

    // -------------------------------------------------------------------------
    // Actor pool
    // -------------------------------------------------------------------------

    address[NUM_ACTORS] public actors;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        MarginRouter marginRouter_,
        MockLendingAdapter adapter_,
        MockLendingProtocol protocol_,
        MockERC20 collateralToken_,
        MockERC20 debtToken_,
        PoolKey memory poolKey_
    ) {
        marginRouter = marginRouter_;
        adapter = adapter_;
        protocol = protocol_;
        collateralToken = collateralToken_;
        debtToken = debtToken_;
        poolKey = poolKey_;
        market =
            Market({collateral: Currency.wrap(address(collateralToken_)), debt: Currency.wrap(address(debtToken_))});

        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");

        // Mint generous collateral to each actor so they can fund equity.
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            collateralToken.mint(actors[i], 1_000_000 ether);
        }
    }

    // -------------------------------------------------------------------------
    // Internal helpers (kept small to avoid stack-too-deep without via_ir)
    // -------------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, NUM_ACTORS - 1)];
    }

    function _subId(uint256 seed) internal pure returns (uint256) {
        return bound(seed, 0, NUM_SUB_IDS - 1);
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    /// @dev Records the predicted account address as a ghost if not already tracked.
    function _trackAccount(address owner, uint256 subId) internal {
        address acc = marginRouter.accountOf(owner, subId);
        if (!ghost_knownAccount[acc]) {
            ghost_knownAccount[acc] = true;
            ghost_accounts.push(acc);
        }
    }

    /// @dev Transfers `amount` of collateral from `actor` to their predicted account address,
    ///      then opens / increases with equity=0 (no Permit2 needed).
    function _fundAccount(address actor, uint256 subId, uint256 amount) internal {
        address acc = marginRouter.accountOf(actor, subId);
        vm.prank(actor);
        collateralToken.transfer(acc, amount);
    }

    // -------------------------------------------------------------------------
    // Handler actions
    // -------------------------------------------------------------------------

    /// @notice Open a long position: fund equity, call increasePosition with equity=0.
    function openLong(uint256 actorSeed, uint256 subIdSeed, uint256 equitySeed, uint256 buySeed) external {
        address actor = _actor(actorSeed);
        uint256 subId = _subId(subIdSeed);
        uint256 equity = bound(equitySeed, EQUITY_MIN, EQUITY_MAX);
        uint128 buy = uint128(bound(buySeed, uint256(BUY_MIN), uint256(BUY_MAX)));

        _trackAccount(actor, subId);
        _fundAccount(actor, subId, equity);

        IMarginRouter.IncreaseParams memory params = _buildIncreaseParams(buy, subId);

        vm.prank(actor);
        try marginRouter.increasePosition(params) {
            ghost_totalCollateralIn += equity;
        } catch {}
    }

    /// @notice Add leverage to an existing long via a second open into the same account.
    function increaseLong(uint256 actorSeed, uint256 subIdSeed, uint256 equitySeed, uint256 buySeed) external {
        address actor = _actor(actorSeed);
        uint256 subId = _subId(subIdSeed);
        uint256 equity = bound(equitySeed, EQUITY_MIN, EQUITY_MAX);
        uint128 buy = uint128(bound(buySeed, uint256(BUY_MIN), uint256(BUY_MAX)));

        _trackAccount(actor, subId);
        _fundAccount(actor, subId, equity);

        IMarginRouter.IncreaseParams memory params = _buildIncreaseParams(buy, subId);

        vm.prank(actor);
        try marginRouter.increasePosition(params) {
            ghost_totalCollateralIn += equity;
        } catch {}
    }

    /// @notice Close a position, returning residual collateral to the actor.
    function closeLong(uint256 actorSeed, uint256 subIdSeed) external {
        address actor = _actor(actorSeed);
        uint256 subId = _subId(subIdSeed);

        _trackAccount(actor, subId);

        IMarginRouter.DecreaseParams memory params = _buildCloseParams(subId);

        uint256 before = collateralToken.balanceOf(actor);
        vm.prank(actor);
        try marginRouter.decreasePosition(params) {
            uint256 returned = collateralToken.balanceOf(actor) - before;
            ghost_totalCollateralOut += returned;
        } catch {}
    }

    /// @notice Partially delever a position by repaying a bounded amount of debt.
    function decreaseLong(uint256 actorSeed, uint256 subIdSeed, uint256 repaySeed) external {
        address actor = _actor(actorSeed);
        uint256 subId = _subId(subIdSeed);
        uint256 repay = bound(repaySeed, REPAY_MIN, REPAY_MAX);

        _trackAccount(actor, subId);

        IMarginRouter.DecreaseParams memory params = _buildDecreaseParams(repay, subId);

        vm.prank(actor);
        try marginRouter.decreasePosition(params) {} catch {}
    }

    /// @notice Open a long through the generalized `execute` entrypoint instead of the curated
    ///         increasePosition, so the invariants also hold across arbitrary-plan opens.
    function executeOpenLong(uint256 actorSeed, uint256 subIdSeed, uint256 equitySeed, uint256 buySeed) external {
        address actor = _actor(actorSeed);
        uint256 subId = _subId(subIdSeed);
        uint256 equity = bound(equitySeed, EQUITY_MIN, EQUITY_MAX);
        uint128 buy = uint128(bound(buySeed, uint256(BUY_MIN), uint256(BUY_MAX)));

        _trackAccount(actor, subId);
        _fundAccount(actor, subId, equity);

        bytes memory data = _executeOpenPlan(actor, subId, buy);

        vm.prank(actor);
        try marginRouter.execute(data, _deadline()) {
            ghost_totalCollateralIn += equity;
        } catch {}
    }

    /// @notice Fully close a position through `execute` (swap-buy the debt, repay all, withdraw all,
    ///         settle, and SWEEP the realized residual to the actor).
    function executeCloseLong(uint256 actorSeed, uint256 subIdSeed) external {
        address actor = _actor(actorSeed);
        uint256 subId = _subId(subIdSeed);
        _trackAccount(actor, subId);

        address account = marginRouter.accountOf(actor, subId);
        uint256 debtOwed = protocol.debtOf(account);
        uint256 collateralHeld = protocol.collateralOf(account);
        // the swap-close path needs a non-zero debt to buy and collateral to withdraw
        if (debtOwed == 0 || collateralHeld == 0) return;

        bytes memory data = _executeClosePlan(account, subId, debtOwed, collateralHeld);

        uint256 before = collateralToken.balanceOf(actor);
        vm.prank(actor);
        try marginRouter.execute(data, _deadline()) {
            ghost_totalCollateralOut += collateralToken.balanceOf(actor) - before;
        } catch {}
    }

    /// @notice Fund an account directly, then supply that loose balance via an `execute` plan
    ///         (SET_ACCOUNT + SUPPLY with OPEN_DELTA). Exercises the account-scoped supply path and
    ///         its allowlist guard without a swap or Permit2.
    function executePullSupply(uint256 actorSeed, uint256 subIdSeed, uint256 equitySeed) external {
        address actor = _actor(actorSeed);
        uint256 subId = _subId(subIdSeed);
        uint256 equity = bound(equitySeed, EQUITY_MIN, EQUITY_MAX);

        _trackAccount(actor, subId);
        _fundAccount(actor, subId, equity);

        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(subId));
        plan =
            plan.add(MarginActions.ACCOUNT_SUPPLY_COLLATERAL, abi.encode(adapter, market, ActionConstants.OPEN_DELTA));

        vm.prank(actor);
        try marginRouter.execute(plan.encode(), _deadline()) {
            ghost_totalCollateralIn += equity;
        } catch {}
    }

    // -------------------------------------------------------------------------
    // Execute plan builders (kept in their own helpers to bound frame locals)
    // -------------------------------------------------------------------------

    function _executeOpenPlan(address actor, uint256 subId, uint128 buy) internal view returns (bytes memory) {
        Market memory m = market;
        address account = marginRouter.accountOf(actor, subId);
        bool zeroForOne = m.toSwapParams(m.debt, 0, 0, poolKey).zeroForOne;

        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(subId));
        plan = plan.add(
            Actions.SWAP_EXACT_OUT_SINGLE,
            abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: zeroForOne,
                    amountOut: buy,
                    amountInMaximum: MAX_DEBT_CAP,
                    minHopPriceX36: 0,
                    hookData: ""
                })
            )
        );
        plan = plan.add(MarginActions.ASSERT_FILL, abi.encode(m.collateral, uint256(buy)));
        plan = plan.add(Actions.TAKE, abi.encode(m.collateral, account, ActionConstants.OPEN_DELTA));
        plan = plan.add(MarginActions.ACCOUNT_SUPPLY_COLLATERAL, abi.encode(adapter, m, ActionConstants.OPEN_DELTA));
        plan = plan.add(
            MarginActions.ACCOUNT_BORROW, abi.encode(adapter, m, ActionConstants.OPEN_DELTA, address(marginRouter))
        );
        plan = plan.add(Actions.SETTLE, abi.encode(m.debt, ActionConstants.OPEN_DELTA, false));
        return plan.encode();
    }

    function _executeClosePlan(address account, uint256 subId, uint256 debtOwed, uint256 collateralHeld)
        internal
        view
        returns (bytes memory)
    {
        Market memory m = market;
        bool zeroForOne = m.toSwapParams(m.collateral, 0, 0, poolKey).zeroForOne;

        Plan memory plan = Planner.init();
        plan = plan.add(MarginActions.SET_ACCOUNT, abi.encode(subId));
        plan = plan.add(
            Actions.SWAP_EXACT_OUT_SINGLE,
            abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: zeroForOne,
                    amountOut: uint128(debtOwed),
                    amountInMaximum: MAX_COLLATERAL_CAP,
                    minHopPriceX36: 0,
                    hookData: ""
                })
            )
        );
        plan = plan.add(Actions.TAKE, abi.encode(m.debt, account, ActionConstants.OPEN_DELTA));
        plan = plan.add(MarginActions.ACCOUNT_REPAY, abi.encode(adapter, m, type(uint256).max));
        plan = plan.add(
            MarginActions.ACCOUNT_WITHDRAW_COLLATERAL, abi.encode(adapter, m, collateralHeld, address(marginRouter))
        );
        plan = plan.add(Actions.SETTLE, abi.encode(m.collateral, ActionConstants.OPEN_DELTA, false));
        plan = plan.add(Actions.SWEEP, abi.encode(m.collateral, ActionConstants.MSG_SENDER));
        return plan.encode();
    }

    // -------------------------------------------------------------------------
    // Param builders (split into helpers to reduce locals per frame)
    // -------------------------------------------------------------------------

    function _buildIncreaseParams(uint128 buy, uint256 subId)
        internal
        view
        returns (IMarginRouter.IncreaseParams memory)
    {
        return IMarginRouter.IncreaseParams({
            adapter: adapter,
            market: market,
            poolKey: poolKey,
            equity: 0,
            collateralToBuy: buy,
            maxDebtIn: MAX_DEBT_CAP,
            minHopPriceX36: 0,
            maxLtvAfter: Ltv.wrap(0),
            subId: subId,
            deadline: _deadline()
        });
    }

    function _buildCloseParams(uint256 subId) internal view returns (IMarginRouter.DecreaseParams memory) {
        return IMarginRouter.DecreaseParams({
            debtToRepay: type(uint256).max,
            maxLtvAfter: Ltv.wrap(0),
            adapter: adapter,
            market: market,
            poolKey: poolKey,
            maxCollateralIn: MAX_COLLATERAL_CAP,
            minHopPriceX36: 0,
            subId: subId,
            deadline: _deadline()
        });
    }

    function _buildDecreaseParams(uint256 repay, uint256 subId)
        internal
        view
        returns (IMarginRouter.DecreaseParams memory)
    {
        return IMarginRouter.DecreaseParams({
            adapter: adapter,
            market: market,
            poolKey: poolKey,
            debtToRepay: repay,
            maxCollateralIn: MAX_COLLATERAL_CAP,
            minHopPriceX36: 0,
            maxLtvAfter: toLtv(0.95e18),
            subId: subId,
            deadline: _deadline()
        });
    }

    // -------------------------------------------------------------------------
    // Ghost state accessors for the invariant contract
    // -------------------------------------------------------------------------

    function ghostAccountsLength() external view returns (uint256) {
        return ghost_accounts.length;
    }
}
