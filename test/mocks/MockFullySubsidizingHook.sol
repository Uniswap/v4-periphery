// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @notice A hook that pays some or all of an exact-output swap's input cost out of its own balance.
///         At the default full subsidy the swapper is left with the requested positive output and a
///         delta of exactly zero on the input currency.
/// @dev Unlike `DeltaReturningHook`, which returns a preset amount, this absorbs a share of whatever
///      the pool actually charged. That is the only way to land the swapper's input delta on exactly
///      zero, which is the state `V4Router` must tolerate. Requires AFTER_SWAP_FLAG and
///      AFTER_SWAP_RETURNS_DELTA_FLAG. Fund the hook with the input currency before swapping.
///
///      EXACT OUTPUT ONLY. The afterSwap return delta applies to the UNSPECIFIED currency, which is
///      the input side only for exact output. On an exact-input swap it would land on the output
///      instead, so this reverts rather than misreporting which side it funded.
contract MockFullySubsidizingHook is BaseTestHooks {
    using CurrencySettler for Currency;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    IPoolManager public immutable manager;

    /// @notice Share of the swapper's input this hook pays. 10_000 is the full cost; above that
    ///         over-funds and leaves the swapper a credit.
    uint256 public subsidyBps = BPS_DENOMINATOR;

    /// @notice Additional wei paid beyond `subsidyBps`, for exercising the boundary precisely.
    uint128 public extraWei;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(manager), "not manager");
        _;
    }

    function setSubsidyBps(uint256 _subsidyBps) external {
        subsidyBps = _subsidyBps;
    }

    function setExtraWei(uint128 _extraWei) external {
        extraWei = _extraWei;
    }

    function afterSwap(
        address, /* sender */
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata /* hookData */
    )
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        require(params.amountSpecified > 0, "exact output only");

        // for exact output the unspecified currency is the input side, which is the side the
        // afterSwap return delta applies to
        (Currency inputCurrency, int128 swapperInput) =
            params.zeroForOne ? (key.currency0, delta.amount0()) : (key.currency1, delta.amount1());

        uint256 fullInput = swapperInput < 0 ? uint256(uint128(-swapperInput)) : 0;
        uint256 owed = fullInput * subsidyBps / BPS_DENOMINATOR + extraWei;
        require(owed <= uint256(uint128(type(int128).max)), "subsidy overflows int128");

        // PoolManager applies `swapDelta = swapDelta - hookDelta`, so a negative hook delta moves that
        // much of the debt off the swapper and onto this hook, which settles it here. Paying the full
        // input zeroes the swapper's side; paying more leaves them a credit.
        if (owed != 0) inputCurrency.settle(manager, address(this), owed, false);

        return (IHooks.afterSwap.selector, -int128(int256(owed)));
    }
}
