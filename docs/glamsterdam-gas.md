# Gas behavior on Ethereum mainnet after Glamsterdam

The deployed contracts do not change. Their gas use on Ethereum mainnet changes after the Glamsterdam activation (EIP-7773). This page covers the contracts in this repository that forward a fixed amount of gas to code that other parties write, and the quoter gas estimate. Other chains keep their current gas rules until they adopt the same changes.

The numbers on this page use the EIP values at the time of writing. They can change if the EIPs change before activation.

## What changes

- EIP-8037 adds state gas. A new storage slot costs 97,920 state gas. A new account costs 183,600 state gas.
- State gas comes from a reservoir. The reservoir is the part of the transaction gas limit above 16,777,216 (2^24). The reservoir is passed in full to every child call, independent of the gas limit of that call.
- In a transaction with a gas limit of 2^24 or less, the reservoir starts empty. State gas then comes from the regular gas of the frame that creates the state. A call with a fixed gas limit pays for the state it creates out of that fixed gas limit.
- A frame that reverts returns its state gas. When a transaction clears a slot that was zero at the start of the transaction, the state gas of that slot is returned. If an earlier frame created the slot, the returned state gas goes to the reservoir and can pay for later state creation, also in a transaction with a gas limit of 2^24 or less.
- The `GAS` opcode (`gasleft()`) returns regular gas only. It does not include the reservoir.
- EIP-8038 increases the cost of cold state access. Calls that write no new state also use more gas.

A write to a new storage slot inside a fixed-gas call costs about 110,000 gas in total (97,920 state gas plus the execution cost). Before the activation, the same write costs about 22,100 gas.

## Subscribers (`Notifier`)

`PositionManager` calls the subscriber of a position in four places. The gas rules are different for each callback.

| Callback | Gas given to the subscriber | Result when the callback fails |
| --- | --- | --- |
| `notifySubscribe` | All available gas (63/64 of the remaining gas) | The subscribe reverts. |
| `notifyUnsubscribe` | Fixed at `unsubscribeGasLimit` | The failure is caught. The unsubscribe succeeds. The subscriber does not see the notification. |
| `notifyModifyLiquidity` | All available gas (63/64 of the remaining gas) | The liquidity change reverts. |
| `notifyBurn` | All available gas (63/64 of the remaining gas) | The burn reverts. |

The `PositionManager` on Ethereum mainnet (`0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e`) has `unsubscribeGasLimit` 150,000.

Measured on a fork of Ethereum mainnet with the deployed `PositionManager` and a test subscriber. `notifyUnsubscribe` writes the given number of new storage slots. The transaction gas limit is 3,000,000.

| New slots in `notifyUnsubscribe` | Gas used by the callback before the activation | After the activation | Callback completes after the activation |
| --- | ---: | ---: | --- |
| 0 | 12,562 | 26,962 | yes |
| 1 | 34,970 | 137,290 | yes |
| 2 | 57,375 | 150,000 (out of gas) | no |
| 3 | 79,780 | 150,000 (out of gas) | no |

After the activation, a `notifyUnsubscribe` that writes two or more new storage slots runs out of gas in a transaction with a gas limit of 2^24 or less. The unsubscribe still succeeds. Any state that the subscriber updates in the callback is not updated.

In a transaction with a gas limit above 2^24, the callback takes its state gas from the reservoir. With a gas limit of 2^24 + 8,000,000, the callbacks with two and three new slots completed on reth and Geth. Erigon gave the same result for two new slots.

`notifySubscribe`, `notifyModifyLiquidity` and `notifyBurn` receive all available gas. They become more expensive. If the transaction gas limit is too low for the callback, the callback runs out of gas and the operation reverts with the notification error. With five new slots in `notifyModifyLiquidity`, the callback used 124,706 gas before the activation and 578,706 gas after the activation. Wallets and routers that set a fixed gas limit for liquidity changes on positions with a subscriber must include the subscriber cost.

Recommendations for subscriber authors:

- Do not write new storage slots in `notifyUnsubscribe`. Write to slots that already hold a nonzero value, or do the bookkeeping in a later call.
- Do not rely on `notifyUnsubscribe` to complete. A subscriber that must track unsubscribes can check `subscriber(tokenId)` on the `PositionManager`.
- Expect `notifySubscribe`, `notifyModifyLiquidity` and `notifyBurn` to cost more. A revert in these callbacks reverts the user operation.

## `PermissionedPositionManager` unwind

`unwindPosition` delivers each currency in a separate `PoolManager.unlock` call with the gas limit `DELIVERY_GAS_LIMIT`. For a currency with a verified permissions adapter, a failed delivery to the LP is followed by a delivery attempt to the adapter owner (the admin). If that also fails, the admin receives the ERC-6909 claim. For a currency without a verified adapter, such as native ETH, there is no admin attempt, and the LP receives the claim. Each leg emits `CurrencyUnwound`. `asClaim` is `true` only when the claim was transferred.

