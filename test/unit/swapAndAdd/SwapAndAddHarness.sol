// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {IUniversalRouter} from "../../../src/interfaces/external/IUniversalRouter.sol";
import {SwapAndAdd} from "../../../src/SwapAndAdd.sol";

/// @notice Test-only wrapper that exposes SwapAndAdd internals.
/// @dev Compiled with via_ir via `compilation_restrictions` in foundry.toml. Tests must deploy it
///      via `deployCode` and must not import this file (or they inherit the IR restriction).
contract SwapAndAddHarness is SwapAndAdd {
    using TransientStateLibrary for IPoolManager;

    /// @dev Sentinel so harness unlock payloads cannot collide with `abi.encode(CoreParams)`.
    bytes32 internal constant HARNESS_TAG = keccak256("SwapAndAddHarness");

    enum HarnessOp {
        DeployLiquidity,
        Reconcile,
        FlashTakeDeficit,
        Trim,
        SettleToward,
        TakeCredit,
        SwapAndAdd,
        Decrease
    }

    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        IPositionManager _positionManager,
        IUniversalRouter _universalRouter
    ) SwapAndAdd(_poolManager, _permit2, _positionManager, _universalRouter) {}

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        if (data.length >= 32) {
            bytes32 tag;
            assembly ("memory-safe") {
                tag := calldataload(data.offset)
            }
            if (tag == HARNESS_TAG) return _harnessUnlock(data);
        }
        return super._unlockCallback(data);
    }

    function _harnessUnlock(bytes calldata data) internal returns (bytes memory) {
        (, HarnessOp op, bytes memory payload) = abi.decode(data, (bytes32, HarnessOp, bytes));

        if (op == HarnessOp.DeployLiquidity) {
            (CoreParams memory cp, uint128 liquidity, uint256 amount0) =
                abi.decode(payload, (CoreParams, uint128, uint256));
            return abi.encode(_deployLiquidity(cp, liquidity, amount0));
        }
        if (op == HarnessOp.Reconcile) {
            (
                CoreParams memory cp,
                uint256 tokenId,
                uint128 lopt,
                uint256 a0opt,
                uint256 a1opt,
                uint160 sqrtLower,
                uint160 sqrtUpper,
                uint256 take0,
                uint256 take1,
                address take0To,
                address take1To
            ) = abi.decode(
                payload,
                (CoreParams, uint256, uint128, uint256, uint256, uint160, uint160, uint256, uint256, address, address)
            );
            if (take0 > 0) _take(cp.key.currency0, take0To, take0);
            if (take1 > 0) _take(cp.key.currency1, take1To, take1);
            uint128 trimmed = _reconcile(cp, tokenId, lopt, a0opt, a1opt, sqrtLower, sqrtUpper);
            return abi.encode(trimmed);
        }
        if (op == HarnessOp.FlashTakeDeficit) {
            (CoreParams memory cp, uint256 amount0, uint256 amount1) =
                abi.decode(payload, (CoreParams, uint256, uint256));
            _flashTakeDeficit(cp, amount0, amount1);
            int256 d0 = poolManager.currencyDelta(address(this), cp.key.currency0);
            int256 d1 = poolManager.currencyDelta(address(this), cp.key.currency1);
            // Close any flash debt so the unlock can succeed; the test already observed the take via balances.
            _settleToward(cp.key.currency0);
            _settleToward(cp.key.currency1);
            _takeCredit(cp.key.currency0);
            _takeCredit(cp.key.currency1);
            return abi.encode(d0, d1);
        }
        if (op == HarnessOp.Trim) {
            (
                CoreParams memory cp,
                uint256 tokenId,
                uint128 lopt,
                bool deficitIsCurrency1,
                uint256 amountOut,
                uint160 sqrtLower,
                uint160 sqrtUpper
            ) = abi.decode(payload, (CoreParams, uint256, uint128, bool, uint256, uint160, uint160));
            return abi.encode(_trim(cp, tokenId, lopt, deficitIsCurrency1, amountOut, sqrtLower, sqrtUpper));
        }
        if (op == HarnessOp.SettleToward) {
            (Currency currency, uint256 takeAmount, address takeTo) = abi.decode(payload, (Currency, uint256, address));
            if (takeAmount > 0) _take(currency, takeTo, takeAmount);
            int256 deltaBefore = poolManager.currencyDelta(address(this), currency);
            uint256 heldBefore = currency.balanceOfSelf();
            _settleToward(currency);
            int256 deltaAfter = poolManager.currencyDelta(address(this), currency);
            uint256 heldAfter = currency.balanceOfSelf();
            _settleToward(currency);
            _takeCredit(currency);
            return abi.encode(deltaBefore, deltaAfter, heldBefore, heldAfter);
        }
        if (op == HarnessOp.TakeCredit) {
            (Currency currency, bool createCredit) = abi.decode(payload, (Currency, bool));
            if (createCredit) {
                // Take to this contract then settle the same amount from a pre-funded extra, leaving a
                // positive credit equal to the extra. Tests fund `2 * amount` and we take `amount`.
                uint256 extra = currency.balanceOfSelf();
                if (extra > 0) {
                    _settle(currency, address(this), extra);
                }
            }
            int256 deltaBefore = poolManager.currencyDelta(address(this), currency);
            uint256 heldBefore = currency.balanceOfSelf();
            _takeCredit(currency);
            int256 deltaAfter = poolManager.currencyDelta(address(this), currency);
            uint256 heldAfter = currency.balanceOfSelf();
            _settleToward(currency);
            _takeCredit(currency);
            return abi.encode(deltaBefore, deltaAfter, heldBefore, heldAfter);
        }
        if (op == HarnessOp.SwapAndAdd) {
            CoreParams memory cp = abi.decode(payload, (CoreParams));
            (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = _swapAndAdd(cp);
            return abi.encode(tokenId, liquidity, amount0, amount1);
        }
        if (op == HarnessOp.Decrease) {
            (PoolKey memory key, uint256 tokenId, uint128 dl, bytes memory hookData) =
                abi.decode(payload, (PoolKey, uint256, uint128, bytes));
            _decrease(key, tokenId, dl, hookData);
            return "";
        }
        revert("SwapAndAddHarness: unknown op");
    }

    function _unlock(HarnessOp op, bytes memory payload) internal returns (bytes memory) {
        return poolManager.unlock(abi.encode(HARNESS_TAG, op, payload));
    }

    // ───────────────────────────────────────────── exposed internals ─────────────────────────────────────────────

    function exposedDeployLiquidity(CoreParams memory cp, uint128 liquidity, uint256 amount0)
        external
        payable
        returns (uint256 tokenId)
    {
        tokenId = abi.decode(_unlock(HarnessOp.DeployLiquidity, abi.encode(cp, liquidity, amount0)), (uint256));
    }

    function exposedReconcile(
        CoreParams memory cp,
        uint256 tokenId,
        uint128 lopt,
        uint256 a0opt,
        uint256 a1opt,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint256 take0,
        uint256 take1,
        address take0To,
        address take1To
    ) external payable returns (uint128 trimmed) {
        trimmed = abi.decode(
            _unlock(
                HarnessOp.Reconcile,
                abi.encode(cp, tokenId, lopt, a0opt, a1opt, sqrtLower, sqrtUpper, take0, take1, take0To, take1To)
            ),
            (uint128)
        );
    }

    function exposedFlashTakeDeficit(CoreParams memory cp, uint256 amount0, uint256 amount1)
        external
        payable
        returns (int256 delta0, int256 delta1)
    {
        (delta0, delta1) =
            abi.decode(_unlock(HarnessOp.FlashTakeDeficit, abi.encode(cp, amount0, amount1)), (int256, int256));
    }

    function exposedTrim(
        CoreParams memory cp,
        uint256 tokenId,
        uint128 lopt,
        bool deficitIsCurrency1,
        uint256 amountOut,
        uint160 sqrtLower,
        uint160 sqrtUpper
    ) external payable returns (uint128 dl) {
        dl = abi.decode(
            _unlock(HarnessOp.Trim, abi.encode(cp, tokenId, lopt, deficitIsCurrency1, amountOut, sqrtLower, sqrtUpper)),
            (uint128)
        );
    }

    function exposedSettleToward(Currency currency, uint256 takeAmount, address takeTo)
        external
        payable
        returns (int256 deltaBefore, int256 deltaAfter, uint256 heldBefore, uint256 heldAfter)
    {
        (deltaBefore, deltaAfter, heldBefore, heldAfter) = abi.decode(
            _unlock(HarnessOp.SettleToward, abi.encode(currency, takeAmount, takeTo)),
            (int256, int256, uint256, uint256)
        );
    }

    function exposedTakeCredit(Currency currency, bool createCredit)
        external
        payable
        returns (int256 deltaBefore, int256 deltaAfter, uint256 heldBefore, uint256 heldAfter)
    {
        (deltaBefore, deltaAfter, heldBefore, heldAfter) = abi.decode(
            _unlock(HarnessOp.TakeCredit, abi.encode(currency, createCredit)), (int256, int256, uint256, uint256)
        );
    }

    function exposedSwapAndAdd(CoreParams memory cp)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (tokenId, liquidity, amount0, amount1) =
            abi.decode(_unlock(HarnessOp.SwapAndAdd, abi.encode(cp)), (uint256, uint128, uint256, uint256));
    }

    function exposedDecrease(PoolKey memory key, uint256 tokenId, uint128 dl, bytes memory hookData) external payable {
        _unlock(HarnessOp.Decrease, abi.encode(key, tokenId, dl, hookData));
    }

    function exposedPlanLiquidity(CoreParams memory cp, uint160 sqrtLower, uint160 sqrtUpper)
        external
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        return _planLiquidity(cp, sqrtLower, sqrtUpper);
    }

    function exposedExecuteRoute(CoreParams memory cp) external payable {
        _executeRoute(cp);
    }

    function exposedPull(
        PoolKey memory key,
        uint256 amount0In,
        uint256 amount1In,
        ISwapAndAdd.TokenAmount[] calldata funding,
        bytes calldata route
    ) external payable {
        _pull(key, amount0In, amount1In, funding, route);
    }

    function exposedSweepFunding(ISwapAndAdd.TokenAmount[] calldata funding, address to) external {
        _sweepFunding(funding, to);
    }

    function exposedSweep(Currency currency, address to) external {
        _sweep(currency, to);
    }

    function exposedEnsureApproved(Currency currency) external {
        _ensureApproved(currency);
    }

    function exposedResolveBudget(Currency currency, int128 delta, address recipient)
        external
        returns (uint256 budget)
    {
        return _resolveBudget(currency, delta, recipient);
    }

    function exposedValidateRecipient(address recipient) external view {
        _validateRecipient(recipient);
    }

    function exposedAuthAndResolveRecipient(uint256 tokenId, address requested) external view returns (address) {
        return _authAndResolveRecipient(tokenId, requested);
    }

    function exposedBurnAndWithdraw(PoolKey memory key, uint256 tokenId, bytes calldata hookData) external {
        _burnAndWithdraw(key, tokenId, hookData);
    }
}
