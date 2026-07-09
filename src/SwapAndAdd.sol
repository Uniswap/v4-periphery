// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
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
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {PositionInfo, PositionInfoLibrary} from "./libraries/PositionInfoLibrary.sol";
import {SafeCallback} from "./base/SafeCallback.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {Permit2Forwarder} from "./base/Permit2Forwarder.sol";
import {ReentrancyLock} from "./base/ReentrancyLock.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {ISwapAndAdd} from "./interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "./interfaces/external/IUniversalRouter.sol";

interface IERC721Minimal {
    function ownerOf(uint256 id) external view returns (address);
    function getApproved(uint256 id) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function transferFrom(address from, address to, uint256 id) external;
}

/// @title SwapAndAdd
/// @notice See ISwapAndAdd. Route-first swap-and-add / rebalance zap for Uniswap v4.
///
///         Flow, all inside one PoolManager unlock:
///           1. ROUTE FIRST — run the caller's verbatim Universal Router route to swap the surplus side toward
///              the deficit side (best execution, off-venue). After it, the contract holds the *actual* tokens.
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
///           required ratio would depend on the swap we are still computing — a circular dependency (the
///           Aperture problem). Minting *first* fixes the position's composition at the live price, so the
///           reconcile swap can move the price freely without invalidating the mint. The *route* runs before
///           the mint too, but it is off-venue (it does not touch this pool), so it cannot move this pool's
///           price out from under the mint — it only tells us the real holdings to size from. `minLiquidity`
///           checked on the final position is the single slippage gate for the whole operation.
///
///         INVARIANT — no funds at rest: outside an active operation this contract holds no tokens, no native
///         balance and no positions. Every entrypoint pulls the caller's budget, deploys/settles it in full and
///         sweeps the remainder within the same transaction (any donation to the contract is simply treated as
///         part of the next caller's budget). The standing max Permit2 allowances to POSM and the Universal
///         Router (see `_ensureApproved`) are safe *because* of this invariant: both spenders only ever pull
///         from their direct caller, i.e. only when this contract itself invokes them mid-operation, at which
///         point the balance is the current caller's own budget and `minLiquidity` bounds the outcome.
///
///         v4-only; ERC-20 + native ETH. Four ops: add + rebalance mint a NEW position (to this contract so it
///         can be trimmed, transferred to the recipient after the unlock closes); increase + compound grow an
///         EXISTING tokenId in place through the same core.
contract SwapAndAdd is ISwapAndAdd, SafeCallback, DeltaResolver, Permit2Forwarder, ReentrancyLock {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    using SafeCast for uint256;

    /// @dev Extra wei flash-taken on the deficit side so POSM's round-up never under-funds the mint.
    uint256 private constant ROUNDING_BUFFER = 1;
    uint48 private constant ALLOWANCE_EXPIRATION = type(uint48).max;
    /// @dev v4 fees are expressed in pips (millionths).
    uint256 private constant PIPS_DENOMINATOR = 1e6;
    /// @dev Reference liquidity the sizing math scales from; see `_sizeLiquidityWeighted`.
    uint128 private constant REFERENCE_LIQUIDITY = 1e18;
    /// @dev universal-router Commands.SWEEP — used to reclaim native value a route left in the UR.
    uint256 private constant UR_SWEEP_COMMAND = 0x04;
    uint256 private constant OP_ADD = 0;
    uint256 private constant OP_REBALANCE = 1;
    uint256 private constant OP_COMPOUND = 2;
    uint256 private constant OP_INCREASE = 3;

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

    /// @dev Tokens already wired up: max-approved to Permit2, with standing Permit2 allowances for POSM and the
    ///      UR. Safe under the no-funds-at-rest invariant documented on the contract.
    mapping(address token => bool) private _tokenApproved;

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
        _pullBudget(params.poolKey, params.amount0In, params.amount1In);
        bytes memory result = poolManager.unlock(abi.encode(OP_ADD, abi.encode(params)));
        (tokenId, liquidity, amount0, amount1) = abi.decode(result, (uint256, uint128, uint256, uint256));
        // the position was minted to this contract so it could be trimmed; hand it to the recipient now that
        // the pool is locked again.
        IERC721Minimal(address(positionManager)).transferFrom(address(this), params.recipient, tokenId);
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
        address recipient = _authAndResolveRecipient(params.tokenId, params.recipient);
        // pull any positive (add) deltas here, where msg.sender is the caller (mirrors add()'s _pullBudget);
        // negative (return) deltas are handled inside the unlock once we know the withdrawn amounts.
        _pullAdditional(key, params.additionalA, params.additionalB);

        bytes memory result = poolManager.unlock(abi.encode(OP_REBALANCE, abi.encode(params, key, recipient)));
        (newTokenId, liquidity, amount0, amount1) = abi.decode(result, (uint256, uint128, uint256, uint256));
        IERC721Minimal(address(positionManager)).transferFrom(address(this), recipient, newTokenId);
    }

    /// @inheritdoc ISwapAndAdd
    function increase(IncreaseParams calldata params)
        external
        payable
        isNotLocked
        checkDeadline(params.deadline)
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1)
    {
        // read the position's pool + existing range; the increase deploys into that same range/tokenId.
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(params.tokenId);
        // pull the caller's budget here (mirrors add()'s _pullBudget) — funds come from msg.sender, the position
        // only grows for whoever owns it, so no CALLER auth is needed. POSM still gates INCREASE_LIQUIDITY on this
        // contract being approved on the tokenId (the owner grants that, same as for compound/rebalance).
        _pullBudget(key, params.amount0In, params.amount1In);
        bytes memory result =
            poolManager.unlock(abi.encode(OP_INCREASE, abi.encode(params, key, info.tickLower(), info.tickUpper())));
        (liquidityAdded, amount0, amount1) = abi.decode(result, (uint128, uint256, uint256));
    }

    /// @inheritdoc ISwapAndAdd
    function compound(CompoundParams calldata params)
        external
        isNotLocked
        checkDeadline(params.deadline)
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1)
    {
        // the position NFT never moves and only grows, so forcing an operator's (dust) sweep to the owner is
        // belt-and-braces.
        address recipient = _authAndResolveRecipient(params.tokenId, params.recipient);
        bytes memory result = poolManager.unlock(abi.encode(OP_COMPOUND, abi.encode(params, recipient)));
        (liquidityAdded, amount0, amount1) = abi.decode(result, (uint128, uint256, uint256));
    }

    /// @dev Revert unless msg.sender is the position owner or an ERC-721-approved operator for it, and resolve
    ///      where the operation's output goes: only the owner may name a custom recipient. For an approved
    ///      operator ALL output (a new NFT, any cash-out, swept dust) is forced to the owner, so a standing
    ///      NFT approval can never be used to redirect the position's value to the operator.
    function _authAndResolveRecipient(uint256 tokenId, address requested) internal view returns (address) {
        IERC721Minimal posm = IERC721Minimal(address(positionManager));
        address owner = posm.ownerOf(tokenId);
        if (msg.sender == owner) return requested;
        if (posm.getApproved(tokenId) != msg.sender && !posm.isApprovedForAll(owner, msg.sender)) {
            revert NotAuthorizedForToken(tokenId);
        }
        return owner;
    }

    // ───────────────────────────────────────────── unlock callback ─────────────────────────────────────────────

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (uint256 op, bytes memory inner) = abi.decode(data, (uint256, bytes));
        if (op == OP_COMPOUND) {
            (CompoundParams memory cparams, address recipient) = abi.decode(inner, (CompoundParams, address));
            (uint128 liqAdded, uint256 added0, uint256 added1) = _compound(cparams, recipient);
            return abi.encode(liqAdded, added0, added1);
        }
        if (op == OP_INCREASE) {
            (IncreaseParams memory p, PoolKey memory key, int24 tickLower, int24 tickUpper) =
                abi.decode(inner, (IncreaseParams, PoolKey, int24, int24));
            CoreParams memory icp = CoreParams({
                key: key,
                tickLower: tickLower,
                tickUpper: tickUpper,
                budget0: p.amount0In,
                budget1: p.amount1In,
                route: p.route,
                minLiquidity: p.minLiquidityAdded,
                recipient: p.recipient,
                hookData: p.hookData
            });
            // existing tokenId -> _addCore INCREASEs it in place (no new NFT).
            (, uint128 liqAdded, uint256 added0, uint256 added1) = _addCore(icp, p.tokenId);
            return abi.encode(liqAdded, added0, added1);
        }

        CoreParams memory cp;
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
            (RebalanceParams memory p, PoolKey memory key, address recipient) =
                abi.decode(inner, (RebalanceParams, PoolKey, address));
            cp = _prepareRebalance(p, key, recipient);
        }
        // tokenId 0 -> _addCore MINTs a new position.
        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = _addCore(cp, 0);
        return abi.encode(tokenId, liq, a0, a1);
    }

    /// @dev Rebalance prep: burn the WHOLE position, then resolve each token's redeploy budget from the signed
    ///      delta — `withdrawn + additional`. Positive deltas were already pulled in `rebalance()` (so they sit in
    ///      this contract's balance); negative deltas are returned to the recipient HERE, before the add flow runs.
    ///      Returning the cash-out share up front is what keeps the accounting safe: the contract is then left
    ///      holding exactly the redeploy budget, so every `balanceOfSelf()` read in `_addCore` (the route, the
    ///      reconcile's sell-all, the mint settle) sees only what should be deployed — never the portion owed back.
    function _prepareRebalance(RebalanceParams memory p, PoolKey memory key, address recipient)
        internal
        returns (CoreParams memory cp)
    {
        _withdraw(key, p.tokenId, p.hookData); // burn the full position; tokens land in this contract.

        cp = CoreParams({
            key: key,
            tickLower: p.newTickLower,
            tickUpper: p.newTickUpper,
            budget0: _resolveBudget(key.currency0, p.additionalA, recipient),
            budget1: _resolveBudget(key.currency1, p.additionalB, recipient),
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
        if (delta >= 0) return held; // withdrawn + (pre-pulled) additional
        // widen before negating: -int128 would overflow on type(int128).min
        uint256 toReturn = uint256(-int256(delta));
        if (toReturn > held) revert ReturnExceedsWithdrawn(toReturn, held);
        currency.transfer(recipient, toReturn);
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
        _ensureApproved(cp.key.currency0);
        _ensureApproved(cp.key.currency1);

        // 1. ROUTE FIRST: run the verbatim route (best-execution, off-venue) to convert the surplus toward the
        //    deficit, then re-read balances — we now size from the *actual* holdings, not an estimate.
        if (cp.route.length != 0) {
            _runRoute(cp);
            cp.budget0 = cp.key.currency0.balanceOfSelf();
            cp.budget1 = cp.key.currency1.balanceOfSelf();
        }

        // 2. size from the holdings (fee-aware, optimistic), flash-take whatever side is short, then mint a new
        //    position or increase the existing one.
        (uint128 lopt, uint256 a0opt, uint256 a1opt) = _planLiquidity(cp);
        _flashTakeDeficit(cp, a0opt, a1opt);
        tokenId = _deploy(cp, existingTokenId, lopt, a0opt);

        // 3. reconcile any residual same-pool (in whichever direction is short) and trim to the exact funded size.
        uint128 trimmed = _reconcile(cp, tokenId, lopt, a0opt, a1opt);
        liquidity = lopt - trimmed;

        // 4. slippage floor — the single gate for the whole operation.
        if (liquidity < cp.minLiquidity) revert InsufficientLiquidity(uint128(cp.minLiquidity), liquidity);

        // 5. report the position's composition; sweep any leftover (small, in the input token) to the recipient.
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
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cp.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cp.tickUpper);
        // mid price (token1 per token0, Q96): the value-conservation reference for sizing L from the budget.
        uint256 midRateX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        liquidity =
            _sizeFeeAware(sqrtPriceX96, sqrtLower, sqrtUpper, cp.budget0, cp.budget1, midRateX96, protocolFee, lpFee);
        (amount0, amount1) = _getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
    }

    /// @dev Flash-`take` from the pool whatever the optimistic deploy needs beyond the held budget, on each side,
    ///      so the subsequent mint/increase is fully funded; `_reconcile` later settles what the take actually owes.
    function _flashTakeDeficit(CoreParams memory cp, uint256 amount0, uint256 amount1) internal {
        if (amount0 > cp.budget0) _take(cp.key.currency0, address(this), amount0 - cp.budget0 + ROUNDING_BUFFER);
        if (amount1 > cp.budget1) _take(cp.key.currency1, address(this), amount1 - cp.budget1 + ROUNDING_BUFFER);
    }

    /// @dev Compound: reinvest the position's accrued fees back into the SAME tokenId. Mirrors `_addCore` but with
    ///      no route (fees are tiny — same-pool only) and an INCREASE in place of a fresh MINT, so the existing NFT
    ///      just grows. Collect fees -> size from them (fee-aware) -> flash-take any deficit -> INCREASE ->
    ///      reconcile residual same-pool + trim -> floor -> sweep dust. The fees never leave to the wallet.
    function _compound(CompoundParams memory p, address recipient)
        internal
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1)
    {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(p.tokenId);

        // collect fees only: DECREASE by 0 liquidity credits the accrued fees, TAKE_PAIR pulls them here.
        _decrease(key, p.tokenId, 0, p.hookData);

        // budget = the collected fees; target the position's existing range; no route. Then run the shared core,
        // INCREASING the same tokenId in place (the fees never leave to the wallet; the NFT stays with its owner).
        CoreParams memory cp = CoreParams({
            key: key,
            tickLower: info.tickLower(),
            tickUpper: info.tickUpper(),
            budget0: key.currency0.balanceOfSelf(),
            budget1: key.currency1.balanceOfSelf(),
            route: "",
            minLiquidity: p.minLiquidityAdded,
            recipient: recipient,
            hookData: p.hookData
        });
        if (cp.budget0 == 0 && cp.budget1 == 0) revert NoFeesToCompound();

        (, liquidityAdded, amount0, amount1) = _addCore(cp, p.tokenId);
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
            _swap(cp.key, zeroForOne, -surplusBal.toInt256());
            _settleToward(surplus);
        }

        // 3. whatever deficit is still owed (the genuine residual) -> free it by trimming the position. The
        //    DECREASE frees BOTH tokens when the price is in range, so it also tops the surplus side back up.
        int256 owed = poolManager.currencyDelta(address(this), deficit);
        if (owed < 0) {
            trimmed = _trim(cp, tokenId, lopt, deficitIs1, uint256(-owed));
            _settleToward(deficit);
        }

        // 4. clean up: take any leftover deficit credit; sell a tiny rounding excess back so dust stays in the
        //    surplus (= input) token; then square up the surplus side (its swap output nets against any
        //    remaining surplus debt in the transient accounting).
        _takeCredit(deficit);
        uint256 excessDeficit = deficit.balanceOfSelf();
        if (excessDeficit > ROUNDING_BUFFER) {
            _swap(cp.key, !zeroForOne, -excessDeficit.toInt256()); // deficit -> surplus exact-input
            _settleToward(deficit);
        }
        _takeCredit(surplus);
        _settleToward(surplus);
    }

    /// @dev DECREASE the position by enough liquidity to free at least `amountOut` of the deficit token,
    ///      capped at `lopt` — the liquidity this flow just added. On increase/compound the position also
    ///      holds the owner's pre-existing principal, which the trim must never consume; if even the full
    ///      `lopt` cannot free the deficit, the unlock reverts (CurrencyNotSettled) instead.
    function _trim(CoreParams memory cp, uint256 tokenId, uint128 lopt, bool deficitIs1, uint256 amountOut)
        internal
        returns (uint128 dl)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(cp.key.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cp.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cp.tickUpper);
        if (deficitIs1) {
            // token1 occupies [sqrtLower, min(price, sqrtUpper)]
            uint160 hi = sqrtPriceX96 < sqrtUpper ? sqrtPriceX96 : sqrtUpper;
            if (hi <= sqrtLower) hi = sqrtUpper; // price below range (all token0 — shouldn't be the token1 deficit)
            dl = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, hi, amountOut);
        } else {
            // token0 occupies [max(price, sqrtLower), sqrtUpper]
            uint160 lo = sqrtPriceX96 > sqrtLower ? sqrtPriceX96 : sqrtLower;
            if (lo >= sqrtUpper) lo = sqrtLower; // price above range (all token1)
            dl = LiquidityAmounts.getLiquidityForAmount0(lo, sqrtUpper, amountOut);
        }
        // +1 because DECREASE frees rounded-down amounts (so the freed amount covers `amountOut`), capped at lopt.
        dl = dl >= lopt ? lopt : dl + 1;
        _decrease(cp.key, tokenId, dl, cp.hookData);
    }

    // ───────────────────────────────────────────── sizing math ─────────────────────────────────────────────

    /// @dev Fee-aware sizing. First size at mid to find which side is the surplus (the side the same-pool
    ///      reconcile will swap), then re-size discounting that side's value by that swap direction's total
    ///      fee, so we don't over-mint by a fee the trim would otherwise have to claw back. If the holdings
    ///      are already in ratio (no swap needed) the mid size is returned unchanged. `protocolFee` is the
    ///      packed directional pair from Slot0; the direction's component compounds with the lp fee
    ///      (ProtocolFeeLibrary.calculateSwapFee), it does not simply add.
    function _sizeFeeAware(
        uint160 sp,
        uint160 sl,
        uint160 su,
        uint256 b0,
        uint256 b1,
        uint256 midRateX96,
        uint24 protocolFee,
        uint24 lpFee
    ) internal pure returns (uint128) {
        uint128 midL = _sizeLiquidityWeighted(sp, sl, su, b0, b1, midRateX96, PIPS_DENOMINATOR);
        (uint256 a0m, uint256 a1m) = _getAmountsForLiquidity(sp, sl, su, midL);
        if (b0 > a0m) {
            // token0 is surplus -> the reconcile sells it zeroForOne -> discount its value by that direction's fee.
            uint256 feePips =
                ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.getZeroForOneFee(protocolFee), lpFee);
            uint256 rate0 = FullMath.mulDiv(midRateX96, PIPS_DENOMINATOR - feePips, PIPS_DENOMINATOR);
            return _sizeLiquidityWeighted(sp, sl, su, b0, b1, rate0, PIPS_DENOMINATOR);
        } else if (b1 > a1m) {
            // token1 is surplus -> the reconcile sells it oneForZero -> discount its weight by that direction's fee.
            uint256 feePips =
                ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.getOneForZeroFee(protocolFee), lpFee);
            return _sizeLiquidityWeighted(sp, sl, su, b0, b1, midRateX96, PIPS_DENOMINATOR - feePips);
        }
        return midL;
    }

    /// @dev Size L by value conservation: the budget's value must equal the value of a position of size L at
    ///      the current price, so L = REFERENCE_LIQUIDITY * value(budget) / value(reference position). Both
    ///      values are expressed in token1: token0 at `rate0X96` (token1 per token0, Q96) and token1 scaled by
    ///      `rate1Pips / 1e6`. The fee-aware caller discounts exactly one of the two — whichever side the
    ///      reconcile will sell — pricing in the swap fee that side will pay; the plain (mid) sizing passes the
    ///      undiscounted mid rate and 1e6.
    ///      Precision: the final division truncates at 1 part in value(reference), i.e. the sized L is exact to
    ///      well below 1 wei of either token for any realistic range, and truncation only under-sizes — the
    ///      safe direction (the leftover is swept back as dust).
    function _sizeLiquidityWeighted(
        uint160 sp,
        uint160 sl,
        uint160 su,
        uint256 b0,
        uint256 b1,
        uint256 rate0X96,
        uint256 rate1Pips
    ) internal pure returns (uint128) {
        (uint256 a0r, uint256 a1r) = _getAmountsForLiquidity(sp, sl, su, REFERENCE_LIQUIDITY);
        uint256 refValue =
            FullMath.mulDiv(a0r, rate0X96, FixedPoint96.Q96) + FullMath.mulDiv(a1r, rate1Pips, PIPS_DENOMINATOR);
        uint256 budgetValue =
            FullMath.mulDiv(b0, rate0X96, FixedPoint96.Q96) + FullMath.mulDiv(b1, rate1Pips, PIPS_DENOMINATOR);
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
    ///      is SETTLE_PAIR from this contract (standing Permit2 allowance / forwarded native value; a SWEEP
    ///      returns unused native wei). POSM's per-amount slippage limits are set to max: the single
    ///      `minLiquidity` floor checked after the trim is the operation's slippage gate.
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
            actions = abi.encodePacked(deployAction, uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            params = new bytes[](3);
            params[2] = abi.encode(c0, ActionConstants.MSG_SENDER);
        } else {
            actions = abi.encodePacked(deployAction, uint8(Actions.SETTLE_PAIR));
            params = new bytes[](2);
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
        params[1] = abi.encode(c0, cp.key.currency1);

        positionManager.modifyLiquiditiesWithoutUnlock{value: _nativeToForward(c0, amount0)}(actions, params);
    }

    /// @dev Native value to forward to POSM for a mint/increase: the required amount plus the rounding buffer,
    ///      clamped to what we actually hold — `_flashTakeDeficit` only sources the buffer wei when the need
    ///      strictly exceeds the budget, so on an exact match (e.g. amount0 == 0 for a range entirely below
    ///      spot) the buffer is not in the balance and must not be forwarded. POSM SWEEPs back any unused wei.
    function _nativeToForward(Currency c0, uint256 amount0) internal view returns (uint256 value) {
        if (!c0.isAddressZero()) return 0;
        value = amount0 + ROUNDING_BUFFER;
        uint256 held = address(this).balance;
        if (value > held) value = held;
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
        Currency c0 = cp.key.currency0;
        uint256 value = c0.isAddressZero() ? c0.balanceOfSelf() : 0;

        uint256 urBalanceBefore = address(universalRouter).balance;
        universalRouter.execute{value: value}(commands, inputs);
        if (address(universalRouter).balance > urBalanceBefore) {
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
    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal {
        poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
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
    function _pullBudget(PoolKey memory key, uint256 amount0In, uint256 amount1In) internal {
        uint256 expectedValue;
        Currency c0 = key.currency0;
        if (c0.isAddressZero()) {
            expectedValue = amount0In;
        } else if (amount0In > 0) {
            permit2.transferFrom(msg.sender, address(this), amount0In.toUint160(), Currency.unwrap(c0));
        }
        if (amount1In > 0) {
            permit2.transferFrom(msg.sender, address(this), amount1In.toUint160(), Currency.unwrap(key.currency1));
        }
        if (msg.value != expectedValue) revert InvalidEthValue();
    }

    /// @dev Pull the positive (add) rebalance deltas from the caller, before the unlock so msg.sender is still
    ///      the caller (mirrors `_pullBudget`). Negative deltas pull nothing here — they are returned to the
    ///      recipient inside the unlock (`_resolveBudget`) once the withdrawn amounts are known.
    function _pullAdditional(PoolKey memory key, int128 additionalA, int128 additionalB) internal {
        uint256 expectedValue;
        Currency c0 = key.currency0;
        if (additionalA > 0) {
            uint256 amount = uint256(uint128(additionalA));
            if (c0.isAddressZero()) expectedValue = amount;
            else permit2.transferFrom(msg.sender, address(this), uint160(amount), Currency.unwrap(c0));
        }
        if (additionalB > 0) {
            permit2.transferFrom(
                msg.sender, address(this), uint160(uint256(uint128(additionalB))), Currency.unwrap(key.currency1)
            );
        }
        if (msg.value != expectedValue) revert InvalidEthValue();
    }

    /// @dev First time a token is seen: max-approve it to Permit2 and grant standing max Permit2 allowances to
    ///      POSM and the UR — both only ever pull from their direct caller (this contract), which holds nothing
    ///      at rest (see the contract-level INVARIANT), so a standing allowance grants no more than the bounded
    ///      per-operation allowance it replaces while saving an allowance write on every subsequent operation.
    function _ensureApproved(Currency currency) internal {
        if (currency.isAddressZero()) return;
        address token = Currency.unwrap(currency);
        if (_tokenApproved[token]) return;
        _tokenApproved[token] = true;
        // safeApprove: tokens that return nothing (e.g. USDT) would revert a plain IERC20.approve on decode.
        SafeTransferLib.safeApprove(ERC20(token), address(permit2), type(uint256).max);
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
}