The `PermissionedPositionManager` on Ethereum mainnet (`0xd7be746b6b29f6185a01013e944313e1704c971f`) has `DELIVERY_GAS_LIMIT` 500,000. At block 26,256,554 it had no positions (`nextTokenId` 1). The measurement below therefore uses the deployed `PermissionedPositionManager`, `PermissionsAdapterFactory`, `PermissionedHooks` and `PoolManager` on a fork of Ethereum mainnet, with a test permissioned token. The pool is native ETH against the adapter of the test token. The test token can write extra new storage slots in each transfer, to show the effect of a heavier token. The transaction gas limit is 3,000,000.

| Case | Before the activation | After the activation |
| --- | ---: | ---: |
| ETH leg, gas used in the capped call | 20,639 | 23,539 |
| Token leg, LP already holds the token | 69,371 | 88,871 |
| Token leg, LP holds none of the token | 86,471 | 88,871 |
| Unwind transaction, LP already holds the token | 262,647 | 304,967 |
| Unwind transaction, LP holds none of the token | 276,327 | 383,303 |

In the measured unwind, the first new slot inside a delivery leg did not count against `DELIVERY_GAS_LIMIT`. The leg burns the ERC-6909 claim of the `PermissionedPositionManager`. In the measurement that claim balance was zero at the start of the transaction and was created by the burn step of the same transaction. EIP-8037 therefore returns its state gas to the reservoir, and the reservoir pays for one new slot. If the `PermissionedPositionManager` already holds a claim of that currency at the start of the transaction, the burn returns no state gas, and every new slot in the leg counts against the limit at about 110,000 gas. The full cost of every new slot is still part of the transaction gas.

Results for a token whose transfer writes extra new storage slots:

| Extra new slots per transfer | LP already holds the token | LP holds none of the token |
| --- | --- | --- |
| 0 to 3 | Delivered to the LP | Delivered to the LP |
| 4 | Delivered to the LP | LP delivery fails. The admin receives the token, `asClaim` is `false`. |
| 5 or more | Both deliveries fail. The admin receives the claim, `asClaim` is `true`. | Both deliveries fail. The admin receives the claim, `asClaim` is `true`. |

Before the activation, the same token fell back to the claim only at 18 extra new slots per transfer.

After the activation, a successful unwind receipt does not show that the LP received the underlying token. Read the `CurrencyUnwound` events. The `recipient` field and the `asClaim` field show where each currency went.

In a transaction with a gas limit above 2^24, the delivery takes its state gas from the reservoir. With a gas limit of 2^24 + 8,000,000, every case in the table (up to 12 extra new slots) delivered the token to the LP on reth and Geth. Erigon gave the same result for 4 and 5 extra new slots.

Recommendations for issuers and admins:

- Check that the permissioned token transfer creates few new storage slots for a new holder. Each new slot costs about 110,000 of the 500,000 delivery gas. Do not count on the one slot that the claim refill paid for in the measurement.
- To force-exit a position whose token transfer is expensive, send `unwindPosition` with a gas limit above 2^24. Leave a reservoir that covers all new slots of both deliveries.

## `V4Quoter` gas estimate

The quote functions measure `gasleft()` before and after a `PoolManager.unlock` call that always reverts. The revert returns all state gas of the simulated swap. `gasleft()` also never includes the reservoir. The `gasEstimate` therefore never includes state gas.

The estimate still increases after the activation because of the other repricing EIPs. Measured on a fork of Ethereum mainnet:

| Route | `gasEstimate` before the activation | After the activation |
| --- | ---: | ---: |
| Hookless V4 pool, USDC to USDT | 42,068 | 64,068 |
| V4 pool with a CurveNG wrapper hook | 206,201 | 285,001 |
| V4 pool with a FluidDexT1 wrapper hook | 237,269 | 310,269 |

`gasEstimate` includes the execution cost of the work inside the simulated swap, which can include token transfers inside hooks. It does not include state gas, the intrinsic gas, or the work of the real transaction outside the swap, such as settling the input and taking the output. Examples of state that a real swap can create are a balance slot for a first-time holder of the output token (97,920 state gas) and native ETH sent to a new account (183,600 state gas). Integrators that build a gas limit from `gasEstimate` must add these costs, or estimate the full transaction with `eth_estimateGas` on a node that runs the new rules.

## Method

The subscriber and unwind rows come from mined transactions on a patched anvil (revm 43.0.3, Amsterdam gas parameters) that forks Ethereum mainnet at block 26,256,554. Each Amsterdam transaction was replayed with `eth_simulateV1` on Sepolia reth and Geth nodes (and a subset on Erigon), with the prestate of the transaction as state overrides. For gas limits of 2^24 or less, the gas used and the events matched the anvil receipts. The patched anvil does not split the reservoir from regular gas, so the rows above 2^24 come from the real clients only. The quoter rows come from earlier measurements with the same patched anvil at block 26,128,135.
