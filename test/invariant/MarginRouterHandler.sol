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
import {Market} from "../../src/types/Market.sol";
import {Ltv, toLtv} from "../../src/types/Ltv.sol";
import {MockLendingAdapter} from "../mocks/MockLendingAdapter.sol";
import {MockLendingProtocol} from "../mocks/MockLendingProtocol.sol";

/// @notice Bounded action handler for MarginRouter invariant fuzzing. Exposes one action per
///         router entry point, bounds all fuzz inputs, pre-funds accounts directly (equity=0 path
///         to avoid Permit2), and maintains ghost state tracking every deployed account.
///
/// @dev Stack-depth kept low throughout: each action is split into small helpers so the compiler
///      does not need via_ir. No local frame exceeds ~10 variables.
contract MarginRouterHandler is CommonBase, StdCheats, StdUtils {
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

    /// @notice Open a long position: fund equity, call openPosition with equity=0.
    function openLong(uint256 actorSeed, uint256 subIdSeed, uint256 equitySeed, uint256 buySeed) external {
        address actor = _actor(actorSeed);
        uint256 subId = _subId(subIdSeed);
        uint256 equity = bound(equitySeed, EQUITY_MIN, EQUITY_MAX);
        uint128 buy = uint128(bound(buySeed, uint256(BUY_MIN), uint256(BUY_MAX)));

        _trackAccount(actor, subId);
        _fundAccount(actor, subId, equity);

        IMarginRouter.OpenParams memory params = _buildOpenParams(buy, subId);

        vm.prank(actor);
        try marginRouter.openPosition(params) {
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

        IMarginRouter.OpenParams memory params = _buildOpenParams(buy, subId);

        vm.prank(actor);
        try marginRouter.openPosition(params) {
            ghost_totalCollateralIn += equity;
        } catch {}
    }

    /// @notice Close a position, returning residual collateral to the actor.
    function closeLong(uint256 actorSeed, uint256 subIdSeed) external {
        address actor = _actor(actorSeed);
        uint256 subId = _subId(subIdSeed);

        _trackAccount(actor, subId);

        IMarginRouter.CloseParams memory params = _buildCloseParams(subId);

        uint256 before = collateralToken.balanceOf(actor);
        vm.prank(actor);
        try marginRouter.closePosition(params) {
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

    // -------------------------------------------------------------------------
    // Param builders (split into helpers to reduce locals per frame)
    // -------------------------------------------------------------------------

    function _buildOpenParams(uint128 buy, uint256 subId) internal view returns (IMarginRouter.OpenParams memory) {
        return IMarginRouter.OpenParams({
            adapter: adapter,
            market: market,
            poolKey: poolKey,
            equity: 0,
            collateralToBuy: buy,
            maxDebtIn: MAX_DEBT_CAP,
            minHopPriceX36: 0,
            subId: subId,
            deadline: _deadline()
        });
    }

    function _buildCloseParams(uint256 subId) internal view returns (IMarginRouter.CloseParams memory) {
        return IMarginRouter.CloseParams({
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
