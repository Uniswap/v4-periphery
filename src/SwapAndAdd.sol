// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
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
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Actions} from "./libraries/Actions.sol";
import {ActionConstants} from "./libraries/ActionConstants.sol";
import {PositionInfo, PositionInfoLibrary} from "./libraries/PositionInfoLibrary.sol";
import {SwapAndAddMath} from "./libraries/SwapAndAddMath.sol";
import {Multicall_v4} from "./base/Multicall_v4.sol";
import {SafeCallback} from "./base/SafeCallback.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {Permit2Forwarder} from "./base/Permit2Forwarder.sol";
import {ReentrancyLock} from "./base/ReentrancyLock.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {ISwapAndAdd} from "./interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "./interfaces/external/IUniversalRouter.sol";

/// @title SwapAndAdd
/// @notice Implementation of the route-first liquidity zap for Uniswap v4.
/// @dev Entrypoints funnel into a single PoolManager unlock callback:
///      route -> size -> flash-take deficit -> deploy -> reconcile & trim -> floor check -> sweep dust.
///      Rebalance first burns the old position in POSM's own unlock so the main flow starts from resolved budgets.
///
///      Invariant: All pulled tokens, collected fees, and declared route funding are either deployed into
///      the position or swept to the recipient within the transaction. Only direct donations or unlisted route
///      outputs can remain at rest (which join subsequent pool budgets or can be claimed via zero-amount route
///      funding entries). Standing Permit2 allowances to POSM and Universal Router are safe because spenders only
///      pull during active calls initiated by this contract.
contract SwapAndAdd is ISwapAndAdd, SafeCallback, DeltaResolver, Permit2Forwarder, Multicall_v4, ReentrancyLock {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    using SafeCast for uint256;
    using Hooks for IHooks;

    /// @dev Hook permissions that let a hook alter this contract's settlement deltas, breaking the
    ///      conservation accounting the reconcile relies on. Pools carrying any of them are rejected.
    uint160 private constant UNSUPPORTED_HOOK_FLAGS = Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    /// @dev Standing Permit2 allowance expiration timestamp.
    uint48 private constant ALLOWANCE_EXPIRATION = type(uint48).max;
    /// @dev Universal Router command to sweep unspent native ETH.
    uint8 private constant UR_SWEEP_COMMAND = 0x04;

    /// @dev Internal bundle of inputs passed to the shared unlock and execution core.
    ///      `deployTokenId`: 0 mints a new position, non-zero increases that position in place.
    struct CoreParams {
        uint256 deployTokenId;
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
        if (address(_positionManager) == address(0)) revert ZeroAddress();
        if (address(_universalRouter) == address(0)) revert ZeroAddress();
        if (address(_permit2) == address(0)) revert ZeroAddress();
        if (address(_poolManager) == address(0)) revert ZeroAddress();

        positionManager = _positionManager;
        universalRouter = _universalRouter;
    }

    /// @dev Only accept native ETH from PoolManager, PositionManager, or Universal Router.
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
        _pull(params.poolKey, params.amount0In, params.amount1In, params.routeFunding, params.route);

        CoreParams memory cp = CoreParams({
            deployTokenId: 0, // Mints a new position
            key: params.poolKey,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            budget0: params.amount0In,
            budget1: params.amount1In,
            route: params.route,
            minLiquidity: params.minLiquidity,
            recipient: params.recipient,
            hookData: params.hookData
        });
        (tokenId, liquidity, amount0, amount1) = _run(cp);
        emit Added(params.recipient, tokenId, msg.sender, liquidity, amount0, amount1);

        // Position was minted to this contract so it could be trimmed; transfer it to recipient now.
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
        address recipient = _authAndResolveRecipient(params.tokenId, params.recipient);
        _validateRecipient(recipient);

        // Pull positive additional deltas from caller; negative deltas (cash-out) pull nothing here.
        _pull(
            key,
            params.additional0 > 0 ? uint256(uint128(params.additional0)) : 0,
            params.additional1 > 0 ? uint256(uint128(params.additional1)) : 0,
            params.routeFunding,
            params.route
        );

        // Burn the old position in POSM's own unlock, pay out any cash-out share up front,
        // and compute net redeploy budgets before opening the main unlock.
        _burnAndWithdraw(key, params.tokenId, params.hookData);
        CoreParams memory cp = CoreParams({
            deployTokenId: 0, // Mints a new position in the new range
            key: key,
            tickLower: params.newTickLower,
            tickUpper: params.newTickUpper,
            budget0: _resolveBudget(key.currency0, params.additional0, recipient),
            budget1: _resolveBudget(key.currency1, params.additional1, recipient),
            route: params.route,
            minLiquidity: params.minLiquidity,
            recipient: recipient,
            hookData: params.hookData
        });
        (newTokenId, liquidity, amount0, amount1) = _run(cp);
        emit Rebalanced(recipient, params.tokenId, newTokenId, msg.sender, liquidity, amount0, amount1);

        // Transfer newly minted position NFT and unconsumed route funding to recipient.
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
        address recipient = _authAndResolveRecipient(params.tokenId, params.recipient);
        _validateRecipient(recipient);
        CoreParams memory cp =
            _growCore(params.tokenId, params.route, params.minLiquidityAdded, recipient, params.hookData);

        // Pull caller's declared budget; accrued fees are collected inside the unlock callback.
        _pull(cp.key, params.amount0In, params.amount1In, params.routeFunding, params.route);
        (, liquidityAdded, amount0, amount1) = _run(cp);
        emit Increased(recipient, params.tokenId, msg.sender, liquidityAdded, amount0, amount1);

        // Position NFT stays in place; sweep unconsumed route funding to resolved recipient.
        _sweepFunding(params.routeFunding, recipient);
    }

    /// @inheritdoc ISwapAndAdd
    function compound(CompoundParams calldata params)
        external
        isNotLocked
        checkDeadline(params.deadline)
        returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1)
    {
        address recipient = _authAndResolveRecipient(params.tokenId, params.recipient);
        _validateRecipient(recipient);

        // Compound is an increase with 0 pulled budget: collected fees constitute the entire budget.
        CoreParams memory cp =
            _growCore(params.tokenId, params.route, params.minLiquidityAdded, recipient, params.hookData);
        (, liquidityAdded, amount0, amount1) = _run(cp);
        emit Compounded(recipient, params.tokenId, msg.sender, liquidityAdded, amount0, amount1);
    }

    /// @dev Shared CoreParams for grow-in-place operations (increase, compound).
    ///      Budgets are left zero and populated in the callback after collecting accrued fees.
    function _growCore(
        uint256 tokenId,
        bytes calldata route,
        uint256 minLiquidity,
        address recipient,
        bytes calldata hookData
    ) internal view returns (CoreParams memory cp) {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        cp = CoreParams({
            deployTokenId: tokenId,
            key: key,
            tickLower: info.tickLower(),
            tickUpper: info.tickUpper(),
            budget0: 0, // Populated after fee collection in callback
            budget1: 0, // Populated after fee collection in callback
            route: route,
            minLiquidity: minLiquidity,
            recipient: recipient,
            hookData: hookData
        });
    }

    /// @dev Executes the core logic inside a PoolManager unlock.
    function _run(CoreParams memory cp)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        bytes memory result = poolManager.unlock(abi.encode(cp));
        return abi.decode(result, (uint256, uint128, uint256, uint256));
    }

    // ───────────────────────────────────────────── unlock callback ─────────────────────────────────────────────

    /// @dev Unlock callback from PoolManager: collects fees for grow ops, then executes the shared core flow.
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        CoreParams memory cp = abi.decode(data, (CoreParams));

        // For grow ops (increase, compound): collect accrued fees via a 0-liquidity decrease first.
        // The held balance (collected fees + any pulled budget) becomes the redeploy budget.
        if (cp.deployTokenId != 0) {
            _decrease(cp.key, cp.deployTokenId, 0, cp.hookData);
            cp.budget0 = cp.key.currency0.balanceOfSelf();
            cp.budget1 = cp.key.currency1.balanceOfSelf();
            // Revert if there are neither held fees nor a route to source tokens.
            if (cp.budget0 == 0 && cp.budget1 == 0 && cp.route.length == 0) revert NoFeesToCompound();
        }

        (uint256 tokenId, uint128 liquidity, uint256 a0, uint256 a1) = _swapAndAdd(cp);
        return abi.encode(tokenId, liquidity, a0, a1);
    }

    /// @dev Resolves redeploy budget from signed delta: positive deltas add to budget, negative deltas return cash-out to recipient.
    function _resolveBudget(Currency currency, int128 delta, address recipient) internal returns (uint256 budget) {
        uint256 held = currency.balanceOfSelf();
        if (delta >= 0) return held; // Withdrawn tokens + pre-pulled additional budget

        // Widen to int256 before negating to prevent overflow on type(int128).min
        uint256 toReturn = uint256(-int256(delta));
        if (toReturn > held) revert ReturnExceedsWithdrawn(toReturn, held);
        currency.transfer(recipient, toReturn);
        return held - toReturn;
    }

    // ───────────────────────────────────────────── core flow ─────────────────────────────────────────────

    /// @dev Shared execution core: route -> size -> flash-take deficit -> deploy -> reconcile & trim -> floor check -> sweep.
    function _swapAndAdd(CoreParams memory cp)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // Pure bitmask on the hook address; a benignly-behaving hook with the permission is still rejected —
        // the boundary is the capability, not observed behavior.
        if (cp.key.hooks.hasPermission(UNSUPPORTED_HOOK_FLAGS)) revert UnsupportedHookPermissions(cp.key.hooks);

        _ensureApproved(cp.key.currency0);
        _ensureApproved(cp.key.currency1);

        // 1. ROUTE FIRST: Execute off-chain route (if provided) and update held token budgets from live balances.
        if (cp.route.length != 0) {
            _executeRoute(cp);
            cp.budget0 = cp.key.currency0.balanceOfSelf();
            cp.budget1 = cp.key.currency1.balanceOfSelf();
        }

        // 2. Sizing: Compute optimistic liquidity, flash-take any deficit, and deploy via POSM.
        // Range bounds are constant for the whole operation and threaded; the live price is re-read at
        // each use instead (the reconcile swap and hook callbacks can move it).
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cp.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cp.tickUpper);
        (uint128 liquidityOptimistic, uint256 amount0optimistic, uint256 amount1optimistic) =
            _planLiquidity(cp, sqrtLower, sqrtUpper);
        // Surface contract's own floor error rather than POSM's opaque CannotUpdateEmptyPosition on 0-sized mint.
        if (liquidityOptimistic == 0 && cp.deployTokenId == 0) {
            revert InsufficientLiquidity(cp.minLiquidity, 0);
        }
        _flashTakeDeficit(cp, amount0optimistic, amount1optimistic);
        tokenId = _deployLiquidity(cp, liquidityOptimistic, amount0optimistic);

        // 3. Reconcile & Trim: Reconcile deficit via same-pool swap and trim newly added liquidity for any remaining debt.
        uint128 trimmed =
            _reconcile(cp, tokenId, liquidityOptimistic, amount0optimistic, amount1optimistic, sqrtLower, sqrtUpper);
        liquidity = liquidityOptimistic - trimmed;

        // 4. Slippage Floor: Enforce minimum liquidity threshold on final post-trim position.
        if (liquidity < cp.minLiquidity) revert InsufficientLiquidity(cp.minLiquidity, liquidity);

        // 5. Sweep: Calculate final position token amounts at live price and sweep leftover dust to recipient.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(cp.key.toId());
        (amount0, amount1) = SwapAndAddMath.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
        _sweep(cp.key.currency0, cp.recipient);
        _sweep(cp.key.currency1, cp.recipient);
    }

    /// @dev Computes fee-aware optimistic liquidity and required token amounts based on held budgets and pool price.
    function _planLiquidity(CoreParams memory cp, uint160 sqrtLower, uint160 sqrtUpper)
        internal
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(cp.key.toId());
        if (sqrtPriceX96 == 0) revert IPoolManager.PoolNotInitialized();
        liquidity = SwapAndAddMath.getLiquidityFeeAware(
            sqrtPriceX96, sqrtLower, sqrtUpper, cp.budget0, cp.budget1, protocolFee, lpFee
        );
        (amount0, amount1) = SwapAndAddMath.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
    }

    /// @dev Flash-takes deficit tokens from PoolManager so the subsequent POSM deploy is fully funded.
    ///      `SwapAndAddMath.getAmountsForLiquidity` rounds up with the pool's own math on pool inputs, making funding wei-exact
    ///      with no rounding buffer needed. Requires PoolManager to hold sufficient aggregate reserves of that
    ///      token across all pools. `_reconcile` settles what the take owes afterwards.
    function _flashTakeDeficit(CoreParams memory cp, uint256 amount0, uint256 amount1) internal {
        if (amount0 > cp.budget0) _take(cp.key.currency0, address(this), amount0 - cp.budget0);
        if (amount1 > cp.budget1) _take(cp.key.currency1, address(this), amount1 - cp.budget1);
    }

    /// @dev Settles flash-take debt using held tokens, same-pool swaps, and partial liquidity trimming.
    ///      Bidirectional: handles both under-conversion (selling surplus token) and over-conversion.
    /// @return trimmed The amount of liquidity removed by trimming (0 if budget covered deploy).
    function _reconcile(
        CoreParams memory cp,
        uint256 tokenId,
        uint128 lopt,
        uint256 a0opt,
        uint256 a1opt,
        uint160 sqrtLower,
        uint160 sqrtUpper
    ) internal returns (uint128 trimmed) {
        bool deficitIsCurrency1;
        if (a0opt > cp.budget0) deficitIsCurrency1 = false; // Short token0
        else if (a1opt > cp.budget1) deficitIsCurrency1 = true; // Short token1
        else return 0; // Holdings already covered deploy; no swap or trim needed.

        Currency deficit = deficitIsCurrency1 ? cp.key.currency1 : cp.key.currency0;
        Currency surplus = deficitIsCurrency1 ? cp.key.currency0 : cp.key.currency1;
        bool zeroForOne = deficitIsCurrency1; // Sell surplus to buy deficit

        // 1. Settle debt using any deficit tokens already held (e.g. fee credits or sweep returns).
        _settleToward(deficit);

        // 2. If debt remains, convert remaining surplus to deficit in the pool (exact-input).
        int256 owed = poolManager.currencyDelta(address(this), deficit);
        if (owed < 0) {
            uint256 surplusBal = surplus.balanceOfSelf();
            if (surplusBal > 0) {
                _swap(cp.key, zeroForOne, -surplusBal.toInt256(), cp.hookData);
                _settleToward(surplus);
                owed = poolManager.currencyDelta(address(this), deficit);
            }
        }

        // 3. If residual deficit remains (due to price impact or fees), trim the position to free tokens.
        if (owed < 0) {
            trimmed = _trim(cp, tokenId, lopt, deficitIsCurrency1, uint256(-owed), sqrtLower, sqrtUpper);
            _settleToward(deficit);
        }

        // 4. Take positive delta credits into balance and close deltas.
        // Leftovers are swept as-is (trimming in-range frees both tokens, so two-token dust is normal).
        _takeCredit(deficit);
        // Defensive closure: ensure both currency deltas are zero past this line (surplus debt was cleared in step 2).
        _takeCredit(surplus);
        _settleToward(surplus);
    }

    /// @dev Decreases newly added liquidity to free enough deficit tokens to settle outstanding debt.
    ///      Caps removal at `lopt` so that on increase/compound, existing position principal is never touched.
    ///      Invariant: Price cannot be past the range's far side (reconcile swap's exact-input sell repays debt
    ///      before or at exhausting the range because v4 fees charge input; untaxed output covers debt).
    function _trim(
        CoreParams memory cp,
        uint256 tokenId,
        uint128 lopt,
        bool deficitIsCurrency1,
        uint256 amountOut,
        uint160 sqrtLower,
        uint160 sqrtUpper
    ) internal returns (uint128 dl) {
        // Fresh price read: the reconcile swap (or a hook) moved the price since sizing.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(cp.key.toId());
        uint256 liquidityToFree =
            SwapAndAddMath.getLiquidityToFree(sqrtPriceX96, sqrtLower, sqrtUpper, deficitIsCurrency1, amountOut);
        // Cap trim at the liquidity added in this transaction.
        dl = liquidityToFree >= lopt ? lopt : uint128(liquidityToFree);
        _decrease(cp.key, tokenId, dl, cp.hookData);
    }

    // ───────────────────────────────────────────── POSM / pool actions ─────────────────────────────────────────────

    /// @dev Deploys liquidity via POSM (MINT for new position, INCREASE for existing).
    ///      Uses CLOSE_CURRENCY on both tokens so positive deltas (e.g. fee credits from hooks or routes
    ///      trading this pool) are credited to balance rather than reverting SETTLE_PAIR.
    ///      POSM per-amount slippage limits are maxed because `minLiquidity` on the final post-trim position is the single slippage gate.
    function _deployLiquidity(CoreParams memory cp, uint128 liquidity, uint256 amount0)
        internal
        returns (uint256 tokenId)
    {
        bool isMint = cp.deployTokenId == 0;
        tokenId = isMint ? positionManager.nextTokenId() : cp.deployTokenId;

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

        // Forward native ETH if currency0 is native; POSM's SWEEP returns any unused wei.
        uint256 nativeToForward = c0.isAddressZero() ? amount0 : 0;
        positionManager.modifyLiquiditiesWithoutUnlock{value: nativeToForward}(actions, params);
    }

    /// @dev Executes the Universal Router payload and reclaims any unspent native ETH from the router.
    function _executeRoute(CoreParams memory cp) internal {
        (bytes memory commands, bytes[] memory inputs) = abi.decode(cp.route, (bytes, bytes[]));
        // Forward entire native balance (holds only this operation's native budget / funding).
        uint256 value = address(this).balance;

        universalRouter.execute{value: value}(commands, inputs);

        // Reclaim any unspent native ETH left in Universal Router (UR balances are permissionlessly sweepable).
        if (address(universalRouter).balance > 0) {
            bytes[] memory sweepInputs = new bytes[](1);
            sweepInputs[0] = abi.encode(address(0), ActionConstants.MSG_SENDER, 0);
            universalRouter.execute(abi.encodePacked(UR_SWEEP_COMMAND), sweepInputs);
        }
    }

    /// @dev Burns an existing position and takes both tokens to this contract.
    ///      POSM `modifyLiquidities` is passed `type(uint256).max` deadline because staleness is already checked by entrypoint modifier.
    function _burnAndWithdraw(PoolKey memory key, uint256 tokenId, bytes calldata hookData) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), hookData);
        params[1] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        positionManager.modifyLiquidities(abi.encode(actions, params), type(uint256).max);
    }

    /// @dev Decreases position liquidity (or collects fees when dl == 0) and takes tokens to this contract.
    function _decrease(PoolKey memory key, uint256 tokenId, uint128 dl, bytes memory hookData) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(dl), uint128(0), uint128(0), hookData);
        params[1] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
    }

    /// @dev Executes a same-pool swap to convert surplus tokens to deficit without price limits.
    ///      Unbounded because `minLiquidity` is the slippage gate and input amount is strictly bounded by held holdings.
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

    /// @dev Settles outstanding debt for a currency using held balance.
    function _settleToward(Currency currency) internal {
        int256 d = poolManager.currencyDelta(address(this), currency);
        if (d >= 0) return;
        uint256 debt = uint256(-d);
        uint256 held = currency.balanceOfSelf();
        uint256 pay = held < debt ? held : debt;
        if (pay > 0) _settle(currency, address(this), pay);
    }

    /// @dev Takes positive currency delta credits from PoolManager into this contract's balance.
    function _takeCredit(Currency currency) internal {
        int256 d = poolManager.currencyDelta(address(this), currency);
        if (d > 0) _take(currency, address(this), uint256(d));
    }

    /// @dev Pulls caller budgets and route funding via Permit2/msg.value, validating single native ETH accounting.
    function _pull(
        PoolKey memory key,
        uint256 amount0In,
        uint256 amount1In,
        TokenAmount[] calldata funding,
        bytes calldata route
    ) internal {
        uint256 expectedValue;

        // Pull route funding tokens (non-pool tokens dedicated to the off-chain route).
        if (funding.length != 0) {
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

        // Pull pool-token budget: currency0 can be native or ERC-20; currency1 is always ERC-20.
        Currency c0 = key.currency0;
        if (c0.isAddressZero()) {
            expectedValue += amount0In;
        } else if (amount0In > 0) {
            permit2.transferFrom(msg.sender, address(this), amount0In.toUint160(), Currency.unwrap(c0));
        }
        if (amount1In > 0) {
            permit2.transferFrom(msg.sender, address(this), amount1In.toUint160(), Currency.unwrap(key.currency1));
        }

        // Validate msg.value: exactly one native contribution (pool budget OR route funding) is allowed.
        if (msg.value != expectedValue) revert InvalidEthValue();
        // In multicall batches, verify balance was not already spent by an earlier subcall.
        if (address(this).balance < expectedValue) revert InvalidEthValue();
    }

    /// @dev Sweeps unconsumed route funding tokens to the resolved recipient.
    function _sweepFunding(TokenAmount[] calldata funding, address to) internal {
        for (uint256 i = 0; i < funding.length; i++) {
            _sweep(funding[i].token, to);
        }
    }

    /// @dev Grants standing max Permit2 allowances to POSM and Universal Router if not already configured.
    ///      Safe because the contract holds no funds at rest and spenders only pull during active calls from `this`.
    function _ensureApproved(Currency currency) internal {
        if (currency.isAddressZero()) return;

        address token = Currency.unwrap(currency);
        // Permit2 never decrements a uint160.max allowance, so `permitted` doubles as the init marker; the
        // uint160.max headroom check on the token allowance heals tokens that decrement infinite approvals.
        (uint160 permitted,,) = permit2.allowance(address(this), token, address(positionManager));
        uint256 tokenAllowance = ERC20(token).allowance(address(this), address(permit2));
        if (permitted == type(uint160).max && tokenAllowance >= type(uint160).max) return;

        if (tokenAllowance != type(uint256).max) {
            // Reset to 0 first for approve-race tokens like USDT.
            if (tokenAllowance != 0) SafeTransferLib.safeApprove(ERC20(token), address(permit2), 0);
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
    function _pay(Currency currency, address, uint256 amount) internal override {
        currency.transfer(address(poolManager), amount);
    }

    /// @dev Validates that recipient is neither address(0) nor this contract.
    function _validateRecipient(address recipient) internal view {
        if (recipient == address(this) || recipient == address(0)) revert InvalidRecipient(recipient);
    }

    /// @dev Verifies caller authorization (owner or approved operator) and resolves recipient.
    ///      For approved operators, all output is forced to the position owner to prevent value redirection.
    function _authAndResolveRecipient(uint256 tokenId, address requested) internal view returns (address) {
        ERC721 posm = ERC721(address(positionManager));
        address owner = posm.ownerOf(tokenId);
        if (msg.sender == owner) return requested;
        if (posm.getApproved(tokenId) != msg.sender && !posm.isApprovedForAll(owner, msg.sender)) {
            revert NotAuthorizedForToken(tokenId);
        }
        return owner;
    }
}
