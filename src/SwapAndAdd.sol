// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
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

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
}

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
///           2. SIZE & MINT — size the position from those real holdings at the live price, fee-aware (the
///              residual same-pool swap will pay the pool fee, so discount the side it consumes), and mint to
///              this contract.
///           3. RECONCILE — a single same-pool swap funds whichever side the mint is short of (either
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
///         v4-only; ERC-20 + native ETH; add + rebalance. The position is minted to this contract (so it can
///         be trimmed) and transferred to the recipient after the unlock closes.
contract SwapAndAdd is ISwapAndAdd, SafeCallback, DeltaResolver, Permit2Forwarder, ReentrancyLock {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    using SafeCast for uint256;

    /// @dev Extra wei flash-taken / approved on the deficit side so POSM's round-up never under-funds the mint.
    uint256 private constant ROUNDING_BUFFER = 1;
    uint48 private constant ALLOWANCE_EXPIRATION = type(uint48).max;
    /// @dev v4 fees are expressed in pips (millionths).
    uint256 private constant PIPS_DENOMINATOR = 1e6;
    uint256 private constant OP_ADD = 0;
    uint256 private constant OP_REBALANCE = 1;
    uint256 private constant OP_COMPOUND = 2;

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

    mapping(address token => bool) private _permit2Approved;

    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        IPositionManager _positionManager,
        IUniversalRouter _universalRouter
    ) SafeCallback(_poolManager) Permit2Forwarder(_permit2) {
        positionManager = _positionManager;
        universalRouter = _universalRouter;
    }

    receive() external payable {}

    // ───────────────────────────────────────────── external entrypoints ─────────────────────────────────────────────

    /// @inheritdoc ISwapAndAdd
    function add(AddParams calldata params)
        external
        payable
        isNotLocked
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > params.deadline) revert DeadlinePassed(params.deadline);
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
        returns (uint256 newTokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > params.deadline) revert DeadlinePassed(params.deadline);
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(params.tokenId);
        _checkAuth(params.tokenId);
        // pull any positive (add) deltas here, where msg.sender is the caller (mirrors add()'s _pullBudget);
        // negative (return) deltas are handled inside the unlock once we know the withdrawn amounts.
        _pullAdditional(key, params.additionalA, params.additionalB);

        bytes memory result = poolManager.unlock(abi.encode(OP_REBALANCE, abi.encode(params, key)));
        (newTokenId, liquidity, amount0, amount1) = abi.decode(result, (uint256, uint128, uint256, uint256));
        IERC721Minimal(address(positionManager)).transferFrom(address(this), params.recipient, newTokenId);
    }

    /// @inheritdoc ISwapAndAdd
    function compound(CompoundParams calldata params)
        external
        isNotLocked
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > params.deadline) revert DeadlinePassed(params.deadline);
        _checkAuth(params.tokenId);
        bytes memory result = poolManager.unlock(abi.encode(OP_COMPOUND, abi.encode(params)));
        (liquidityAdded, amount0, amount1) = abi.decode(result, (uint128, uint256, uint256));
    }

    /// @dev Revert unless msg.sender is the position owner or an ERC-721 approved operator for it.
    function _checkAuth(uint256 tokenId) internal view {
        address owner = IERC721Minimal(address(positionManager)).ownerOf(tokenId);
        if (
            msg.sender != owner && IERC721Minimal(address(positionManager)).getApproved(tokenId) != msg.sender
                && !IERC721Minimal(address(positionManager)).isApprovedForAll(owner, msg.sender)
        ) revert NotAuthorizedForToken(tokenId);
    }

    // ───────────────────────────────────────────── unlock callback ─────────────────────────────────────────────

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (uint256 op, bytes memory inner) = abi.decode(data, (uint256, bytes));
        if (op == OP_COMPOUND) {
            (uint128 liq, uint256 a0, uint256 a1) = _compound(abi.decode(inner, (CompoundParams)));
            return abi.encode(liq, a0, a1);
        }

        CoreParams memory cp;
        if (op == OP_ADD) {
            AddParams memory p = abi.decode(inner, (AddParams));
            cp = CoreParams(
                p.poolKey, p.tickLower, p.tickUpper, p.amount0In, p.amount1In, p.route, p.minLiquidity, p.recipient, p.hookData
            );
        } else {
            (RebalanceParams memory p, PoolKey memory key) = abi.decode(inner, (RebalanceParams, PoolKey));
            cp = _prepareRebalance(p, key);
        }
        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = _addCore(cp);
        return abi.encode(tokenId, liq, a0, a1);
    }

    /// @dev Rebalance prep: burn the WHOLE position, then resolve each token's redeploy budget from the signed
    ///      delta — `withdrawn + additional`. Positive deltas were already pulled in `rebalance()` (so they sit in
    ///      this contract's balance); negative deltas are returned to the recipient HERE, before the add flow runs.
    ///      Returning the cash-out share up front is what keeps the accounting safe: the contract is then left
    ///      holding exactly the redeploy budget, so every `balanceOfSelf()` read in `_addCore` (the route, the
    ///      reconcile's sell-all, the mint settle) sees only what should be deployed — never the portion owed back.
    function _prepareRebalance(RebalanceParams memory p, PoolKey memory key) internal returns (CoreParams memory cp) {
        _withdraw(key, p.tokenId, p.hookData); // burn the full position; tokens land in this contract.

        uint256 budget0 = _resolveBudget(key.currency0, p.additionalA, p.recipient);
        uint256 budget1 = _resolveBudget(key.currency1, p.additionalB, p.recipient);

        cp = CoreParams(
            key, p.newTickLower, p.newTickUpper, budget0, budget1, p.route, p.minLiquidity, p.recipient, p.hookData
        );
    }

    /// @dev Resolve one token's redeploy budget from its signed delta. With a positive delta the additional units
    ///      were already pulled into this contract by `rebalance()`, so the held balance already equals
    ///      `withdrawn + additional` and is returned as-is. With a negative delta we return `|delta|` to the
    ///      recipient now (clamped: it may not exceed the withdrawn balance) and redeploy the remainder.
    function _resolveBudget(Currency currency, int128 delta, address recipient) internal returns (uint256 budget) {
        uint256 held = currency.balanceOfSelf();
        if (delta >= 0) return held; // withdrawn + (pre-pulled) additional
        uint256 toReturn = uint256(uint128(-delta));
        if (toReturn > held) revert ReturnExceedsWithdrawn(toReturn, held);
        currency.transfer(recipient, toReturn);
        return held - toReturn;
    }

    // ───────────────────────────────────────────── core flow ─────────────────────────────────────────────

    function _addCore(CoreParams memory cp)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // 1. ROUTE FIRST: run the verbatim route (best-execution, off-venue) to convert the surplus toward the
        //    deficit, then re-read balances — we now size from the *actual* holdings, not an estimate.
        if (cp.route.length != 0) {
            _routeSurplus(cp);
            cp.budget0 = cp.key.currency0.balanceOfSelf();
            cp.budget1 = cp.key.currency1.balanceOfSelf();
        }

        // 2. size the position from the holdings (fee-aware, optimistic) and mint it to this contract.
        (uint128 lopt, uint256 a0opt, uint256 a1opt) = _planMint(cp);
        tokenId = _executeMint(cp, lopt, a0opt, a1opt);

        // 3. reconcile any residual same-pool (in whichever direction is short) and trim to the exact funded size.
        uint128 trimmed = _reconcile(cp, tokenId, a0opt, a1opt);
        liquidity = lopt - trimmed;

        // 4. slippage floor — the single gate for the whole operation.
        if (liquidity < cp.minLiquidity) revert InsufficientLiquidity(uint128(cp.minLiquidity), liquidity);

        // 5. report the position's composition; sweep any leftover (small, in the input token) to the recipient.
        (amount0, amount1) = _positionAmounts(cp, liquidity);
        _sweep(cp.key.currency0, cp.recipient);
        _sweep(cp.key.currency1, cp.recipient);
    }

    /// @dev Size the position from the current holdings at the live price and mint it to this contract.
    ///      Sizing is fee-aware: the side that will be swapped same-pool in `_reconcile` is discounted by the
    ///      pool's total fee, so the optimistic mint isn't over-sized by a fee the trim would otherwise claw back.
    function _planMint(CoreParams memory cp)
        internal
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(cp.key.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cp.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cp.tickUpper);
        // mid price (token1 per token0, Q96): the value-conservation reference for sizing L from the budget.
        uint256 midRateX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        uint256 feePips = uint256(lpFee) + protocolFee; // v4 charges lpFee + protocolFee, both in pips.
        liquidity = _sizeFeeAware(sqrtPriceX96, sqrtLower, sqrtUpper, cp.budget0, cp.budget1, midRateX96, feePips);
        (amount0, amount1) = _getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
    }

    /// @dev Flash-`take` whichever side the optimistic mint is short of so the mint is fully funded up front,
    ///      then mint. After a route, the deficit is small (the route already delivered most of it), so the
    ///      take is small or zero.
    function _executeMint(CoreParams memory cp, uint128 liquidity, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId)
    {
        _flashTakeDeficit(cp, amount0, amount1);
        tokenId = _mint(cp, liquidity, amount0, amount1);
    }

    /// @dev Flash-`take` from the pool whatever the optimistic mint needs beyond the held budget, on each side,
    ///      so the subsequent mint/increase is fully funded; `_reconcile` later settles what the swap actually owes.
    function _flashTakeDeficit(CoreParams memory cp, uint256 amount0, uint256 amount1) internal {
        if (amount0 > cp.budget0) _take(cp.key.currency0, address(this), amount0 - cp.budget0 + ROUNDING_BUFFER);
        if (amount1 > cp.budget1) _take(cp.key.currency1, address(this), amount1 - cp.budget1 + ROUNDING_BUFFER);
    }

    /// @dev Compound: reinvest the position's accrued fees back into the SAME tokenId. Mirrors `_addCore` but with
    ///      no route (fees are tiny — same-pool only) and an INCREASE in place of a fresh MINT, so the existing NFT
    ///      just grows. Collect fees -> size from them (fee-aware) -> flash-take any deficit -> INCREASE ->
    ///      reconcile residual same-pool + trim -> floor -> sweep dust. The fees never leave to the wallet.
    function _compound(CompoundParams memory p)
        internal
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1)
    {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(p.tokenId);

        // 1. collect fees only: DECREASE by 0 liquidity credits the accrued fees, TAKE_PAIR pulls them here.
        _decrease(key, p.tokenId, 0, p.hookData);

        // budget = the collected fees; target the position's existing range; no route.
        CoreParams memory cp = CoreParams(
            key,
            info.tickLower(),
            info.tickUpper(),
            key.currency0.balanceOfSelf(),
            key.currency1.balanceOfSelf(),
            "",
            p.minLiquidityAdded,
            p.recipient,
            p.hookData
        );
        if (cp.budget0 == 0 && cp.budget1 == 0) revert NoFeesToCompound();

        // 2. size from the fees and INCREASE the same position (flash-taking any side the mint is short of).
        (uint128 lopt, uint256 a0opt, uint256 a1opt) = _planMint(cp);
        _flashTakeDeficit(cp, a0opt, a1opt);
        _increase(cp, p.tokenId, lopt, a0opt, a1opt);

        // 3. reconcile the small residual same-pool and trim; net liquidity added = lopt - trimmed.
        uint128 trimmed = _reconcile(cp, p.tokenId, a0opt, a1opt);
        liquidityAdded = lopt - trimmed;

        // 4. slippage floor on the liquidity actually added.
        if (liquidityAdded < cp.minLiquidity) revert InsufficientLiquidity(uint128(cp.minLiquidity), liquidityAdded);

        // 5. report the reinvested amounts; sweep any dust to the recipient (NFT stays with its owner).
        (amount0, amount1) = _positionAmounts(cp, liquidityAdded);
        _sweep(key.currency0, p.recipient);
        _sweep(key.currency1, p.recipient);
    }

    /// @dev Settle the position's funding using a single same-pool swap in whichever direction is short, then
    ///      trim the just-minted position by any remaining shortfall. The route already ran (in `_routeSurplus`),
    ///      so this is same-pool only. Bidirectional: if the route under-converted we still hold surplus and
    ///      swap surplus->deficit; if it over-converted we are short the other side and swap the other way.
    ///      Returns the liquidity removed by the trim (0 if the holdings already covered the optimistic mint).
    function _reconcile(CoreParams memory cp, uint256 tokenId, uint256 a0opt, uint256 a1opt)
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
            _swap(cp.key, zeroForOne, -int256(surplusBal));
            _settleToward(surplus);
        }

        // 3. whatever deficit is still owed (the genuine residual) -> free it by trimming the position.
        int256 owed = poolManager.currencyDelta(address(this), deficit);
        if (owed < 0) {
            trimmed = _trim(cp, tokenId, deficitIs1, uint256(-owed));
            _settleToward(deficit);
        }

        // 4. clean up: take any leftover deficit credit; sell a tiny rounding excess back so dust stays in surplus.
        _takeCredit(deficit);
        uint256 excessDeficit = deficit.balanceOfSelf();
        if (excessDeficit > ROUNDING_BUFFER) {
            _swap(cp.key, !zeroForOne, -int256(excessDeficit)); // deficit -> surplus exact-input
            _settleToward(deficit);
        }
        _takeCredit(surplus);
        _settleToward(surplus);
    }

    /// @dev DECREASE the position by enough liquidity to free at least `amountOut` of the deficit token.
    function _trim(CoreParams memory cp, uint256 tokenId, bool deficitIs1, uint256 amountOut)
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
        dl += 1; // DECREASE frees rounded-down amounts; bump up so the freed amount covers `amountOut`.
        uint128 cur = positionManager.getPositionLiquidity(tokenId);
        if (dl > cur) dl = cur;
        _decrease(cp.key, tokenId, dl, cp.hookData);
    }

    /// @dev Route-first pre-step: determine which side is the surplus relative to the target ratio (at mid),
    ///      then run the verbatim route from that side. The route is off-venue, so it does not move this pool.
    function _routeSurplus(CoreParams memory cp) internal {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(cp.key.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cp.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cp.tickUpper);
        uint256 midRateX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        uint128 lref = _sizeLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, cp.budget0, cp.budget1, midRateX96);
        (uint256 a0,) = _getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, lref);
        Currency surplus = cp.budget0 > a0 ? cp.key.currency0 : cp.key.currency1;
        _runRoute(cp.route, surplus);
    }

    // ───────────────────────────────────────────── sizing helpers ─────────────────────────────────────────────

    /// @dev Fee-aware sizing. First size at mid to find which side is the surplus (the side the same-pool
    ///      reconcile will swap), then re-size discounting that side's value by the pool fee, so we don't
    ///      over-mint by a fee the trim would otherwise have to claw back. If the holdings are already in
    ///      ratio (no swap needed) the mid size is returned unchanged.
    function _sizeFeeAware(
        uint160 sp,
        uint160 sl,
        uint160 su,
        uint256 b0,
        uint256 b1,
        uint256 midRateX96,
        uint256 feePips
    ) internal pure returns (uint128) {
        uint128 midL = _sizeLiquidity(sp, sl, su, b0, b1, midRateX96);
        (uint256 a0m, uint256 a1m) = _getAmountsForLiquidity(sp, sl, su, midL);
        if (b0 > a0m) {
            // token0 is surplus -> it gets swapped same-pool -> discount its value by the fee.
            uint256 rate0 = FullMath.mulDiv(midRateX96, PIPS_DENOMINATOR - feePips, PIPS_DENOMINATOR);
            return _sizeLiquidityWeighted(sp, sl, su, b0, b1, rate0, PIPS_DENOMINATOR);
        } else if (b1 > a1m) {
            // token1 is surplus -> discount its weight by the fee.
            return _sizeLiquidityWeighted(sp, sl, su, b0, b1, midRateX96, PIPS_DENOMINATOR - feePips);
        }
        return midL;
    }

    /// @dev L = lref * budgetValue / refValue, valuing both sides in token1 at `rateX96` (token1 per token0).
    function _sizeLiquidity(uint160 sp, uint160 sl, uint160 su, uint256 b0, uint256 b1, uint256 rateX96)
        internal
        pure
        returns (uint128)
    {
        return _sizeLiquidityWeighted(sp, sl, su, b0, b1, rateX96, PIPS_DENOMINATOR);
    }

    /// @dev As `_sizeLiquidity`, but token1's value is additionally scaled by `rate1Pips / 1e6` (used by
    ///      fee-aware sizing to discount whichever side is the surplus).
    function _sizeLiquidityWeighted(
        uint160 sp,
        uint160 sl,
        uint160 su,
        uint256 b0,
        uint256 b1,
        uint256 rate0X96,
        uint256 rate1Pips
    ) internal pure returns (uint128) {
        uint128 lref = 1e18;
        (uint256 a0r, uint256 a1r) = _getAmountsForLiquidity(sp, sl, su, lref);
        uint256 refValue =
            FullMath.mulDiv(a0r, rate0X96, FixedPoint96.Q96) + FullMath.mulDiv(a1r, rate1Pips, PIPS_DENOMINATOR);
        uint256 budgetValue =
            FullMath.mulDiv(b0, rate0X96, FixedPoint96.Q96) + FullMath.mulDiv(b1, rate1Pips, PIPS_DENOMINATOR);
        if (refValue == 0) return 0;
        return FullMath.mulDiv(uint256(lref), budgetValue, refValue).toUint128();
    }

    /// @dev token amounts required for `liquidity` at the given price/range, via SqrtPriceMath. Rounded UP to
    ///      mirror POSM's MINT_POSITION (which rounds the pull up, in the pool's favor): so the flash-take
    ///      decision in `_executeMint` sees the true required amount and the contract is never a wei short of
    ///      what POSM pulls. For sizing, rounding the reference up only shrinks L — the safe direction. The
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

    function _positionAmounts(CoreParams memory cp, uint128 liquidity)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(cp.key.toId());
        (amount0, amount1) = _getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(cp.tickLower), TickMath.getSqrtPriceAtTick(cp.tickUpper), liquidity
        );
    }

    // ───────────────────────────────────────────── POSM / pool actions ─────────────────────────────────────────────

    function _mint(CoreParams memory cp, uint128 liquidity, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId)
    {
        Currency c0 = cp.key.currency0;
        if (!c0.isAddressZero()) _approveSpender(c0, address(positionManager), amount0 + ROUNDING_BUFFER);
        if (!cp.key.currency1.isAddressZero()) {
            _approveSpender(cp.key.currency1, address(positionManager), amount1 + ROUNDING_BUFFER);
        }

        tokenId = positionManager.nextTokenId();
        uint256 nativeToForward = c0.isAddressZero() ? amount0 + ROUNDING_BUFFER : 0;

        (bytes memory actions, bytes[] memory params) = _buildMintParams(cp, liquidity);
        positionManager.modifyLiquiditiesWithoutUnlock{value: nativeToForward}(actions, params);
    }

    function _buildMintParams(CoreParams memory cp, uint128 liquidity)
        internal
        view
        returns (bytes memory actions, bytes[] memory params)
    {
        if (cp.key.currency0.isAddressZero()) {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            params = new bytes[](3);
            params[2] = abi.encode(cp.key.currency0, ActionConstants.MSG_SENDER);
        } else {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            params = new bytes[](2);
        }
        // mint to THIS contract so the position can be trimmed within the unlock; transferred to recipient after.
        params[0] = abi.encode(
            cp.key, cp.tickLower, cp.tickUpper, liquidity, type(uint128).max, type(uint128).max, address(this), cp.hookData
        );
        params[1] = abi.encode(cp.key.currency0, cp.key.currency1);
    }

    /// @dev INCREASE the liquidity of an existing position (the compound path). Mirrors `_mint`'s funding —
    ///      approve POSM for the ERC-20 sides / forward native — but adds to `tokenId` instead of minting anew.
    function _increase(CoreParams memory cp, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
        internal
    {
        Currency c0 = cp.key.currency0;
        if (!c0.isAddressZero()) _approveSpender(c0, address(positionManager), amount0 + ROUNDING_BUFFER);
        if (!cp.key.currency1.isAddressZero()) {
            _approveSpender(cp.key.currency1, address(positionManager), amount1 + ROUNDING_BUFFER);
        }
        uint256 nativeToForward = c0.isAddressZero() ? amount0 + ROUNDING_BUFFER : 0;

        (bytes memory actions, bytes[] memory params) = _buildIncreaseParams(cp, tokenId, liquidity);
        positionManager.modifyLiquiditiesWithoutUnlock{value: nativeToForward}(actions, params);
    }

    function _buildIncreaseParams(CoreParams memory cp, uint256 tokenId, uint128 liquidity)
        internal
        view
        returns (bytes memory actions, bytes[] memory params)
    {
        if (cp.key.currency0.isAddressZero()) {
            actions =
                abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            params = new bytes[](3);
            params[2] = abi.encode(cp.key.currency0, ActionConstants.MSG_SENDER);
        } else {
            actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
            params = new bytes[](2);
        }
        params[0] = abi.encode(tokenId, uint256(liquidity), type(uint128).max, type(uint128).max, cp.hookData);
        params[1] = abi.encode(cp.key.currency0, cp.key.currency1);
    }

    /// @dev Run the caller's verbatim Universal Router route. The route encodes its own (fixed) input amount; we
    ///      grant UR a bounded Permit2 allowance for the surplus (or forward native value) and call execute.
    function _runRoute(bytes memory route, Currency surplus) internal {
        (bytes memory commands, bytes[] memory inputs) = abi.decode(route, (bytes, bytes[]));
        uint256 value;
        if (surplus.isAddressZero()) {
            value = surplus.balanceOfSelf();
        } else {
            _approveSpender(surplus, address(universalRouter), surplus.balanceOfSelf());
        }
        universalRouter.execute{value: value}(commands, inputs);
    }

    /// @dev Burn the whole position and TAKE both tokens (+ fees) to this contract.
    function _withdraw(PoolKey memory key, uint256 tokenId, bytes memory hookData) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), hookData);
        params[1] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
    }

    /// @dev Pull the positive (add) rebalance deltas from the caller into this contract, before the unlock so
    ///      msg.sender is still the caller (mirrors `_pullBudget`): native via msg.value, ERC-20 via Permit2.
    ///      Negative deltas pull nothing here. currency1 is never native, so only currency0 can consume value.
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

    function _decrease(PoolKey memory key, uint256 tokenId, uint128 dl, bytes memory hookData) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(dl), uint128(0), uint128(0), hookData);
        params[1] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
    }

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

    function _pullBudget(PoolKey calldata key, uint256 amount0In, uint256 amount1In) internal {
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

    /// @dev One-time max ERC20 approval to Permit2, then a bounded per-call Permit2 allowance to `spender`.
    function _approveSpender(Currency currency, address spender, uint256 amount) internal {
        address token = Currency.unwrap(currency);
        if (!_permit2Approved[token]) {
            _permit2Approved[token] = true;
            IERC20Minimal(token).approve(address(permit2), type(uint256).max);
        }
        permit2.approve(token, spender, amount.toUint160(), ALLOWANCE_EXPIRATION);
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
