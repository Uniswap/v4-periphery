// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC721} from "solmate/src/tokens/ERC721.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Actions} from "./libraries/Actions.sol";
import {ActionConstants} from "./libraries/ActionConstants.sol";
import {PositionInfo, PositionInfoLibrary} from "./libraries/PositionInfoLibrary.sol";
import {Multicall_v4} from "./base/Multicall_v4.sol";
import {SafeCallback} from "./base/SafeCallback.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {Permit2Forwarder} from "./base/Permit2Forwarder.sol";
import {ReentrancyLock} from "./base/ReentrancyLock.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {ISwapAndAdd} from "./interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "./interfaces/external/IUniversalRouter.sol";

/// @title SwapAndAdd
/// @notice See ISwapAndAdd. Route-first swap-and-add / rebalance zap for Uniswap v4.
///
///         Flow, all inside one PoolManager unlock:
///           1. ROUTE FIRST — run the caller's verbatim Universal Router route to swap the surplus side toward
///              the deficit side (best execution, typically off-venue). The post-route state — balances and
///              pool price — is the source of truth for everything after.
///           2. SIZE & DEPLOY — size the position from those real holdings at the live price, fee-aware (the
///              residual same-pool swap will pay the pool fee, so discount the side it consumes), and mint to
///              this contract (or increase the existing tokenId in place).
///           3. RECONCILE — a single same-pool swap funds whichever side the deploy is short of (either
///              direction), then a DECREASE ("trim") lands the position exactly on what the holdings support.
///           4. FLOOR — revert unless the final liquidity >= `minLiquidity` (the one slippage knob).
///           5. SWEEP leftover to the recipient and transfer the position NFT to them after the unlock closes.
///
///         Why route *before* mint:
///           The same-pool reconcile swap moves the pool price. If we sized/minted *after* it, the position's
///           required ratio would depend on the swap we are still computing — a circular dependency.
///           Minting *first* fixes the position's composition at the live price, so the
///           reconcile swap can move the price freely without invalidating the mint. The *route* is a black
///           box that simply runs first — whatever state it leaves (balances and pool price alike, it may even
///           touch this pool) is re-read and used as the source of truth for sizing. `minLiquidity` checked on
///           the final position is the single slippage gate for the whole operation.
///
///         INVARIANT — no funds at rest for well-formed operations: an operation pulls the caller's budget,
///         deploys/settles it in full and sweeps the remainder — pool tokens and every declared routeFunding
///         token — within the same transaction. What CAN rest here is only value nobody declared: direct
///         donations, or tokens/native a route delivered that the operation did not list. Such balances are
///         not lost — they are treated as part of the next caller's budget (pool tokens) or claimable via a
///         zero-amount routeFunding entry — and, decisively for safety, they are never reachable by a third
///         party THROUGH this contract's allowances: the standing max Permit2 allowances to POSM and the
///         Universal Router (see `_ensureApproved`) only ever let those spenders pull from their direct
///         caller, i.e. only when this contract itself invokes them mid-operation, under the reentrancy lock,
///         with `minLiquidity` bounding the outcome for the caller whose budget the balance then is.
///
///         v4-only; ERC-20 + native ETH. Four ops: add + rebalance mint a NEW position (to this contract so it
///         can be trimmed, transferred to the recipient after the unlock closes); increase + compound grow an
///         EXISTING tokenId in place through the same core.
contract SwapAndAdd is ISwapAndAdd, SafeCallback, DeltaResolver, Permit2Forwarder, Multicall_v4, ReentrancyLock {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    using SafeCast for uint256;

    /// @dev Allowances to POSM and the Universal Router should never expire.
    uint48 private constant ALLOWANCE_EXPIRATION = type(uint48).max;
    /// @dev v4 fees are expressed in pips (millionths).
    uint256 private constant PIPS_DENOMINATOR = 1e6;
    /// @dev Reference liquidity the sizing math scales from; max so the reference amounts stay far above their
    ///      wei rounding even for narrow ranges at extreme ticks (see `_sizeLiquidityWeighted`).
    uint128 private constant REFERENCE_LIQUIDITY = type(uint128).max;
    /// @dev universal-router Commands.SWEEP — used to reclaim native value a route left in the UR.
    uint256 private constant UR_SWEEP_COMMAND = 0x04;

    /// @dev Internal operation commands to identify the operation type in the unlock callback. Compound has
    ///      no op of its own: it is an increase with a zero pulled budget and shares OP_INCREASE.
    uint256 private constant OP_ADD = 0;
    uint256 private constant OP_REBALANCE = 1;
    uint256 private constant OP_INCREASE = 2;

    /// @dev internal, stack-friendly bundle of the shared add inputs (budget already held by this contract).
    struct CoreParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 budget0;
        uint256 budget1;
        bytes route;
        uint256 minLiquidity;
        address recipient;
        bytes hookData;
    }

    IPositionManager public immutable positionManager;
    IUniversalRouter public immutable universalRouter;

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        _;
    }

    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        IPositionManager _positionManager,
        IUniversalRouter _universalRouter
    ) SafeCallback(_poolManager) Permit2Forwarder(_permit2) {
        positionManager = _positionManager;
        universalRouter = _universalRouter;
    }

    /// @dev Native only ever arrives from the PoolManager (take), POSM (mint/increase SWEEP return) or the UR
    ///      (route output / reclaimed value). Rejecting everything else keeps stray transfers from being swept
    ///      to the next caller.
    receive() external payable {
        if (
            msg.sender != address(poolManager) && msg.sender != address(positionManager)
                && msg.sender != address(universalRouter)
        ) revert InvalidEthSender();
    }

    // ───────────────────────────────────────────── external entrypoints ─────────────────────────────────────────────

    /// @inheritdoc ISwapAndAdd
    function add(AddParams calldata params)
        external
        payable
        isNotLocked
        checkDeadline(params.deadline)
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        _validateRecipient(params.recipient);
        uint256 fundingValue = _pullFunding(params.poolKey, params.routeFunding, params.route);
        _pullBudget(params.poolKey, params.amount0In, params.amount1In, fundingValue);
        // unlock the pool manager and trigger the callback with the ADD operation.
        bytes memory result = poolManager.unlock(abi.encode(OP_ADD, abi.encode(params)));
        // decode the result of the callback.
        (tokenId, liquidity, amount0, amount1) = abi.decode(result, (uint256, uint128, uint256, uint256));
        // the position was minted to this contract so it could be trimmed; hand it to the recipient now that
        // the pool is locked again, along with any funding the route did not consume.
        ERC721(address(positionManager)).transferFrom(address(this), params.recipient, tokenId);
        _sweepFunding(params.routeFunding, params.recipient);
    }

    /// @inheritdoc ISwapAndAdd
    function rebalance(RebalanceParams calldata params)
        external
        payable
        isNotLocked
        checkDeadline(params.deadline)
        returns (uint256 newTokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(params.tokenId);
        // ensure caller is owner or an approved operator. Only the position owner can set a new recipient.
        address recipient = _authAndResolveRecipient(params.tokenId, params.recipient);
        _validateRecipient(recipient);
        // pull funds from msg.sender (same as add()'s _pullBudget), if additional0/1 is positive. If its
        // negative, funds will be returned during the unlock once we know the withdrawn amounts.
        uint256 fundingValue = _pullFunding(key, params.routeFunding, params.route);
        _pullAdditional(key, params.additional0, params.additional1, fundingValue);

        // unlock the pool manager and trigger the callback with the REBALANCE operation.
        bytes memory result = poolManager.unlock(abi.encode(OP_REBALANCE, abi.encode(params, key, recipient)));
        // decode the result of the callback.
        (newTokenId, liquidity, amount0, amount1) = abi.decode(result, (uint256, uint128, uint256, uint256));
        // transfer the newly created position NFT to the recipient, along with any unconsumed funding.
        ERC721(address(positionManager)).transferFrom(address(this), recipient, newTokenId);
        _sweepFunding(params.routeFunding, recipient);
    }

    /// @inheritdoc ISwapAndAdd
    function increase(IncreaseParams calldata params)
        external
        payable
        isNotLocked
        checkDeadline(params.deadline)
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1)
    {
        // the position's accrued fees are collected into the budget (see the callback), so an increase spends
        // position value: only the owner or an approved operator may call, and only the owner picks the recipient.
        address recipient = _authAndResolveRecipient(params.tokenId, params.recipient);
        _validateRecipient(recipient);
        (PoolKey memory key, bytes memory payload) =
            _growPayload(params.tokenId, params.route, params.minLiquidityAdded, recipient, params.hookData);
        // pull the caller's stated budget from msg.sender (same as add()'s _pullBudget); the collected fees
        // join it inside the callback.
        uint256 fundingValue = _pullFunding(key, params.routeFunding, params.route);
        _pullBudget(key, params.amount0In, params.amount1In, fundingValue);
        bytes memory result = poolManager.unlock(abi.encode(OP_INCREASE, payload));
        // decode the result of the callback.
        (liquidityAdded, amount0, amount1) = abi.decode(result, (uint128, uint256, uint256));
        // positionNFT stays with the original owner, so no transfer is needed; unconsumed funding goes to the
        // RESOLVED recipient (an operator's leftovers are forced to the owner — a route can also produce a
        // funding token from the collected fees, so funding leftovers are output like any other).
        _sweepFunding(params.routeFunding, recipient);
    }

    /// @inheritdoc ISwapAndAdd
    function compound(CompoundParams calldata params)
        external
        isNotLocked
        checkDeadline(params.deadline)
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1)
    {
        // fees of the pool are used as funds for the compound operation, so only a valid owner or operator can compound,
        // ensuring a trusted route and liquidity threshold is used. Dust is forced to the owner if caller is an operator.
        address recipient = _authAndResolveRecipient(params.tokenId, params.recipient);
        _validateRecipient(recipient);
        // compound is an increase with a zero pulled budget: nothing is pulled here, the collected fees are
        // the entire budget — both ops share the OP_INCREASE callback path.
        (, bytes memory payload) =
            _growPayload(params.tokenId, params.route, params.minLiquidityAdded, recipient, params.hookData);
        bytes memory result = poolManager.unlock(abi.encode(OP_INCREASE, payload));
        // decode the result of the callback.
        (liquidityAdded, amount0, amount1) = abi.decode(result, (uint128, uint256, uint256));
    }

    /// @dev Shared unlock payload for the grow-in-place ops (increase, compound): deploy into the position's
    ///      existing range. Budgets are left zero — the callback fills them from the balances actually held
    ///      once the accrued fees have been collected.
    function _growPayload(
        uint256 tokenId,
        bytes calldata route,
        uint256 minLiquidity,
        address recipient,
        bytes calldata hookData
    ) internal view returns (PoolKey memory key, bytes memory payload) {
        PositionInfo info;
        (key, info) = positionManager.getPoolAndPositionInfo(tokenId);
        CoreParams memory cp = CoreParams({
            key: key,
            tickLower: info.tickLower(),
            tickUpper: info.tickUpper(),
            budget0: 0,
            budget1: 0,
            route: route,
            minLiquidity: minLiquidity,
            recipient: recipient,
            hookData: hookData
        });
        payload = abi.encode(tokenId, cp);
    }

    // ───────────────────────────────────────────── unlock callback ─────────────────────────────────────────────

    /// @notice Callback function triggered by the pool manager and handles the different operations.
    /// @dev Protected by SafeCallback.onlyPoolManager modifier.
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (uint256 op, bytes memory inner) = abi.decode(data, (uint256, bytes));
        // handle the grow-in-place operations: increase and compound share this path (compound = zero
        // pulled budget, so the collected fees are its whole budget).
        if (op == OP_INCREASE) {
            (uint256 growId, CoreParams memory growCp) = abi.decode(inner, (uint256, CoreParams));
            // collect accrued fees FIRST (DECREASE by 0 credits them, TAKE_PAIR pulls them here): they join
            // the pulled budget below, so fees are route- and sizing-eligible and never leave to the wallet.
            _decrease(growCp.key, growId, 0, growCp.hookData);
            // budget = everything held: the caller's pulled amounts plus the just-collected fees.
            growCp.budget0 = growCp.key.currency0.balanceOfSelf();
            growCp.budget1 = growCp.key.currency1.balanceOfSelf();
            // a route can still produce a budget (e.g. from route funding); with neither holdings nor a route
            // there is provably nothing to deploy.
            if (growCp.budget0 == 0 && growCp.budget1 == 0 && growCp.route.length == 0) revert NoFeesToCompound();
            // existing tokenId -> _addCore INCREASEs it in place (no new NFT).
            (, uint128 liqAdded, uint256 added0, uint256 added1) = _addCore(growCp, growId);
            return abi.encode(liqAdded, added0, added1);
        }

        // Only reached by ADD or REBALANCE operations.
        CoreParams memory cp;
        // prepare the ADD operation.
        if (op == OP_ADD) {
            AddParams memory p = abi.decode(inner, (AddParams));
            cp = CoreParams({
                key: p.poolKey,
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                budget0: p.amount0In,
                budget1: p.amount1In,
                route: p.route,
                minLiquidity: p.minLiquidity,
                recipient: p.recipient,
                hookData: p.hookData
            });
        } else {
            // prepare the REBALANCE operation by burning the position and resolving the budget.
            (RebalanceParams memory p, PoolKey memory key, address recipient) =
                abi.decode(inner, (RebalanceParams, PoolKey, address));
            cp = _prepareRebalance(p, key, recipient);
        }
        // tokenId 0 -> _addCore MINTs a new position. Both ADD and REBALANCE create a new position.
        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = _addCore(cp, 0);
        return abi.encode(tokenId, liq, a0, a1);
    }

    /// @dev Rebalance prep: burn the WHOLE position, then resolve each token's redeploy budget from the signed
    ///      delta — `withdrawn + additional`. Positive deltas were already pulled in `rebalance()` (so they sit in
    ///      this contract's balance); negative deltas are returned to the recipient HERE, before the add flow runs.
    ///      Returning the cash-out share up front is what keeps the accounting safe: the contract is then left
    ///      holding exactly the redeploy budget, so every `balanceOfSelf()` read in `_addCore` (the route, the
    ///      reconcile's sell-all, the mint settle) sees only what should be deployed, never the portion owed back.
    /// @dev reverts with `ReturnExceedsWithdrawn` if the negative delta exceeds the positions balance.
    function _prepareRebalance(RebalanceParams memory p, PoolKey memory key, address recipient)
        internal
        returns (CoreParams memory cp)
    {
        // burn the full position. Tokens land in this contract.
        _withdraw(key, p.tokenId, p.hookData);

        // Create the CoreParams with the remaining budget of the withdrawal after _resolveBudget.
        cp = CoreParams({
            key: key,
            tickLower: p.newTickLower,
            tickUpper: p.newTickUpper,
            budget0: _resolveBudget(key.currency0, p.additional0, recipient),
            budget1: _resolveBudget(key.currency1, p.additional1, recipient),
            route: p.route,
            minLiquidity: p.minLiquidity,
            recipient: recipient,
            hookData: p.hookData
        });
    }

    /// @dev Resolve one token's redeploy budget from its signed delta. With a positive delta the additional units
    ///      were already pulled into this contract by `rebalance()`, so the held balance already equals
    ///      `withdrawn + additional` and is returned as-is. With a negative delta we return `|delta|` to the
    ///      recipient now (clamped: it may not exceed the withdrawn balance) and redeploy the remainder.
    function _resolveBudget(Currency currency, int128 delta, address recipient) internal returns (uint256 budget) {
        uint256 held = currency.balanceOfSelf();
        if (delta >= 0) return held; // withdrawn + (pre-pulled) additional tokens
        // widen before negating: -int128 would overflow on type(int128).min
        uint256 toReturn = uint256(-int256(delta));
        // Check if the amount to return exceeds the held balance.
        if (toReturn > held) revert ReturnExceedsWithdrawn(toReturn, held);
        // Return the requested amount of tokens to the recipient.
        currency.transfer(recipient, toReturn);
        // Return the remaining budget.
        return held - toReturn;
    }

    // ───────────────────────────────────────────── core flow ─────────────────────────────────────────────

    /// @dev Shared route-first core for add / rebalance / increase / compound. With `existingTokenId == 0` it
    ///      MINTs a new position (to this contract, so it can be trimmed); otherwise it INCREASEs that tokenId in
    ///      place (no new NFT). Route -> size (fee-aware) -> flash-take deficit -> mint|increase -> reconcile +
    ///      trim -> floor -> sweep dust to recipient.
    function _addCore(CoreParams memory cp, uint256 existingTokenId)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // ensure the contract has standing allowances for permit2 and UR / PositionManager via Permit2.
        _ensureApproved(cp.key.currency0);
        _ensureApproved(cp.key.currency1);

        // 1. ROUTE FIRST: run the verbatim route (a black box) to convert the surplus toward the deficit, then
        //    re-read balances — the post-route state is the source of truth we size from, not an estimate.
        if (cp.route.length != 0) {
            _runRoute(cp);
            // update the budget after the route has run.
            cp.budget0 = cp.key.currency0.balanceOfSelf();
            cp.budget1 = cp.key.currency1.balanceOfSelf();
        }

        // 2. size from the holdings (fee-aware, optimistic), flash-take whatever side is short, then mint a new
        //    position or increase the existing one.
        (uint128 liquidityOptimistic, uint256 amount0optimistic, uint256 amount1optimistic) = _planLiquidity(cp);
        // a zero-sized MINT can never produce a position (v4 rejects empty-position updates outright), so no
        // outcome could ever satisfy the caller: surface the contract's own floor error instead of the pool's
        // opaque CannotUpdateEmptyPosition. Grow-in-place ops keep their semantics (adding 0 to an existing
        // position is valid; the minLiquidityAdded floor is the gate).
        if (liquidityOptimistic == 0 && existingTokenId == 0) {
            revert InsufficientLiquidity(uint128(cp.minLiquidity), 0);
        }
        _flashTakeDeficit(cp, amount0optimistic, amount1optimistic);
        tokenId = _deploy(cp, existingTokenId, liquidityOptimistic, amount0optimistic);

        // 3. same-pool swap to reconcile whichever side is short (if any), then trim the optimistic
        //    size down to what the holdings actually funded.
        uint128 trimmed = _reconcile(cp, tokenId, liquidityOptimistic, amount0optimistic, amount1optimistic);
        liquidity = liquidityOptimistic - trimmed;

        // 4. slippage floor — the single gate for the whole operation.
        if (liquidity < cp.minLiquidity) revert InsufficientLiquidity(uint128(cp.minLiquidity), liquidity);

        // 5. report the position's composition; sweep all remaining balances to the recipient (no-funds-at-rest).
        // dust can sit in BOTH tokens (the trim frees both sides); it is not re-denominated.
        (amount0, amount1) = _positionAmounts(cp, liquidity);
        _sweep(cp.key.currency0, cp.recipient);
        _sweep(cp.key.currency1, cp.recipient);
    }

    /// @dev Size the position from the current holdings at the live price. Sizing is fee-aware: the side that
    ///      will be swapped same-pool in `_reconcile` is discounted by that direction's total swap fee, so the
    ///      optimistic deploy isn't over-sized by a fee the trim would otherwise claw back.
    function _planLiquidity(CoreParams memory cp)
        internal
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(cp.key.toId());
        // the sizing math divides by the price; only initialized pools guarantee sp >= MIN_SQRT_PRICE.
        if (sqrtPriceX96 == 0) revert IPoolManager.PoolNotInitialized();
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cp.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cp.tickUpper);
        liquidity = _sizeFeeAware(sqrtPriceX96, sqrtLower, sqrtUpper, cp.budget0, cp.budget1, protocolFee, lpFee);
        (amount0, amount1) = _getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
    }

    /// @dev Flash-`take` from the pool whatever the optimistic deploy needs beyond the held budget, on each side,
    ///      so the subsequent mint/increase is fully funded; `_reconcile` later settles what the take actually owes.
    ///      EXACT to the wei — no rounding buffer: `_getAmountsForLiquidity` rounds up with the pool's own math
    ///      on the pool's own inputs, so the deploy can never pull more than `amount0/1` (the tick/price boundary
    ///      states, the one place the formulas could diverge, are pinned by tests). Requires the PoolManager to
    ///      hold the taken amount across ALL pools; if it is globally drained of that token the take reverts
    ///      inside the token transfer — the same state leaves the reconcile swap nothing to source the deficit
    ///      from, so the operation is unviable regardless and no pre-check is spent on it (the deficit token is
    ///      usually a cold SLOAD, i.e. real gas on every call to buy a prettier error in an already-doomed state).
    function _flashTakeDeficit(CoreParams memory cp, uint256 amount0, uint256 amount1) internal {
        if (amount0 > cp.budget0) _take(cp.key.currency0, address(this), amount0 - cp.budget0);
        if (amount1 > cp.budget1) _take(cp.key.currency1, address(this), amount1 - cp.budget1);
    }

    /// @dev Settle the position's funding using a single same-pool swap in whichever direction is short, then
    ///      trim the just-added liquidity by any remaining shortfall. The route already ran (in `_runRoute`),
    ///      so this is same-pool only. Bidirectional: if the route under-converted we still hold surplus and
    ///      swap surplus->deficit; if it over-converted we are short the other side and swap the other way.
    ///      Returns the liquidity removed by the trim (0 if the holdings already covered the optimistic deploy).
    function _reconcile(CoreParams memory cp, uint256 tokenId, uint128 lopt, uint256 a0opt, uint256 a1opt)
        internal
        returns (uint128 trimmed)
    {
        bool deficitIs1;
        if (a0opt > cp.budget0) deficitIs1 = false; // short token0 -> token0 is the deficit
        else if (a1opt > cp.budget1) deficitIs1 = true; // short token1 -> token1 is the deficit
        else return 0; // holdings already in-ratio: no swap, no trim.

        Currency deficit = deficitIs1 ? cp.key.currency1 : cp.key.currency0;
        Currency surplus = deficitIs1 ? cp.key.currency0 : cp.key.currency1;
        bool zeroForOne = deficitIs1; // sell surplus(token0) -> deficit(token1) when token1 is the deficit

        // 1. settle the deficit owed (from the flash-take) with whatever deficit tokens we already hold.
        _settleToward(deficit);

        // 2. convert ALL remaining surplus to deficit (exact-input) — never overshoot, so nothing is bought
        //    just to be handed back by the trim. Settle the surplus the swap consumed.
        uint256 surplusBal = surplus.balanceOfSelf();
        if (surplusBal > 0) {
            _swap(cp.key, zeroForOne, -surplusBal.toInt256(), cp.hookData);
            _settleToward(surplus);
        }

        // 3. whatever deficit is still owed (the genuine residual) -> free it by trimming the position. The
        //    DECREASE frees BOTH tokens when the price is in range, so it also tops the surplus side back up.
        int256 owed = poolManager.currencyDelta(address(this), deficit);
        if (owed < 0) {
            trimmed = _trim(cp, tokenId, lopt, deficitIs1, uint256(-owed));
            _settleToward(deficit);
        }

        // 4. square up: take any leftover credit on either side into the balance and settle any remaining
        //    surplus debt. Leftovers are NOT re-denominated — the sweep returns them in whatever pool tokens
        //    they are (the trim frees BOTH sides, so two-token dust is the normal case; converting one into
        //    the other would pay the pool fee on cosmetics).
        _takeCredit(deficit);
        _takeCredit(surplus);
        _settleToward(surplus);
    }

    /// @dev DECREASE the position by enough liquidity to free at least `amountOut` of the deficit token,
    ///      capped at `lopt` — the liquidity this flow just added. On increase/compound the position also
    ///      holds the owner's pre-existing principal, which the trim must never consume.
    ///      The token->liquidity inverse ROUNDS UP on every division, over `amountOut + 1`, so the DECREASE's
    ///      rounded-DOWN return always covers `amountOut`: the token0 inverse floors an intermediate value
    ///      whose truncation is scaled by the amount, so its error in liquidity units is unbounded — a
    ///      "+1 liquidity unit" style compensation cannot bound a shortfall measured in token wei.
    ///      The cap is reachable only when the deficit exceeds what unwinding ALL of `lopt` returns, i.e. the
    ///      budget is within the pool's ~1-wei mint/burn rounding toll: the trim then removes all of `lopt`,
    ///      the added liquidity is 0 and any non-zero `minLiquidity` floor reverts InsufficientLiquidity (a zero
    ///      floor lets the unsettled toll surface as v4's CurrencyNotSettled at the end of the unlock).
    function _trim(CoreParams memory cp, uint256 tokenId, uint128 lopt, bool deficitIs1, uint256 amountOut)
        internal
        returns (uint128 dl)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(cp.key.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cp.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cp.tickUpper);
        // INVARIANT — the price cannot be past the range's far side (below it when short token1, above it when
        // short token0): the flash debt is the just-added range's own deficit side, and the exact-input
        // reconcile sell repays it in full at the latest when it exhausts the range — so a still-owed deficit
        // means the sell stopped at or before the far edge. The near side needs no such bound (a range fully
        // beyond spot trims from a price outside it), hence the one-sided clamps.
        uint256 dlUp;
        if (deficitIs1) {
            // token1 occupies [sqrtLower, min(price, sqrtUpper)]: amount1 = L * (hi - lo) / Q96
            uint160 hi = sqrtPriceX96 < sqrtUpper ? sqrtPriceX96 : sqrtUpper;
            dlUp = FullMath.mulDivRoundingUp(amountOut + 1, FixedPoint96.Q96, hi - sqrtLower);
        } else {
            // token0 occupies [max(price, sqrtLower), sqrtUpper]: amount0 = L * Q96 * (hi - lo) / (hi * lo)
            uint160 lo = sqrtPriceX96 > sqrtLower ? sqrtPriceX96 : sqrtLower;
            uint256 intermediate = FullMath.mulDivRoundingUp(lo, sqrtUpper, FixedPoint96.Q96);
            dlUp = FullMath.mulDivRoundingUp(amountOut + 1, intermediate, sqrtUpper - lo);
        }
        dl = dlUp >= lopt ? lopt : uint128(dlUp);
        _decrease(cp.key, tokenId, dl, cp.hookData);
    }

    // ───────────────────────────────────────────── sizing math ─────────────────────────────────────────────

    /// @dev Fee-aware sizing. First size at mid to find which side is the surplus (the side the same-pool
    ///      reconcile will swap), then re-size discounting that side's value by that swap direction's total
    ///      fee, so we don't over-mint by a fee the trim would otherwise have to claw back. Discounting the
    ///      side on both the budget and the reference nets to charging the fee on exactly the swapped amount.
    ///      If the holdings are already in ratio (no swap needed) the mid size is returned unchanged.
    ///      `protocolFee` is the packed directional pair from Slot0; the direction's component compounds with
    ///      the lp fee (ProtocolFeeLibrary.calculateSwapFee), it does not simply add.
    function _sizeFeeAware(uint160 sp, uint160 sl, uint160 su, uint256 b0, uint256 b1, uint24 protocolFee, uint24 lpFee)
        internal
        pure
        returns (uint128)
    {
        uint128 midL = _sizeLiquidityWeighted(sp, sl, su, b0, b1, PIPS_DENOMINATOR, PIPS_DENOMINATOR);
        (uint256 a0m, uint256 a1m) = _getAmountsForLiquidity(sp, sl, su, midL);
        if (b0 > a0m) {
            // token0 is surplus -> the reconcile sells it zeroForOne -> discount token0 by that direction's fee.
            uint256 feePips =
                ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.getZeroForOneFee(protocolFee), lpFee);
            return _sizeLiquidityWeighted(sp, sl, su, b0, b1, PIPS_DENOMINATOR - feePips, PIPS_DENOMINATOR);
        } else if (b1 > a1m) {
            // token1 is surplus -> the reconcile sells it oneForZero -> discount token1 by that direction's fee.
            uint256 feePips =
                ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.getOneForZeroFee(protocolFee), lpFee);
            return _sizeLiquidityWeighted(sp, sl, su, b0, b1, PIPS_DENOMINATOR, PIPS_DENOMINATOR - feePips);
        }
        return midL;
    }

    /// @dev Size L by value conservation: the budget's value must equal the value of a position of size L at
    ///      the current price, so L = REFERENCE_LIQUIDITY * value(budget) / value(reference position). Values
    ///      are expressed in the CHEAPER token (token1 when price >= 1, token0 otherwise) so the conversion
    ///      rate is always >= Q96: the expensive side is multiplied up, never truncated toward zero, keeping
    ///      the sizing exact (<= 2^-95 rate error) across the full tick domain. `pips0`/`pips1` weight each
    ///      side's value (1e6 = 100%); the fee-aware caller discounts exactly one — the side the reconcile
    ///      will sell.
    ///      Precision: the final division truncates at 1 part in value(reference) and only ever under-sizes —
    ///      the safe direction (the leftover is swept back as dust).
    function _sizeLiquidityWeighted(
        uint160 sp,
        uint160 sl,
        uint160 su,
        uint256 b0,
        uint256 b1,
        uint256 pips0,
        uint256 pips1
    ) internal pure returns (uint128) {
        (uint256 a0r, uint256 a1r) = _getAmountsForLiquidity(sp, sl, su, REFERENCE_LIQUIDITY);
        uint256 refValue;
        uint256 budgetValue;
        if (sp >= FixedPoint96.Q96) {
            // price >= 1: value in token1. rate * pips fits: rate <= sqrtMax^2/Q96 ~ 2^224, pips <= 2^20.
            uint256 rate0X96 = FullMath.mulDiv(sp, sp, FixedPoint96.Q96);
            refValue = FullMath.mulDiv(a0r, rate0X96 * pips0, FixedPoint96.Q96 * PIPS_DENOMINATOR)
                + FullMath.mulDiv(a1r, pips1, PIPS_DENOMINATOR);
            budgetValue = FullMath.mulDiv(b0, rate0X96 * pips0, FixedPoint96.Q96 * PIPS_DENOMINATOR)
                + FullMath.mulDiv(b1, pips1, PIPS_DENOMINATOR);
        } else {
            // price < 1: value in token0. token0-per-token1 = Q96^3/sp^2, split in two mulDivs (Q96^3 > 2^256);
            // each factor is >= Q96 since sp < Q96, so both truncations stay below 2^-96.
            uint256 rate1X96 =
                FullMath.mulDiv(FullMath.mulDiv(FixedPoint96.Q96, FixedPoint96.Q96, sp), FixedPoint96.Q96, sp);
            refValue = FullMath.mulDiv(a0r, pips0, PIPS_DENOMINATOR)
                + FullMath.mulDiv(a1r, rate1X96 * pips1, FixedPoint96.Q96 * PIPS_DENOMINATOR);
            budgetValue = FullMath.mulDiv(b0, pips0, PIPS_DENOMINATOR)
                + FullMath.mulDiv(b1, rate1X96 * pips1, FixedPoint96.Q96 * PIPS_DENOMINATOR);
        }
        if (refValue == 0) return 0;
        return FullMath.mulDiv(REFERENCE_LIQUIDITY, budgetValue, refValue).toUint128();
    }

    /// @dev token amounts required for `liquidity` at the given price/range, via SqrtPriceMath. Rounded UP to
    ///      mirror POSM's MINT_POSITION (which rounds the pull up, in the pool's favor): so the flash-take
    ///      decision in `_flashTakeDeficit` sees the true required amount and the contract is never a wei short
    ///      of what POSM pulls. For sizing, rounding the reference up only shrinks L — the safe direction. The
    ///      <=1-wei over-estimate is swept as dust.
    function _getAmountsForLiquidity(uint160 sqrtPriceX96, uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (sqrtPriceX96 <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, true);
        } else if (sqrtPriceX96 < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, true);
        }
    }

    /// @dev The final position composition at the live (post-reconcile) price, for the return values.
    function _positionAmounts(CoreParams memory cp, uint128 liquidity)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(cp.key.toId());
        (amount0, amount1) = _getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(cp.tickLower),
            TickMath.getSqrtPriceAtTick(cp.tickUpper),
            liquidity
        );
    }

    // ───────────────────────────────────────────── POSM / pool actions ─────────────────────────────────────────────

    /// @dev Deploy `liquidity` through POSM: MINT a new position when `existingTokenId` is 0 (owned by THIS
    ///      contract so `_trim` can decrease it within the unlock), else INCREASE that tokenId in place. Funding
    ///      comes from this contract (standing Permit2 allowance / forwarded native value; a SWEEP returns
    ///      unused native wei). POSM's per-amount slippage limits are set to max: the single `minLiquidity`
    ///      floor checked after the trim is the operation's slippage gate.
    ///      Each currency is settled with CLOSE_CURRENCY rather than one SETTLE_PAIR: POSM applies
    ///      `liquidityDelta + feesAccrued` to its own delta, so on a grow op a fee credit larger than that
    ///      side's principal makes the delta POSITIVE, and SETTLE_PAIR (which asserts a debt) would revert
    ///      DeltaNotNegative. The callback collects the position's fees before the route, so the only source
    ///      left is fees accrued DURING the operation — a route leg trading this pool, or a hook doing the
    ///      same — but tolerating either sign removes the whole failure class instead of proving each source
    ///      is handled. A taken credit lands in this contract's balance, where the reconcile spends it on the
    ///      flash debt (a smaller trim, i.e. more retained liquidity) and the sweep returns any remainder.
    ///      On a MINT the delta is always a pure debt, so CLOSE_CURRENCY is exactly SETTLE_PAIR there.
    function _deploy(CoreParams memory cp, uint256 existingTokenId, uint128 liquidity, uint256 amount0)
        internal
        returns (uint256 tokenId)
    {
        bool isMint = existingTokenId == 0;
        tokenId = isMint ? positionManager.nextTokenId() : existingTokenId;

        Currency c0 = cp.key.currency0;
        uint8 deployAction = uint8(isMint ? Actions.MINT_POSITION : Actions.INCREASE_LIQUIDITY);
        bytes memory actions;
        bytes[] memory params;
        if (c0.isAddressZero()) {
            actions = abi.encodePacked(
                deployAction, uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.SWEEP)
            );
            params = new bytes[](4);
            params[3] = abi.encode(c0, ActionConstants.MSG_SENDER);
        } else {
            actions = abi.encodePacked(deployAction, uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY));
            params = new bytes[](3);
        }
        params[0] = isMint
            ? abi.encode(
                cp.key,
                cp.tickLower,
                cp.tickUpper,
                liquidity,
                type(uint128).max,
                type(uint128).max,
                address(this),
                cp.hookData
            )
            : abi.encode(tokenId, uint256(liquidity), type(uint128).max, type(uint128).max, cp.hookData);
        params[1] = abi.encode(c0);
        params[2] = abi.encode(cp.key.currency1);

        // forward exactly the required native amount (the funding is wei-exact, see _flashTakeDeficit); the
        // SWEEP returns whatever POSM does not consume of the forwarded value.
        uint256 nativeToForward = c0.isAddressZero() ? amount0 : 0;
        positionManager.modifyLiquiditiesWithoutUnlock{value: nativeToForward}(actions, params);
    }

    /// @dev Run the caller's verbatim Universal Router route. The route encodes its own input token and (fixed)
    ///      input amount, so BOTH sides are funded up front — the standing Permit2 allowances cover the ERC-20
    ///      sides and the native balance is forwarded as value — and the route pulls whichever side it declares.
    ///      (Funding one side chosen by an on-chain surplus classification could flip vs the off-chain route
    ///      direction on price drift and leave the route's pull unfunded.) UR consumes exactly what the route
    ///      commands specify; any native value the route did not consume is reclaimed via a UR SWEEP right
    ///      after — UR's balance is permissionlessly sweepable, so not a wei may be left there. Everything
    ///      unconsumed thus stays in this contract for the same-pool reconcile.
    function _runRoute(CoreParams memory cp) internal {
        (bytes memory commands, bytes[] memory inputs) = abi.decode(cp.route, (bytes, bytes[]));
        // forward the WHOLE native balance: under no-funds-at-rest it is exactly the operation's own native
        // budget (native pool) or native route funding (non-native pool) — zero when neither applies.
        uint256 value = address(this).balance;

        universalRouter.execute{value: value}(commands, inputs);
        // Reclaim ANY native left in the UR: the operation's own over-push (the push is sized to the full
        // held balance, so a remainder is expected), a route leg that produced native output on a non-native
        // pool (a supported routeFunding flow that pushes zero value), or a pre-existing donation — UR
        // balances are permissionlessly sweepable, so not a wei may be left there. The SWEEP takes the
        // router's WHOLE balance; on a native pool it joins the caller's budget, otherwise it rests here
        // until claimed (donation doctrine / a zero-amount address(0) routeFunding entry).
        if (address(universalRouter).balance > 0) {
            bytes[] memory sweepInputs = new bytes[](1);
            // token ETH (address(0)), recipient MSG_SENDER (UR maps it back to this contract), no minimum.
            sweepInputs[0] = abi.encode(address(0), ActionConstants.MSG_SENDER, 0);
            universalRouter.execute(abi.encodePacked(uint8(UR_SWEEP_COMMAND)), sweepInputs);
        }
    }

    /// @dev Burn the whole position and TAKE both tokens (+ fees) to this contract.
    function _withdraw(PoolKey memory key, uint256 tokenId, bytes memory hookData) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), hookData);
        params[1] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
    }

    /// @dev DECREASE `dl` liquidity (0 collects just the accrued fees) and TAKE both tokens to this contract.
    function _decrease(PoolKey memory key, uint256 tokenId, uint128 dl, bytes memory hookData) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(dl), uint128(0), uint128(0), hookData);
        params[1] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
    }

    /// @dev Same-pool swap with no price limit: `minLiquidity` on the final position is the slippage gate, and
    ///      the input is bounded by the operation's own holdings (see the reconcile notes in ISwapAndAdd).
    ///      Forward the operation's hookData just like the associated liquidity actions.
    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, bytes memory hookData) internal {
        poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );
    }

    // ───────────────────────────────────────────── delta / token helpers ─────────────────────────────────────────────

    /// @dev Settle as much of `currency`'s outstanding debt as we currently hold (no-op on a credit/zero debt).
    function _settleToward(Currency currency) internal {
        int256 d = poolManager.currencyDelta(address(this), currency);
        if (d >= 0) return;
        uint256 debt = uint256(-d);
        uint256 held = currency.balanceOfSelf();
        uint256 pay = held < debt ? held : debt;
        if (pay > 0) _settle(currency, address(this), pay);
    }

    /// @dev Take any positive credit on `currency` into this contract's balance.
    function _takeCredit(Currency currency) internal {
        int256 d = poolManager.currencyDelta(address(this), currency);
        if (d > 0) _take(currency, address(this), uint256(d));
    }

    /// @dev Pull the caller's budget into this contract: native via msg.value (exact), ERC-20 via Permit2.
    ///      currency1 is never native (native sorts to currency0), so only currency0 can consume value.
    ///      `fundingValue` is the native amount `_pullFunding` declared; the funding guard makes the two
    ///      msg.value sources mutually exclusive (a native pool rejects an address(0) funding entry), so the
    ///      sum below always has at most one non-zero term.
    function _pullBudget(PoolKey memory key, uint256 amount0In, uint256 amount1In, uint256 fundingValue) internal {
        uint256 expectedValue = fundingValue;
        Currency c0 = key.currency0;

        // currency0 can either be native or an ERC-20
        if (c0.isAddressZero()) {
            // amountIn must match msg.value
            expectedValue += amount0In;
        } else if (amount0In > 0) {
            permit2.transferFrom(msg.sender, address(this), amount0In.toUint160(), Currency.unwrap(c0));
        }

        // currency1 is always an ERC-20
        if (amount1In > 0) {
            permit2.transferFrom(msg.sender, address(this), amount1In.toUint160(), Currency.unwrap(key.currency1));
        }
        // msg.value must match its single meaning: the native budget (native pool) OR the native funding entry
        if (msg.value != expectedValue) revert InvalidEthValue();
        // under multicall msg.value is per-BATCH (delegatecall preserves it), so equality alone no longer
        // proves this op is funded: an earlier subcall may have consumed the value. Native spending is
        // balance-based throughout, so a double-claim can only revert — this guard just makes it revert HERE.
        if (address(this).balance < expectedValue) revert InvalidEthValue();
    }

    /// @dev Pull the positive (add) rebalance deltas from the caller, before the unlock so msg.sender is still
    ///      the caller (mirrors `_pullBudget`, including the `fundingValue` semantics). Negative deltas pull
    ///      nothing here — they are returned to the recipient inside the unlock (`_resolveBudget`) once the
    ///      withdrawn amounts are known.
    function _pullAdditional(PoolKey memory key, int128 additional0, int128 additional1, uint256 fundingValue)
        internal
    {
        uint256 expectedValue = fundingValue;
        Currency c0 = key.currency0;
        if (additional0 > 0) {
            uint256 amount = uint256(uint128(additional0));
            if (c0.isAddressZero()) expectedValue += amount;
            else permit2.transferFrom(msg.sender, address(this), uint160(amount), Currency.unwrap(c0));
        }
        if (additional1 > 0) {
            permit2.transferFrom(
                msg.sender, address(this), uint160(uint256(uint128(additional1))), Currency.unwrap(key.currency1)
            );
        }
        if (msg.value != expectedValue) revert InvalidEthValue();
        // per-batch msg.value under multicall: see the identical guard in _pullBudget.
        if (address(this).balance < expectedValue) revert InvalidEthValue();
    }

    /// @dev Pull the caller's route-funding entries — non-pool tokens that exist solely to fund the route —
    ///      and wire their approvals so the route can spend them. Native entries contribute to the expected
    ///      msg.value instead of a Permit2 pull; on a native pool address(0) IS currency0 and is rejected as a
    ///      pool currency, so msg.value never has two meanings. Pool currencies are budget, not funding
    ///      (rejecting them keeps one canonical encoding). A zero-amount entry pulls nothing but still wires
    ///      and later sweeps its token — the donation-claim path (see the contract INVARIANT).
    function _pullFunding(PoolKey memory key, TokenAmount[] calldata funding, bytes calldata route)
        internal
        returns (uint256 expectedValue)
    {
        if (funding.length == 0) return 0;
        // funding is route input by definition: without a route it would only round-trip to the recipient.
        if (route.length == 0) revert RouteFundingRequiresRoute();
        for (uint256 i = 0; i < funding.length; i++) {
            Currency token = funding[i].token;
            if (token == key.currency0 || token == key.currency1) revert InvalidFundingToken(token);
            if (token.isAddressZero()) {
                expectedValue += funding[i].amount;
            } else {
                if (funding[i].amount > 0) {
                    permit2.transferFrom(
                        msg.sender, address(this), funding[i].amount.toUint160(), Currency.unwrap(token)
                    );
                }
                _ensureApproved(token);
            }
        }
    }

    /// @dev Sweep every funding token to the resolved recipient: whatever the route did not consume must not
    ///      stay in this contract (no-funds-at-rest). Runs after the unlock. The RESOLVED recipient — not
    ///      msg.sender — receives leftovers, because a route can also PRODUCE a funding token from position
    ///      value (collected fees, withdrawn principal); sweeping to msg.sender would hand an approved
    ///      operator a value-redirect path through the zap.
    function _sweepFunding(TokenAmount[] calldata funding, address to) internal {
        for (uint256 i = 0; i < funding.length; i++) {
            _sweep(funding[i].token, to);
        }
    }

    /// @dev Wires a token up: max-approves it to Permit2 and grants standing max Permit2 allowances to POSM
    ///      and the UR — both only ever pull from their direct caller (this contract), which holds nothing at
    ///      rest (see the contract-level INVARIANT), so a standing allowance grants no more than the bounded
    ///      per-operation allowance it replaces while saving an allowance write on every subsequent operation.
    ///      Already-wired is detected from live state (cheaper than a flag: both slots are re-read by the
    ///      operation's own pulls): the Permit2 allowance for POSM is the init marker — only this contract can
    ///      write it and max never decrements or expires; the token's own allowance can't be it, some tokens
    ///      hardcode an infinite Permit2 allowance — plus a headroom re-check that heals tokens whose
    ///      allowance decrements even from max (no single Permit2 pull can exceed uint160).
    function _ensureApproved(Currency currency) internal {
        // skip approval for native token
        if (currency.isAddressZero()) return;

        address token = Currency.unwrap(currency);
        // check the standing allowance with permit2 for the position manager.
        (uint160 permitted,,) = permit2.allowance(address(this), token, address(positionManager));
        // check the standing allowance with the token for permit2.
        uint256 tokenAllowance = ERC20(token).allowance(address(this), address(permit2));
        // if both allowances are set, skip renewal. UR is guaranteed to have a standing allowance as well.
        if (permitted == type(uint160).max && tokenAllowance >= type(uint160).max) return;

        // Skipped entirely when the token hardcodes an infinite Permit2 allowance.
        if (tokenAllowance != type(uint256).max) {
            // zero-first for approve-race tokens (USDT). Only reachable on a heal, since a first init starts from zero)
            if (tokenAllowance != 0) SafeTransferLib.safeApprove(ERC20(token), address(permit2), 0);
            // safeApprove: tokens that return nothing (e.g. USDT) would revert a plain IERC20.approve on decode.
            SafeTransferLib.safeApprove(ERC20(token), address(permit2), type(uint256).max);
        }
        permit2.approve(token, address(positionManager), type(uint160).max, ALLOWANCE_EXPIRATION);
        permit2.approve(token, address(universalRouter), type(uint160).max, ALLOWANCE_EXPIRATION);
    }

    function _sweep(Currency currency, address to) internal {
        uint256 bal = currency.balanceOfSelf();
        if (bal > 0) currency.transfer(to, bal);
    }

    /// @inheritdoc DeltaResolver
    /// @dev Only ever called for this contract settling its own delta; we hold the tokens, so transfer them.
    function _pay(Currency currency, address, uint256 amount) internal override {
        currency.transfer(address(poolManager), amount);
    }

    /// @dev Output must be deliverable: this contract would strand it (violating no-funds-at-rest), and the
    ///      zero address would either revert late (the NFT hand-off rejects address(0) after the whole
    ///      operation already ran) or, on the grow ops, silently burn swept leftovers — including unconsumed
    ///      route funding. Reject both up front.
    function _validateRecipient(address recipient) internal view {
        if (recipient == address(this) || recipient == address(0)) revert InvalidRecipient(recipient);
    }

    /// @dev Revert unless msg.sender is the position owner or an ERC-721-approved operator for it, and resolve
    ///      where the operation's output goes: only the owner may name a custom recipient. For an approved
    ///      operator ALL output (a new NFT, any cash-out, swept dust) is forced to the owner, so a standing
    ///      NFT approval can never be used to redirect the position's value to the operator.
    function _authAndResolveRecipient(uint256 tokenId, address requested) internal view returns (address) {
        // POSM IS a solmate ERC721 (via ERC721Permit_v4); IPositionManager just doesn't declare that surface.
        ERC721 posm = ERC721(address(positionManager));
        address owner = posm.ownerOf(tokenId);
        if (msg.sender == owner) return requested;
        if (posm.getApproved(tokenId) != msg.sender && !posm.isApprovedForAll(owner, msg.sender)) {
            revert NotAuthorizedForToken(tokenId);
        }
        return owner;
    }
}
