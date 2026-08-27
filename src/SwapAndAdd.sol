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
/// @dev All entrypoints funnel into one PoolManager unlock:
///      route -> size -> flash-take deficit -> deploy -> reconcile and trim -> floor check -> sweep.
///      Rebalance burns the old position in POSM's own unlock first.
///
///      Invariant: all pulled and collected funds are deployed or swept within the transaction.
///      Only donations or undeclared route outputs can remain at rest.
contract SwapAndAdd is ISwapAndAdd, SafeCallback, DeltaResolver, Permit2Forwarder, Multicall_v4, ReentrancyLock {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    using SafeCast for uint256;
    using Hooks for IHooks;

    /// @dev Permissions that let a hook alter settlement deltas, which breaks the reconcile
    ///      accounting. Pools with any of them are rejected.
    uint160 private constant UNSUPPORTED_HOOK_FLAGS = Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    /// @dev Standing Permit2 allowance expiration timestamp.
    uint48 private constant ALLOWANCE_EXPIRATION = type(uint48).max;
    /// @dev Universal Router command to sweep unspent native ETH.
    uint8 private constant UR_SWEEP_COMMAND = 0x04;

    /// @dev Inputs for the shared unlock and execution core. A `deployTokenId` of 0 mints a new
    ///      position. A non-zero value increases that position in place.
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

        // the position was minted to this contract so the trim step could burn from it
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

        // positive deltas are pulled, negative deltas (cash-out) pull nothing
        _pull(
            key,
            params.additional0 > 0 ? uint256(uint128(params.additional0)) : 0,
            params.additional1 > 0 ? uint256(uint128(params.additional1)) : 0,
            params.routeFunding,
            params.route
        );

        // burn in POSM's own unlock and resolve the net budgets before the main unlock opens
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

        // accrued fees are collected inside the unlock callback
        _pull(cp.key, params.amount0In, params.amount1In, params.routeFunding, params.route);
        (, liquidityAdded, amount0, amount1) = _run(cp);
        emit Increased(recipient, params.tokenId, msg.sender, liquidityAdded, amount0, amount1);

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

        // compound is an increase where the collected fees are the entire budget
        CoreParams memory cp =
            _growCore(params.tokenId, params.route, params.minLiquidityAdded, recipient, params.hookData);
        (, liquidityAdded, amount0, amount1) = _run(cp);
        emit Compounded(recipient, params.tokenId, msg.sender, liquidityAdded, amount0, amount1);
    }

    /// @dev Shared CoreParams for grow-in-place operations. Budgets are set in the callback after
    ///      fee collection.
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

    /// @dev Collects fees for grow operations, then executes the shared core flow.
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        CoreParams memory cp = abi.decode(data, (CoreParams));

        // for grow operations, fees collected via a 0-liquidity decrease become the budget
        if (cp.deployTokenId != 0) {
            // POSM reverts on a decrease of an empty position
            if (positionManager.getPositionLiquidity(cp.deployTokenId) != 0) {
                _decrease(cp.key, cp.deployTokenId, 0, cp.hookData);
            }
            cp.budget0 = cp.key.currency0.balanceOfSelf();
            cp.budget1 = cp.key.currency1.balanceOfSelf();
            // a route can still source tokens, so only revert when there is also no route
            if (cp.budget0 == 0 && cp.budget1 == 0 && cp.route.length == 0) revert NoFeesToCompound();
        }

        (uint256 tokenId, uint128 liquidity, uint256 a0, uint256 a1) = _swapAndAdd(cp);
        return abi.encode(tokenId, liquidity, a0, a1);
    }

    /// @dev Resolves the redeploy budget from the signed delta. Negative deltas pay out cash-out
    ///      to the recipient.
    function _resolveBudget(Currency currency, int128 delta, address recipient) internal returns (uint256 budget) {
        uint256 held = currency.balanceOfSelf();
        if (delta >= 0) return held; // withdrawn tokens plus the pre-pulled additional budget

        // widen to int256 before negating to prevent overflow on type(int128).min
        uint256 toReturn = uint256(-int256(delta));
        if (toReturn > held) revert ReturnExceedsWithdrawn(toReturn, held);
        currency.transfer(recipient, toReturn);
        return held - toReturn;
    }

    /// @dev Shared execution core.
    function _swapAndAdd(CoreParams memory cp)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // pure bitmask check, the capability is rejected regardless of observed behavior
        if (cp.key.hooks.hasPermission(UNSUPPORTED_HOOK_FLAGS)) revert UnsupportedHookPermissions(cp.key.hooks);

        _ensureApproved(cp.key.currency0);
        _ensureApproved(cp.key.currency1);

        // 1. Execute the optional route and re-read the held budgets.
        if (cp.route.length != 0) {
            _executeRoute(cp);
            cp.budget0 = cp.key.currency0.balanceOfSelf();
            cp.budget1 = cp.key.currency1.balanceOfSelf();
        }

        // 2. Size the liquidity, flash-take any deficit, and deploy via POSM. The bounds are
        // constant, the price is re-read at each use because swaps and hooks move it.
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cp.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cp.tickUpper);
        (uint128 liquidityOptimistic, uint256 amount0optimistic, uint256 amount1optimistic) =
            _planLiquidity(cp, sqrtLower, sqrtUpper);
        // revert with the floor error instead of POSM's opaque CannotUpdateEmptyPosition
        if (liquidityOptimistic == 0 && cp.deployTokenId == 0) {
            revert InsufficientLiquidity(cp.minLiquidity, 0);
        }
        _flashTakeDeficit(cp, amount0optimistic, amount1optimistic);
        tokenId = _deployLiquidity(cp, liquidityOptimistic, amount0optimistic);

        // 3. Settle the flash-take debt, trimming the new liquidity if a debt remains.
        uint128 trimmed =
            _reconcile(cp, tokenId, liquidityOptimistic, amount0optimistic, amount1optimistic, sqrtLower, sqrtUpper);
        liquidity = liquidityOptimistic - trimmed;

        // 4. Enforce the slippage floor.
        if (liquidity < cp.minLiquidity) revert InsufficientLiquidity(cp.minLiquidity, liquidity);

        // 5. Compute the final position amounts and sweep dust.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(cp.key.toId());
        (amount0, amount1) = SwapAndAddMath.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
        _sweep(cp.key.currency0, cp.recipient);
        _sweep(cp.key.currency1, cp.recipient);
    }

    /// @dev Computes the fee-aware liquidity and required amounts from the budgets and pool price.
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

    /// @dev Flash-takes deficit tokens so the POSM deploy is fully funded. The rounded-up amounts
    ///      are wei-exact against POSM's pull. `_reconcile` settles the debt. The take requires the
    ///      PoolManager to hold enough of the token across all pools, or it reverts.
    function _flashTakeDeficit(CoreParams memory cp, uint256 amount0, uint256 amount1) internal {
        if (amount0 > cp.budget0) _take(cp.key.currency0, address(this), amount0 - cp.budget0);
        if (amount1 > cp.budget1) _take(cp.key.currency1, address(this), amount1 - cp.budget1);
    }

    /// @dev Settles the flash-take debt with held tokens, a same-pool swap, then a trim.
    /// @return trimmed The liquidity removed by the trim.
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
        if (a0opt > cp.budget0) deficitIsCurrency1 = false; // short token0
        else if (a1opt > cp.budget1) deficitIsCurrency1 = true; // short token1
        else return 0; // the budget covered the deploy, no swap or trim needed

        Currency deficit = deficitIsCurrency1 ? cp.key.currency1 : cp.key.currency0;
        Currency surplus = deficitIsCurrency1 ? cp.key.currency0 : cp.key.currency1;
        bool zeroForOne = deficitIsCurrency1; // sell the surplus to buy the deficit

        // 1. Settle with deficit tokens already held.
        _settleToward(deficit);

        // 2. If a debt remains, sell the surplus for the deficit token (exact input).
        int256 owed = poolManager.currencyDelta(address(this), deficit);
        if (owed < 0) {
            uint256 surplusBal = surplus.balanceOfSelf();
            if (surplusBal > 0) {
                _swap(cp.key, zeroForOne, -surplusBal.toInt256(), cp.hookData);
                _settleToward(surplus);
                owed = poolManager.currencyDelta(address(this), deficit);
            }
        }

        // 3. If price impact or fees left a residual deficit, trim the position to free tokens.
        if (owed < 0) {
            trimmed = _trim(cp, tokenId, lopt, deficitIsCurrency1, uint256(-owed), sqrtLower, sqrtUpper);
            _settleToward(deficit);
        }

        // 4. Take credits and defensively close both deltas.
        _takeCredit(deficit);
        _takeCredit(surplus);
        _settleToward(surplus);
    }

    /// @dev Frees deficit tokens by decreasing the new liquidity, capped at `lopt` so existing
    ///      principal is never touched. The price cannot be past the range's far side because the
    ///      reconcile swap's untaxed output repays the debt within the range.
    function _trim(
        CoreParams memory cp,
        uint256 tokenId,
        uint128 lopt,
        bool deficitIsCurrency1,
        uint256 amountOut,
        uint160 sqrtLower,
        uint160 sqrtUpper
    ) internal returns (uint128 dl) {
        // re-read the price, the reconcile swap or a hook moved it since sizing
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(cp.key.toId());
        uint256 liquidityToFree =
            SwapAndAddMath.getLiquidityToFree(sqrtPriceX96, sqrtLower, sqrtUpper, deficitIsCurrency1, amountOut);
        // cap the trim at the liquidity added in this transaction
        dl = liquidityToFree >= lopt ? lopt : uint128(liquidityToFree);
        _decrease(cp.key, tokenId, dl, cp.hookData);
    }

    /// @dev Deploys via POSM MINT_POSITION or INCREASE_LIQUIDITY, with CLOSE_CURRENCY on both
    ///      tokens so positive deltas credit instead of reverting SETTLE_PAIR. Per-amount slippage
    ///      limits are maxed, `minLiquidity` is the single slippage gate.
    function _deployLiquidity(CoreParams memory cp, uint128 liquidity, uint256 amount0)
        internal
        returns (uint256 tokenId)
    {
        bool isMint = cp.deployTokenId == 0;
        tokenId = isMint ? positionManager.nextTokenId() : cp.deployTokenId;

        uint8 deployAction = uint8(isMint ? Actions.MINT_POSITION : Actions.INCREASE_LIQUIDITY);
        bytes memory deployData = isMint
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

        // native pools carry a trailing SWEEP to return unconsumed wei of the forwarded ETH
        Currency c0 = cp.key.currency0;
        bool isNative = c0.isAddressZero();
        bytes memory actions = isNative
            ? abi.encodePacked(
                deployAction, uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.SWEEP)
            )
            : abi.encodePacked(deployAction, uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY));

        bytes[] memory params = new bytes[](isNative ? 4 : 3);
        params[0] = deployData;
        params[1] = abi.encode(c0);
        params[2] = abi.encode(cp.key.currency1);
        if (isNative) params[3] = abi.encode(c0, ActionConstants.MSG_SENDER);

        positionManager.modifyLiquiditiesWithoutUnlock{value: isNative ? amount0 : 0}(actions, params);
    }

    /// @dev Executes the Universal Router payload and reclaims unspent native ETH from the router.
    function _executeRoute(CoreParams memory cp) internal {
        (bytes memory commands, bytes[] memory inputs) = abi.decode(cp.route, (bytes, bytes[]));
        // the contract holds only this operation's native budget
        uint256 value = address(this).balance;

        universalRouter.execute{value: value}(commands, inputs);

        // router balances are permissionlessly sweepable, reclaim before anyone else can
        if (address(universalRouter).balance > 0) {
            bytes[] memory sweepInputs = new bytes[](1);
            sweepInputs[0] = abi.encode(address(0), ActionConstants.MSG_SENDER, 0);
            universalRouter.execute(abi.encodePacked(UR_SWEEP_COMMAND), sweepInputs);
        }
    }

    /// @dev Burns a position and takes both tokens. The max POSM deadline is inert, the entrypoint
    ///      already checked staleness.
    function _burnAndWithdraw(PoolKey memory key, uint256 tokenId, bytes calldata hookData) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), hookData);
        params[1] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        positionManager.modifyLiquidities(abi.encode(actions, params), type(uint256).max);
    }

    /// @dev Decreases liquidity and takes the tokens. A `dl` of 0 only collects fees.
    function _decrease(PoolKey memory key, uint256 tokenId, uint128 dl, bytes memory hookData) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(dl), uint128(0), uint128(0), hookData);
        params[1] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
    }

    /// @dev Swaps without a price limit. Max slippage is fine because callers enforce
    ///      `minLiquidity` on the final position. Callers MUST check minimum amounts.
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

    /// @dev Pays min(held, debt) toward the currency's outstanding debt, possibly partially.
    function _settleToward(Currency currency) internal {
        int256 d = poolManager.currencyDelta(address(this), currency);
        if (d >= 0) return;
        uint256 debt = uint256(-d);
        uint256 held = currency.balanceOfSelf();
        uint256 pay = held < debt ? held : debt;
        if (pay > 0) _settle(currency, address(this), pay);
    }

    /// @dev Takes any positive currency delta into this contract's balance.
    function _takeCredit(Currency currency) internal {
        int256 d = poolManager.currencyDelta(address(this), currency);
        if (d > 0) _take(currency, address(this), uint256(d));
    }

    /// @dev Pulls the caller's budgets and route funding via Permit2 or msg.value.
    function _pull(
        PoolKey memory key,
        uint256 amount0In,
        uint256 amount1In,
        TokenAmount[] calldata funding,
        bytes calldata route
    ) internal {
        uint256 expectedValue;

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

        // currency0 can be native or ERC-20, currency1 is always ERC-20
        Currency c0 = key.currency0;
        if (c0.isAddressZero()) {
            expectedValue += amount0In;
        } else if (amount0In > 0) {
            permit2.transferFrom(msg.sender, address(this), amount0In.toUint160(), Currency.unwrap(c0));
        }
        if (amount1In > 0) {
            permit2.transferFrom(msg.sender, address(this), amount1In.toUint160(), Currency.unwrap(key.currency1));
        }

        if (msg.value != expectedValue) revert InvalidEthValue();
        // in a multicall batch, an earlier subcall may have already spent the balance
        if (address(this).balance < expectedValue) revert InvalidEthValue();
    }

    /// @dev Sweeps unconsumed route funding tokens to the recipient.
    function _sweepFunding(TokenAmount[] calldata funding, address to) internal {
        for (uint256 i = 0; i < funding.length; i++) {
            _sweep(funding[i].token, to);
        }
    }

    /// @dev Grants standing max Permit2 allowances to POSM and the Universal Router. Safe because
    ///      the contract holds no funds at rest.
    function _ensureApproved(Currency currency) internal {
        if (currency.isAddressZero()) return;

        address token = Currency.unwrap(currency);
        // Permit2 never decrements a uint160.max allowance, so `permitted` doubles as the init marker
        (uint160 permitted,,) = permit2.allowance(address(this), token, address(positionManager));
        uint256 tokenAllowance = ERC20(token).allowance(address(this), address(permit2));
        if (permitted == type(uint160).max && tokenAllowance >= type(uint160).max) return;

        if (tokenAllowance != type(uint256).max) {
            // reset to 0 first for approve-race tokens like USDT
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

    /// @dev Verifies that the caller is the owner or an approved operator. Operator output is
    ///      forced to the owner, though operators remain trusted (see the interface notes).
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
