// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Actions} from "./libraries/Actions.sol";
import {ActionConstants} from "./libraries/ActionConstants.sol";
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
}

/// @title SwapAndAdd (V1)
/// @notice See ISwapAndAdd. Mint-first single-mint zap: size L on-chain, flash-take the deficit, mint to the
///         user, source the deficit (verbatim UR route + same-pool reconcile), settle, sweep leftover (in the
///         input token only). v4-only; ERC-20 + native ETH; add + rebalance. No threshold dust-deploy (V2).
contract SwapAndAdd is ISwapAndAdd, SafeCallback, DeltaResolver, Permit2Forwarder, ReentrancyLock {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    /// @dev Extra wei flash-taken on the deficit side so POSM's round-up never under-funds the mint.
    uint256 private constant ROUNDING_BUFFER = 1;
    uint48 private constant ALLOWANCE_EXPIRATION = type(uint48).max;
    uint256 private constant OP_ADD = 0;
    uint256 private constant OP_REBALANCE = 1;

    /// @dev internal, stack-friendly bundle of the shared add inputs (budget already held by this contract).
    struct CoreParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 budget0;
        uint256 budget1;
        bytes route;
        uint256 swapRateX96;
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
    }

    /// @inheritdoc ISwapAndAdd
    function rebalance(RebalanceParams calldata params)
        external
        payable
        isNotLocked
        returns (uint256 newTokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > params.deadline) revert DeadlinePassed(params.deadline);
        address owner = IERC721Minimal(address(positionManager)).ownerOf(params.tokenId);
        if (
            msg.sender != owner && IERC721Minimal(address(positionManager)).getApproved(params.tokenId) != msg.sender
                && !IERC721Minimal(address(positionManager)).isApprovedForAll(owner, msg.sender)
        ) revert NotAuthorizedForToken(params.tokenId);

        bytes memory result = poolManager.unlock(abi.encode(OP_REBALANCE, abi.encode(params)));
        (newTokenId, liquidity, amount0, amount1) = abi.decode(result, (uint256, uint128, uint256, uint256));
    }

    // ───────────────────────────────────────────── unlock callback ─────────────────────────────────────────────

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (uint256 op, bytes memory inner) = abi.decode(data, (uint256, bytes));
        CoreParams memory cp;
        if (op == OP_ADD) {
            AddParams memory p = abi.decode(inner, (AddParams));
            cp = CoreParams(
                p.poolKey, p.tickLower, p.tickUpper, p.amount0In, p.amount1In, p.route, p.swapRateX96, p.minLiquidity, p.recipient, p.hookData
            );
        } else {
            cp = _prepareRebalance(abi.decode(inner, (RebalanceParams)));
        }
        (uint256 tokenId, uint128 liq, uint256 a0, uint256 a1) = _addCore(cp);
        return abi.encode(tokenId, liq, a0, a1);
    }

    /// @dev Withdraw the moved liquidity and assemble the add inputs for the new range.
    function _prepareRebalance(RebalanceParams memory p) internal returns (CoreParams memory cp) {
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(p.tokenId);
        bool full = p.liquidityToMove >= positionManager.getPositionLiquidity(p.tokenId);
        _withdraw(key, p.tokenId, p.liquidityToMove, full, p.hookData);
        cp = CoreParams(
            key,
            p.newTickLower,
            p.newTickUpper,
            key.currency0.balanceOfSelf(),
            key.currency1.balanceOfSelf(),
            p.route,
            p.swapRateX96,
            p.minLiquidity,
            p.recipient,
            p.hookData
        );
    }

    // ───────────────────────────────────────────── core flow ─────────────────────────────────────────────

    function _addCore(CoreParams memory cp)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (liquidity, amount0, amount1) = _planMint(cp);
        if (liquidity < cp.minLiquidity) revert InsufficientLiquidity(uint128(cp.minLiquidity), liquidity);

        tokenId = _executeMint(cp, liquidity, amount0, amount1);

        _repayDeficit(cp.key, cp.route);

        _sweep(cp.key.currency0, cp.recipient);
        _sweep(cp.key.currency1, cp.recipient);
    }

    function _planMint(CoreParams memory cp) internal view returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(cp.key.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cp.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cp.tickUpper);
        liquidity = _sizeLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, cp.budget0, cp.budget1, cp.swapRateX96);
        (amount0, amount1) = _getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
    }

    function _executeMint(CoreParams memory cp, uint128 liquidity, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId)
    {
        Currency c0 = cp.key.currency0;
        Currency c1 = cp.key.currency1;
        if (amount0 > cp.budget0) _take(c0, address(this), amount0 - cp.budget0 + ROUNDING_BUFFER);
        if (amount1 > cp.budget1) _take(c1, address(this), amount1 - cp.budget1 + ROUNDING_BUFFER);
        tokenId = _mintToUser(cp, liquidity, amount0, amount1);
    }

    // ───────────────────────────────────────────── helpers ─────────────────────────────────────────────

    /// @dev L = L_ref * budgetValue / refValue, valuing both in token1 units at `rateX96` (token1 per token0).
    function _sizeLiquidity(uint160 sqrtPriceX96, uint160 sqrtLower, uint160 sqrtUpper, uint256 b0, uint256 b1, uint256 rateX96)
        internal
        pure
        returns (uint128)
    {
        uint128 lref = 1e18;
        (uint256 a0r, uint256 a1r) = _getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, lref);
        uint256 refValue = FullMath.mulDiv(a0r, rateX96, FixedPoint96.Q96) + a1r;
        uint256 budgetValue = FullMath.mulDiv(b0, rateX96, FixedPoint96.Q96) + b1;
        if (refValue == 0) return 0;
        return FullMath.mulDiv(uint256(lref), budgetValue, refValue).toUint128();
    }

    /// @dev token amounts required for `liquidity` at the given price/range (rounded down), via SqrtPriceMath.
    function _getAmountsForLiquidity(uint160 sqrtPriceX96, uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        if (sqrtPriceX96 <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtPriceX96 < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        }
    }

    function _mintToUser(CoreParams memory cp, uint128 liquidity, uint256 amount0, uint256 amount1)
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
        pure
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
        params[0] = abi.encode(
            cp.key, cp.tickLower, cp.tickUpper, liquidity, type(uint128).max, type(uint128).max, cp.recipient, cp.hookData
        );
        params[1] = abi.encode(cp.key.currency0, cp.key.currency1);
    }

    /// @dev Source the still-owed deficit (from the flash-take) and settle, keeping leftover in the input token.
    function _repayDeficit(PoolKey memory key, bytes memory route) internal {
        Currency c0 = key.currency0;
        Currency c1 = key.currency1;
        uint256 owed0 = _getFullDebt(c0);
        uint256 owed1 = _getFullDebt(c1);
        if (owed0 > 0) {
            _sourceAndSettle(key, c1, c0, false, owed0, route); // surplus c1 -> deficit c0
        } else if (owed1 > 0) {
            _sourceAndSettle(key, c0, c1, true, owed1, route); // surplus c0 -> deficit c1
        }
    }

    /// @dev Acquire `owed` of `deficit` by swapping `surplus`: verbatim route (bulk) then a same-pool exact-out
    ///      reconcile for any shortfall. Excess deficit is sold back to surplus so dust lands only in surplus.
    function _sourceAndSettle(PoolKey memory key, Currency surplus, Currency deficit, bool zeroForOne, uint256 owed, bytes memory route)
        internal
    {
        // 1. bulk via verbatim route: yields real `deficit` tokens. Settle them to pay down the delta debt.
        if (route.length != 0) {
            _runRoute(route, surplus);
            uint256 real = deficit.balanceOfSelf();
            if (real > 0) {
                uint256 toSettle = real < owed ? real : owed;
                _settle(deficit, address(this), toSettle);
                owed -= toSettle;
            }
        }

        // 2. same-pool exact-output for the remaining debt: credits delta[deficit] directly (no settle).
        if (owed > 0) _swap(key, zeroForOne, int256(owed));

        // 3. pay the surplus the same-pool swap consumed.
        uint256 surplusOwed = _getFullDebt(surplus);
        if (surplusOwed > 0) _settle(surplus, address(this), surplusOwed);

        // 4. meaningful leftover deficit (route over-delivery) -> sell back so dust stays in the input token.
        uint256 excess = deficit.balanceOfSelf();
        if (excess > ROUNDING_BUFFER) {
            _swap(key, !zeroForOne, -int256(excess)); // exact-input: deficit -> surplus
            uint256 deficitOwed = _getFullDebt(deficit);
            if (deficitOwed > 0) _settle(deficit, address(this), deficitOwed);
            uint256 surplusCredit = _getFullCredit(surplus);
            if (surplusCredit > 0) _take(surplus, address(this), surplusCredit);
        }
    }

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

    function _withdraw(PoolKey memory key, uint256 tokenId, uint128 liquidityToMove, bool full, bytes memory hookData) internal {
        bytes memory actions;
        bytes[] memory params = new bytes[](2);
        if (full) {
            actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
            params[0] = abi.encode(tokenId, uint128(0), uint128(0), hookData);
        } else {
            actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
            params[0] = abi.encode(tokenId, uint256(liquidityToMove), uint128(0), uint128(0), hookData);
        }
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
