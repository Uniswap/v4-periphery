# Uniswap v4 Margin Trading — Protocol & Integration Guide

A periphery that lets a user open a leveraged spot position in a single transaction by composing a
Uniswap v4 swap with a borrow/supply against an external lending protocol. Four venues are integrated
today (Morpho Blue, Aave v3, Aave v4, and Compound v3), all behind the same router; the caller selects
the venue per call by passing the matching adapter. This document explains how the system works and how
to integrate with it from both smart contracts and a front end.

---

## 1. Overview

A "margin" position is leveraged spot exposure:

1. Borrow the **debt** token from the lending protocol.
2. Swap the **debt** token into the **collateral** token (exact-output).
3. Supply the collateral (your equity plus the bought amount) to the lending protocol.

The sequence runs inside one `PoolManager` unlock using v4 flash accounting, which lets us swap debt tokens we don't have yet for the collateral we'll use to borrow it. The result is a position that is **long the collateral token and short the debt token**, at a leverage chosen by the caller and bounded only by the maximum LTV of the chosen market.

The swap itself routes through the **Universal Router** (the `ROUTE_SWAP` action), so liquidity can be sourced across v2, v3, and v4 rather than a single v4 pool. Because the Universal Router self-settles its own swap, the router wraps the call in a flash-take envelope: it flash-takes the input from the PoolManager, funds the Universal Router to spend exactly what the swap costs (a scoped Permit2 allowance = `maxDebtIn`/`maxCollateralIn`), and settles only this call's unspent flash-take (a pre-existing balance on the router is left untouched, never swept into the settle) — leaving the same net delta a native v4 swap would, so the surrounding borrow/supply/settle are unchanged. You supply the route: `increasePosition`/`decreasePosition` take the Universal Router `routeCommands`/`routeInputs` you build off-chain (see §6.5), and the router only requires that the route delivers the bought output to your account (enforced by `ASSERT_ACCOUNT_BALANCE`) and stays within the `maxDebtIn`/`maxCollateralIn` cap — it does not trust the route's internals. The Universal Router is supplied per call - in `IncreaseParams`/`DecreaseParams` for the curated flows, and as the first field of the `ROUTE_SWAP` action for `execute` plans - rather than fixed at deployment; it must be non-zero on the swap path (the call reverts `UniversalRouterNotSet` otherwise) and must carry already-unlocked `V4_SWAP` support (a Universal Router built after PR #491). Because the Universal Router is a per-call argument, different calls can point at different Universal Router deployments, so callers can adopt an improved or newer Universal Router over time without redeploying the margin router.

Each user's position lives in their own **`MarginAccount`** — a minimal, soulbound contract that is
itself the borrower/supplier in the lending protocol. The **`MarginRouter`** orchestrates the flows
and is the trusted manager of every account it deploys. A **lending adapter** (`MorphoLendingAdapter`
for Morpho Blue, `AaveLendingAdapter` for Aave v3, `AaveV4LendingAdapter` for Aave v4,
`CompoundV3LendingAdapter` for Compound v3) translates protocol-agnostic intents into the concrete
calls the account executes. All implement the same `ILendingAdapter` surface, so the router flows are
identical regardless of venue.

---

## 2. Architecture

```
   User / EOA / integrating contract
        │  increasePosition · decreasePosition · addCollateral · execute
        ▼
  ┌─────────────────┐  unlock + exact-out swap   ┌────────────────────┐
  │  MarginRouter   │ ─────────────────────────▶ │  v4 PoolManager    │
  │ (manager of all │  equity pull (Permit2)     ├────────────────────┤
  │  accounts;      │ ─────────────────────────▶ │  Permit2 · WETH9   │
  │  governance)    │  supply/borrow/repay/...   └────────────────────┘
  └───────┬─────────┘
          │ drives primitives (router is the manager)
          ▼
  ┌─────────────────┐   encode* (view)    ┌────────────────────┐
  │ MarginAccount   │ ──────────────────▶ │  LendingAdapter    │
  │ (per-user clone,│  self-call          │  (governed market  │
  │  soulbound)     │ ──────────────────▶ │   routing table)   │
  └───────┬─────────┘  onBehalf = account └──────────┬─────────┘
          │                                          │ reads + oracle price
          ▼                                          ▼
  ┌────  Morpho Blue / Aave v3 Pool / Aave v4 Spoke / Compound v3 Comet  ────┐
```


| Contract               | Role                                                                                                                                                                                                                                         |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MarginRouter`         | The entry point. Builds and runs each flow inside a `PoolManager` unlock. Inherits `V4Router`, `ReentrancyLock`, `Permit2Forwarder`, `Multicall_v4`, `NativeWrapper`, and the account factory. The router is the `manager` of every account. |
| `MarginAccount`        | A per-user clone (Solady clone-with-immutable-args). It is the lending counterparty (`onBehalf == account`), so it acts as itself and needs no delegated authorization. Owner and manager are baked into bytecode (soulbound).               |
| lending adapters       | Singleton encoders over a governed `(collateral, debt)` routing table. `MorphoLendingAdapter` targets Morpho Blue; `AaveLendingAdapter` targets the Aave v3 Pool; `AaveV4LendingAdapter` targets a single Aave v4 Spoke; `CompoundV3LendingAdapter` targets a single Compound v3 Comet (its base token is the only borrowable debt). Each returns the `(target, value, callData)` an account executes and holds no funds. The caller picks a venue by passing the matching adapter. |
| `ILendingAdapter`      | The protocol-agnostic surface the router and account depend on. New lending protocols are supported by new adapters.                                                                                                                         |
| value types            | `Market` (the `(collateral, debt)` pair), `Ltv` (WAD ratio), `MarketRegistry`, `Owner`.                                                                                                                      |


---

## 3. Core concepts

### 3.1 Markets and direction

A position is described by a `Market`:

```solidity
struct Market {
    Currency collateral; // supplied to the lending market
    Currency debt;       // borrowed from the lending market
}
```

**Direction is set entirely by the pairing.** You are long the collateral and short the debt. There
is no separate long/short flag — the two are the same information:


| Goal               | Market                                 | Resulting position  |
| ------------------ | -------------------------------------- | ------------------- |
| Long WETH vs USDC  | `Market(collateral: WETH, debt: USDC)` | hold WETH, owe USDC |
| Short WETH vs USDC | `Market(collateral: USDC, debt: WETH)` | hold USDC, owe WETH |


The swap mechanic is identical in both cases (borrow debt, buy collateral, supply collateral); only
which token sits in `collateral` vs `debt` differs. `Currency` is the v4 currency type
(`Currency.wrap(tokenAddress)`); native ETH is `Currency.wrap(address(0))`, but margin markets are
ERC-20 only (use WETH).

Which venue serves a pairing depends on which markets each protocol lists:

- **Long ETH** is `Market(collateral: WETH, debt: USDC)`. It is available on Morpho today and also
works on Aave v3 and Aave v4.
- **Short ETH** is `Market(collateral: USDC, debt: WETH)`. It is served by Aave v3 and Aave v4 today;
no Morpho market exists for this pairing on mainnet. See §8 for the venue-selection and short-ETH
walkthrough.
- **Long UNI** is `Market(collateral: UNI, debt: USDC)`, served by Compound v3. A Comet borrows only
its single base token, so the Compound adapter's debt is always USDC (the cUSDCv3 base) and its
collateral is any Comet collateral asset (UNI here).

### 3.2 The MarginAccount

- **One account per `(owner, subId)`.** `subId` is a caller-chosen index so one address can hold many
independent positions. The address is deterministic: `router.accountOf(owner, subId)` returns it
whether or not it has been deployed yet.
- **One Aave position per account.** Aave (v3, and a given v4 Spoke) tracks health and reserve
balances across the whole account, not per `(collateral, debt)` pair, so each Aave position must live
in its own `(owner, subId)` account: open a second Aave market under a *new* `subId`, never the same
one. The router does not enforce this. Re-using a `subId` for two markets on the same Aave deployment
blends their collateral/debt and can make a later `decreasePosition` (partial or full close) revert or
withdraw collateral still backing the other debt. Morpho markets are isolated and not subject to this.
- **Soulbound.** The owner and the manager (the router) are baked into the clone's bytecode at
deployment. There is no initializer and no transfer path.
- **Self-custody with a manager.** The account's fund-moving primitives (`supplyCollateral`,
`withdrawCollateral`, `borrow`, `repay`, `sweep`) are callable only by the **manager (router)** or
the **owner**. Recipients of withdrawals/borrows/sweeps are constrained to the manager or owner, so
funds can never be redirected to a third party.
- **Owner escape hatch.** `execute(adapter, callData)` is owner-only and forwards a call to the
adapter's lending protocol as the account. This lets the owner always manage or exit a position
directly on the lending protocol without the router (for example if the router is paused or an
adapter is removed).

### 3.3 Lending adapter and the allowlist

The adapter is an **encoder**: each `encode`* returns `(target, value, callData)`, and the account
performs the call as itself with a regular call (never a delegatecall). The target is the adapter's
declared `lendingProtocol()`. The encode surface is `encodeSupplyCollateral`,
`encodeEnableCollateral` (run by the account immediately after every supply, for venues that need an
explicit collateral enable; empty `callData` is the skip signal), `encodeWithdrawCollateral`,
`encodeBorrow`, and `encodeRepay` — an adapter implementation must provide all five, or
`supplyCollateral` reverts when the account consults the missing hook. An allowlisted adapter is trusted (see §9); the account's durable
guarantees are that it acts as its own `onBehalf` and constrains every fund recipient to the owner or
manager. Governance maintains an **allowlist** of adapters. The allowlist gates only the operations
that *add* exposure — `increasePosition`, `addCollateral` (and, under `execute`, `ACCOUNT_SUPPLY_COLLATERAL`
/ `ACCOUNT_BORROW`). **Closing and delevering never require an allowlisted adapter**, so a position can
always be unwound even if its adapter is later removed.

### 3.4 Leverage and LTV

Leverage is expressed through the swap sizing, not a separate parameter. For equity `E` (in collateral
units) and target leverage `L`:

```
totalCollateral = E * L
collateralToBuy  = totalCollateral - E = E * (L - 1)
debtBorrowed    ≈ collateralToBuy priced in the debt token
```

Because both legs are valued at the lending market's oracle price, the resulting loan-to-value is
approximately price-independent in token-ratio terms:

```
LTV ≈ collateralToBuy / totalCollateral = (L - 1) / L
```

So 2x ≈ 50% LTV, 3x ≈ 67% LTV, 4x ≈ 75% LTV. The lending market enforces its own maximum
(liquidation LTV, `maxLtvWad`) at borrow time, so an open that would exceed it reverts. Both flows
also accept a caller-supplied `maxLtvAfter` bound on the resulting LTV, asserted after the position
settles: it is optional on `increasePosition` (zero skips the check, so callers relying only on
`maxDebtIn` are unaffected) and mandatory on a partial `decreasePosition`. A supplied (non-zero)
bound must be able to bind — strictly below `1e18` (100%); a value at or above 100% can never be
exceeded by a real LTV, so it would silently disable the check and is rejected with `IneffectiveLtvBound`.
Because an open sizes on the pool while liquidation uses the venue oracle, `maxLtvAfter` lets a caller bound leverage by
health, not just by swap input, so adverse inclusion cannot land a fresh position near the
liquidation LTV. `Ltv` is a WAD value (`1e18 == 100%`).

### 3.5 Equity: Permit2 vs native ETH

Equity (the collateral you contribute) can be provided two ways:

- **ERC-20 via Permit2.** The router pulls `equity` collateral from the caller through Permit2. The
caller must (1) approve Permit2 to spend the token (`ERC20.approve(PERMIT2, ...)`, once per token)
and (2) grant the router an allowance in Permit2 (`Permit2.approve(token, router, amount, expiration)`,
or a signed `PermitSingle` forwarded through the router). See §6.2 and §7.2.
- **Native ETH.** Send `msg.value` with the call; the router wraps it to WETH and credits the account.
The market collateral must be WETH (`NativeCollateralMismatch` otherwise). When `msg.value > 0` the
`equity` field is ignored.

### 3.6 Slippage and deadlines

A curated position swap is an **exact-output** swap you route through the Universal Router
(`routeCommands`/`routeInputs`); the route can source liquidity across v2/v3/v4:

- `maxDebtIn` (open/increase) / `maxCollateralIn` (close/decrease) is the **mandatory, binding**
slippage bound: the absolute cap on the swap input. The router flash-takes this amount and grants the
Universal Router a Permit2 allowance of exactly this much, so it binds regardless of what the route's
own `amountInMaximum` says. Derive it from a quote, not spot price. It must also stay within the
flash-takeable PoolManager liquidity of the input token, so size it as a realistic slippage cap, not an
arbitrary large value.
- Any per-hop price bound (e.g. v4's `minHopPriceX36`) is encoded **inside your route**, not passed as a
separate param.
- `deadline` is a Unix timestamp; the call reverts (`DeadlinePassed`) if `block.timestamp` exceeds it.
- **Position swaps are all-or-nothing on amount.** An exact-output swap can partially fill on a thin
pool. After the routed swap, both the increase and the decrease/close assert the account received the
requested output (`ASSERT_ACCOUNT_BALANCE`) and revert (`IncompleteFill`) otherwise, rather than acting
on a smaller amount (an open that under-filled would open a smaller position; a close that under-bought
the debt would fail the repay opaquely). Your route MUST deliver the bought output to your MarginAccount
and draw the input from the router as payer via Permit2; the guards above make a wrong route fail
loudly rather than silently.

---

## 4. Operations

All entry points operate on the caller's own account, derived from the authenticated caller and
`subId`; an account address is never accepted from calldata.


| Operation                    | Params                | Effect                                                                                                                                                                       |
| ---------------------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `increasePosition` (payable) | `IncreaseParams`      | Deploys the account if needed, pulls equity, opens a leveraged position. Calling again on an account that already holds a position adds leverage to it; set `equity = 0` and send no value for a pure leverage increase. Optional `maxLtvAfter` bound. |
| `addCollateral` (payable)    | `AddCollateralParams` | Supplies more collateral without changing debt (delevers / improves health). No swap.                                                                                        |
| `decreasePosition`           | `DecreaseParams`      | Partial delever: repays `debtToRepay` by selling collateral, position stays open, enforces `maxLtvAfter`. A **full close** is `debtToRepay == type(uint256).max`: repay all debt, withdraw all collateral, return the residual (realized PnL) to the caller (a zero-debt position is withdrawn directly with no swap; `maxLtvAfter` ignored). |
| `execute` (payable)          | `bytes, uint256`      | Runs an arbitrary caller-supplied plan of routing + margin actions in one unlock. The general-purpose counterpart to the curated entries; see §4.1. |


**Increase mechanics:** swap debt → `collateralToBuy` collateral (exact-out, input capped by
`maxDebtIn`) → assert full fill → take to the account → supply the account's full collateral balance →
borrow the debt owed → settle → assert `maxLtvAfter` (skipped when zero).

**Full-close mechanics** (`decreasePosition` with `debtToRepay == type(uint256).max`): swap collateral
→ exactly the current debt (exact-out, input capped by `maxCollateralIn`) → assert full fill → take to
the account → repay all (a venue-resolved full repay that leaves no dust) → withdraw all collateral →
settle → return the residual collateral delta to the caller.

**Partial-decrease mechanics:** swap collateral → `debtToRepay` → assert full fill → repay → withdraw
the collateral the swap consumed → settle → assert the resulting LTV is `<= maxLtvAfter`.

### 4.1 The `execute` entrypoint (advanced)

The curated entries above are fixed plans. `execute(bytes unlockData, uint256 deadline)` is the
general-purpose counterpart: it runs an **arbitrary** caller-supplied plan of v4 routing actions and
margin account actions in a single `PoolManager` unlock. Everything the curated flows do internally
is available as composable opcodes, plus flows they cannot express — adjusting margin and leverage
together, migrating collateral between sub-accounts, paying equity in a token other than the
collateral (convert it in the same plan), or repaying from the wallet.

`unlockData` is `abi.encode(bytes actions, bytes[] params)`: `actions` is the packed opcode string and
`params[i]` is the ABI-encoded parameters for `actions[i]`. The opcodes are the inherited v4 routing
set (swap / settle / take, and `SWEEP` / `WRAP` / `UNWRAP`) plus the margin opcodes:

| Opcode                       | Purpose                                                                                     |
| ---------------------------- | ------------------------------------------------------------------------------------------- |
| `SET_ACCOUNT(subId)`         | Bind the active account for subsequent account-scoped actions. Derived from the authenticated caller and `subId`, never from calldata. May appear multiple times (multi-sub-account plans). |
| `PULL_TO_ACCOUNT(currency, amount, payerIsUser)` | Move a token into the active account: pulled from the caller via Permit2 (`payerIsUser = true`) or from the router's own balance (`false`). Enables repay-from-wallet and native equity. |
| `ACCOUNT_SUPPLY_COLLATERAL` / `ACCOUNT_BORROW` | Supply/borrow on the active account. **Allowlist-gated** (exposure-increasing). |
| `ACCOUNT_WITHDRAW_COLLATERAL` / `ACCOUNT_REPAY` / `ACCOUNT_SWEEP` | Withdraw/repay/sweep on the active account. Not allowlist-gated (exits stay open). |
| `ROUTE_SWAP(universalRouter, input, maxIn, commands, inputs)` | Route a swap through the caller-supplied `universalRouter` (a Universal Router carrying already-unlocked `V4_SWAP`; must be non-zero, else `UniversalRouterNotSet`) across v2/v3/v4: flash-take up to `maxIn` of `input`, fund UR via a scoped Permit2 allowance, run the caller-built UR `commands`/`inputs` (which must deliver the output to the active account and self-settle), then settle only this call's unspent take (any pre-existing router balance is left untouched). Leaves the same net delta a native v4 swap would, so a following `ACCOUNT_BORROW`/`SETTLE` nets via `OPEN_DELTA`. |
| `ASSERT_HEALTH(adapter, market, maxLtv)` / `ASSERT_FILL(currency, minAmount)` / `ASSERT_ACCOUNT_BALANCE(currency, minAmount)` | Opt-in guards; encode them yourself. `ASSERT_FILL` checks the router's per-unlock swap credit (a true delta). `ASSERT_ACCOUNT_BALANCE` checks the active account's ABSOLUTE balance is at least `minAmount` — a floor any pre-existing balance counts toward, not a fill delta; see the note below on getting a delta guarantee from it. |

`execute` does no entry validation — it gives exactly the guardrails the plan encodes. Composing plans
safely:

1. **Active account.** Open each account-scoped section with `SET_ACCOUNT`. A plan can only ever touch
the caller's own accounts. The active account is cleared when the call returns.
2. **Bounds are yours.** Encode swap slippage (`amountInMaximum`), `ASSERT_FILL` after an exact-output
swap, and `ASSERT_HEALTH` after each `SET_ACCOUNT` section — the curated entries remain the
guard-railed path for callers who want that done for them.
3. **Net the router to zero.** A plan MUST leave no residual on the router; terminate with `SWEEP` for
every currency it may touch. Balances left behind are **claimable by the next caller** and are not
protocol-protected.
4. **Allowlist asymmetry.** Supply and borrow require an allowlisted adapter; withdraw, repay, and
account-sweep do not, so a position is always exitable.
5. **`PULL_TO_ACCOUNT`.** An encoded `0` amount reverts (it is not an `OPEN_DELTA` full-balance
sentinel, unlike the other opcodes); `CONTRACT_BALANCE` is honored only on the router-balance path;
native currency is unsupported (wrap to WETH first).
6. **Events.** Every position mutation (supply, withdraw, borrow, repay) on every router path,
including inside an `execute` plan and on the unlock-free paths (`addCollateral` and the zero-debt
swap-free close), emits a `PositionUpdated` snapshot with the account's resulting
`(collateral, debt)`, LTV, max LTV, and health factor, so an indexer can reconstruct positions from
router logs alone (take the last `PositionUpdated` per `(account, collateral, debt)` in a
transaction as the resulting state). Mutations made through the owner escape hatch (calling the
`MarginAccount` directly) bypass the router and emit no snapshot. `execute` plans also emit the account-level delta events
(`CollateralSupplied`, `Borrowed`, `Repaid`, `Swept`, `AccountCreated`). Only the curated entry
points additionally emit the richer `PositionIncreased`/`PositionDecreased`/`CollateralAdded` events
that fold the per-operation deltas and resulting snapshot into one log.

**The curated flows' swap-delta guarantee is not replicable inside a plan.** `ASSERT_ACCOUNT_BALANCE`
is an absolute floor and its `minAmount` is static calldata: a plan cannot snapshot the account's
balance mid-plan, and no delta-asserting account opcode exists, so the curated technique (threshold =
balance going into the unlock plus the required delivery, computed in the same transaction) is not
available to a hand-built plan. Prefer `ASSERT_FILL` wherever the swap output lands on the router —
router credit is per-unlock and cannot be inflated by a standing balance, so it is a true delta.
`ROUTE_SWAP` delivers the output to the active account, so a fill check there must use
`ASSERT_ACCOUNT_BALANCE`: either run against an account known to hold none of the output currency (a
fresh `subId`, or an `ACCOUNT_SWEEP` of that currency beforehand) so the floor and the delta
coincide, or set `minAmount` to an offchain-observed balance plus the required delivery and accept
that a balance arriving between observation and execution relaxes the check.

> **Signing an `execute` plan is equivalent to handing over the sub-account.** Because the router is
> the account's manager, a malicious plan can borrow to the market maximum, withdraw all collateral,
> and direct everything to an arbitrary address — with **no token approval required**, strictly worse
> than a token approval. Never execute a plan built by an untrusted party; front ends must construct
> the calldata themselves.

---

## 5. Reading position state

Read through the adapter. Debt is always interest-accrued to the current timestamp; collateral is the
venue's current balance (interest-accrued on Aave: v3 aTokens rebase, v4 reports the Spoke's accrued
supplied assets; the raw supplied balance on Morpho and Compound, whose collateral earns no interest)
— in every case the amount a full withdrawal returns:

```solidity
// current position, in each token's native decimals
(uint256 collateral, uint256 debt) = adapter.positionOf(account, market);

// current loan-to-value and the market maximum (WAD; 1e18 == 100%)
Ltv current = adapter.currentLtvWad(account, market);
Ltv maxLtv  = adapter.maxLtvWad(market);

// is this (collateral, debt) pair routable?
bool ok = adapter.isSupportedMarket(market);
```

`account` for `(owner, subId)` is `router.accountOf(owner, subId)`. The account exposes `owner()` and
`manager()`.

---

## 6. Smart contract integration (Solidity)

### 6.1 Imports

```solidity
import {IMarginRouter} from "v4-periphery/src/interfaces/IMarginRouter.sol";
import {ILendingAdapter} from "v4-periphery/src/interfaces/ILendingAdapter.sol";
import {IMarginAccount} from "v4-periphery/src/interfaces/IMarginAccount.sol";
import {Market} from "v4-periphery/src/types/Market.sol";
import {Ltv} from "v4-periphery/src/types/Ltv.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
```

### 6.2 Open a leveraged long with ERC-20 equity (Permit2)

```solidity
contract MarginIntegrator {
    IMarginRouter public immutable router;
    ILendingAdapter public immutable adapter;
    IAllowanceTransfer public immutable permit2;
    // Universal Router the position swaps route through; must carry already-unlocked V4_SWAP (a UR
    // built after PR #491). Supplied per call, so it can be repointed at a newer UR without redeploying.
    address public immutable universalRouter;

    // WETH/USDC pool the leverage swap routes through (currencies sorted: USDC < WETH)
    PoolKey internal poolKey;

    constructor(
        IMarginRouter _router,
        ILendingAdapter _adapter,
        IAllowanceTransfer _permit2,
        address _universalRouter,
        PoolKey memory _key
    ) {
        router = _router;
        adapter = _adapter;
        permit2 = _permit2;
        universalRouter = _universalRouter;
        poolKey = _key;
    }

    /// @notice Open a 2x long WETH position with `equity` WETH of the caller's funds (held by this
    ///         contract). Leverage and slippage come from the quote the caller supplies.
    /// @param weth The WETH token (collateral).
    /// @param usdc The USDC token (debt).
    /// @param equity WETH equity, 18 decimals.
    /// @param collateralToBuy WETH to buy on top of equity (for 2x, equal to `equity`).
    /// @param maxDebtIn Max USDC to spend on the swap, from an off-chain or on-chain quote + slippage.
    function open2xLong(address weth, address usdc, uint256 equity, uint128 collateralToBuy, uint128 maxDebtIn)
        external
        returns (address account)
    {
        Market memory market = Market({collateral: Currency.wrap(weth), debt: Currency.wrap(usdc)});

        // one-time per token: let Permit2 move this contract's WETH, then authorize the router
        IERC20(weth).approve(address(permit2), type(uint256).max);
        permit2.approve(weth, address(router), uint160(equity), uint48(block.timestamp + 1 hours));

        // the account is deterministic in (owner, subId), so we can build the route to it before opening
        account = router.accountOf(address(this), 0);

        // build the Universal Router route: buy `collateralToBuy` WETH exact-output for USDC over the
        // v4 pool, pulling the USDC from the router (payer) via Permit2 and delivering WETH to `account`.
        // This is a standard UR command plan, so you can instead route across v2/v3 or split routes.
        (bytes memory routeCommands, bytes[] memory routeInputs) =
            _v4Route(poolKey, market.debt, market.collateral, collateralToBuy, maxDebtIn, account);

        router.increasePosition(
            IMarginRouter.IncreaseParams({
                adapter: adapter,
                market: market,
                equity: equity,
                collateralToBuy: collateralToBuy,
                maxDebtIn: maxDebtIn, // binding slippage cap AND the flash-take/Permit2 allowance
                universalRouter: universalRouter, // UR to route through; must carry already-unlocked V4_SWAP
                routeCommands: routeCommands,
                routeInputs: routeInputs,
                maxLtvAfter: Ltv.wrap(0), // optional resulting-LTV bound; 0 skips the check
                subId: 0,
                deadline: block.timestamp + 15 minutes
            })
        );
    }

    /// @dev Single-pool v4 exact-output UR route: buy `amountOut` of `output` for <= `maxIn` of `input`
    ///      over `poolKey`, input settled from the router (payer) via Permit2, output taken to `to`.
    function _v4Route(PoolKey memory key, Currency input, Currency output, uint128 amountOut, uint128 maxIn, address to)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE));
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(IV4Router.ExactOutputSingleParams({
            poolKey: key,
            zeroForOne: Currency.unwrap(input) == Currency.unwrap(key.currency0),
            amountOut: amountOut,
            amountInMaximum: maxIn,
            minHopPriceX36: 0,
            hookData: ""
        }));
        p[1] = abi.encode(input, uint256(ActionConstants.OPEN_DELTA), true);   // SETTLE input from router (Permit2)
        p[2] = abi.encode(output, to, uint256(ActionConstants.OPEN_DELTA));    // TAKE output to the account
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, p);
        commands = abi.encodePacked(uint8(Commands.V4_SWAP));
    }
}
```

> The remaining Solidity/TypeScript examples in §6–§8 abbreviate the swap: `cmds`/`ins` (Solidity) and
> `routeCommands`/`routeInputs` (TypeScript) stand for a Universal Router route built with the `_v4Route`
> helper above — or any UR route that buys the exact output to your account and pays from the router via
> Permit2. `increasePosition`/`decreasePosition` take `routeCommands`/`routeInputs`; they do not take a
> `poolKey` or a top-level `minHopPriceX36` (a per-hop price bound lives inside your route). Likewise
> `universalRouter` in those examples is the Universal Router the swap routes through - the immutable set
> in §6.2 (or `ADDR.universalRouter` in TypeScript), a UR carrying already-unlocked `V4_SWAP` - supplied
> per call so a later call can point at a newer UR.

The router pulls `equity` from `msg.sender` (this contract) into the account, so this contract must
hold the WETH and have done the two Permit2 approvals above.

### 6.3 Open with native ETH equity

```solidity
function openLongWithEth(address weth, address usdc, uint128 collateralToBuy, uint128 maxDebtIn)
    external
    payable
    returns (address account)
{
    // collateral MUST be WETH for the native path
    Market memory market = Market({collateral: Currency.wrap(weth), debt: Currency.wrap(usdc)});

    account = router.increasePosition{value: msg.value}(
        IMarginRouter.IncreaseParams({
            adapter: adapter,
            market: market,
            equity: 0, // ignored when msg.value > 0
            collateralToBuy: collateralToBuy,
            maxDebtIn: maxDebtIn,
            universalRouter: universalRouter, // UR with already-unlocked V4_SWAP (see §6.2)
            routeCommands: cmds, // built via _v4Route(...) as in §6.2
            routeInputs: ins,
            maxLtvAfter: Ltv.wrap(0),
            subId: 0,
            deadline: block.timestamp + 15 minutes
        })
    );
}
```

### 6.4 Increase, add collateral, decrease, close

```solidity
// add 1 WETH of leverage with no new equity (a second open into the same account)
function increase(Market memory market, uint128 buy, uint128 maxDebtIn) external {
    router.increasePosition(
        IMarginRouter.IncreaseParams({
            adapter: adapter, market: market,
            equity: 0, collateralToBuy: buy, maxDebtIn: maxDebtIn,
            universalRouter: universalRouter, routeCommands: cmds, routeInputs: ins, maxLtvAfter: Ltv.wrap(0), subId: 0, deadline: block.timestamp + 15 minutes
        })
    );
}

// top up collateral to improve health (no swap, no leverage change); needs Permit2 approval as in 6.2
function addCollateral(Market memory market, uint256 amount) external {
    router.addCollateral(
        IMarginRouter.AddCollateralParams({
            adapter: adapter, market: market, amount: amount, subId: 0, deadline: block.timestamp + 15 minutes
        })
    );
}

// repay 1000 USDC of debt by selling WETH; keep the resulting LTV under 70%
function delever(Market memory market, uint256 debtToRepay, uint128 maxCollateralIn) external {
    router.decreasePosition(
        IMarginRouter.DecreaseParams({
            adapter: adapter, market: market,
            debtToRepay: debtToRepay, maxCollateralIn: maxCollateralIn,
            universalRouter: universalRouter, routeCommands: cmds, routeInputs: ins, maxLtvAfter: Ltv.wrap(0.7e18),
            subId: 0, deadline: block.timestamp + 15 minutes
        })
    );
}

// fully close; residual collateral (realized PnL) is sent to msg.sender. A full close is a
// decreasePosition with debtToRepay == type(uint256).max; maxLtvAfter is ignored on a full close.
function close(Market memory market, uint128 maxCollateralIn) external {
    router.decreasePosition(
        IMarginRouter.DecreaseParams({
            adapter: adapter, market: market,
            debtToRepay: type(uint256).max, maxCollateralIn: maxCollateralIn,
            universalRouter: universalRouter, routeCommands: cmds, routeInputs: ins, maxLtvAfter: Ltv.wrap(0),
            subId: 0, deadline: block.timestamp + 15 minutes
        })
    );
}
```

### 6.5 Sizing the swap on-chain

```solidity
// for a target leverage L (WAD) and equity E, derive the exact-out and cap
function size(uint256 equity, uint256 leverageWad, uint256 priceDebtPerCollateralWad, uint256 slippageBps)
    internal
    pure
    returns (uint128 collateralToBuy, uint128 maxDebtIn)
{
    uint256 total = equity * leverageWad / 1e18;
    uint256 buy = total - equity;                                  // collateral to buy
    uint256 debt = buy * priceDebtPerCollateralWad / 1e18;         // expected debt input (a quote)
    collateralToBuy = uint128(buy);
    maxDebtIn = uint128(debt * (10_000 + slippageBps) / 10_000);   // add slippage headroom
}
```

> `priceDebtPerCollateralWad` should come from a quote (a v4 quoter or an oracle) and account for the
> two tokens' decimals. The lending market's oracle (`adapter.currentLtvWad`) is for health, not for
> sizing the swap.

### 6.6 Reading and the owner escape hatch

```solidity
function health(address owner, uint256 subId, Market memory market)
    external
    view
    returns (uint256 collateral, uint256 debt, uint256 ltvWad, uint256 maxLtvWad)
{
    address account = router.accountOf(owner, subId);
    (collateral, debt) = adapter.positionOf(account, market);
    ltvWad = Ltv.unwrap(adapter.currentLtvWad(account, market));
    maxLtvWad = Ltv.unwrap(adapter.maxLtvWad(market));
}

// the owner can always act directly on the lending protocol, bypassing the router
function ownerRepayDirect(uint256 subId, Market memory market, bytes calldata morphoRepayCall) external {
    address account = router.accountOf(address(this), subId);
    IMarginAccount(account).execute(adapter, morphoRepayCall);
}
```

### 6.7 Notes for contract integrators

- The router derives the account from the authenticated caller (`msg.sender` of the entry point).
When your contract calls `increasePosition`, the position belongs to your contract, and its residual on
close is sent to your contract.
- Batch multiple actions in one transaction with `multicall(bytes[])` (inherited). Do not batch two
native-ETH position calls in one `multicall` — `msg.value` is shared and the second wrap would
revert.
- Markets are standard ERC-20 only (no fee-on-transfer or rebasing tokens).

---

## 7. Front-end integration (TypeScript / viem)

The examples use [viem](https://viem.sh). For wagmi v2, wrap the same calls in `useReadContract` /
`useWriteContract`. Import the generated ABIs for `MarginRouter` and your chosen lending adapter (and a
minimal Permit2 / ERC-20 ABI). The `ILendingAdapter` read surface used below
(`positionOf` / `currentLtvWad` / `maxLtvWad` / `isSupportedMarket`) is identical across the Morpho,
Aave v3, and Aave v4 adapters, so the same read code works for any venue — only the adapter address
changes.

### 7.1 Setup

```ts
import { createPublicClient, createWalletClient, custom, http, parseUnits, formatUnits } from "viem";
import { mainnet } from "viem/chains";
import { marginRouterAbi, lendingAdapterAbi } from "./abis";

const ADDR = {
  router:  "0x<MARGIN_ROUTER>",        // fill in per deployment
  adapter: "0x<LENDING_ADAPTER>",      // fill in per deployment (Morpho, Aave v3, Aave v4, or Compound v3)
  universalRouter: "0x<UNIVERSAL_ROUTER>", // fill in per deployment (a UR with already-unlocked V4_SWAP)
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  weth:    "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  usdc:    "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
} as const;

const publicClient = createPublicClient({ chain: mainnet, transport: http() });
const walletClient = createWalletClient({ chain: mainnet, transport: custom((window as any).ethereum) });

// WETH/USDC v4 pool the swap routes through. currency0 < currency1 (USDC < WETH here).
const poolKey = {
  currency0: ADDR.usdc,
  currency1: ADDR.weth,
  fee: 3000,
  tickSpacing: 60,
  hooks: "0x0000000000000000000000000000000000000000",
} as const;

// market: long WETH (collateral) vs USDC (debt)
const market = { collateral: ADDR.weth, debt: ADDR.usdc } as const;
```

### 7.2 Permit2 approval (one-time per token)

```ts
const MAX_UINT160 = (1n << 160n) - 1n;
const MAX_UINT48 = (1n << 48n) - 1n;

const erc20Abi = [
  { type: "function", name: "approve", stateMutability: "nonpayable",
    inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "allowance", stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }, { name: "spender", type: "address" }], outputs: [{ type: "uint256" }] },
] as const;

const permit2Abi = [
  { type: "function", name: "approve", stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" }, { name: "spender", type: "address" },
      { name: "amount", type: "uint160" }, { name: "expiration", type: "uint48" },
    ], outputs: [] },
] as const;

async function ensurePermit2(account: `0x${string}`, token: `0x${string}`, amount: bigint) {
  // 1) let Permit2 move the token (idempotent; approve max once)
  await walletClient.writeContract({
    account, address: token, abi: erc20Abi, functionName: "approve",
    args: [ADDR.permit2, (1n << 256n) - 1n],
  });
  // 2) authorize the router as a Permit2 spender for at least `amount`
  await walletClient.writeContract({
    account, address: ADDR.permit2, abi: permit2Abi, functionName: "approve",
    args: [token, ADDR.router, amount > MAX_UINT160 ? MAX_UINT160 : amount, Number(MAX_UINT48)],
  });
}
```

> Gasless alternative: build a Permit2 `PermitSingle`, sign it (EIP-712), and forward it through the
> router's inherited `permit(owner, permitSingle, signature)` in the same `multicall` as
> `increasePosition`. The on-chain `approve` above is the simplest path.

### 7.3 Size the position and open

```ts
// price: USDC per WETH (e.g. from a quoter or oracle), as a float for the example
function sizeOpen(equityWeth: bigint, leverage: number, usdcPerWeth: number, slippageBps: number) {
  const total = (equityWeth * BigInt(Math.floor(leverage * 1e6))) / 1_000_000n; // total collateral
  const collateralToBuy = total - equityWeth;                                   // WETH to buy (18d)
  // expected USDC in = WETH_to_buy * price, converting 18d WETH -> 6d USDC
  const expectedUsdc = (collateralToBuy * BigInt(Math.floor(usdcPerWeth * 1e6))) / 10n ** 18n;
  const maxDebtIn = (expectedUsdc * BigInt(10_000 + slippageBps)) / 10_000n;     // 6d USDC
  return { collateralToBuy, maxDebtIn };
}

async function open2xLong(user: `0x${string}`) {
  const equity = parseUnits("1", 18);                       // 1 WETH equity
  const { collateralToBuy, maxDebtIn } = sizeOpen(equity, 2, 3000, 50); // 2x, $3000, 0.5%

  await ensurePermit2(user, ADDR.weth, equity);

  const deadline = BigInt(Math.floor(Date.now() / 1000) + 900);

  const params = {
    adapter: ADDR.adapter,
    market,
    equity,
    collateralToBuy,
    maxDebtIn,
    universalRouter: ADDR.universalRouter, // UR with already-unlocked V4_SWAP; supplied per call
    routeCommands, // Universal Router route bytes (built as in §6.2)
    routeInputs,
    maxLtvAfter: 0n, // optional resulting-LTV bound (WAD); 0 skips the check, a non-zero bound must be < 1e18
    subId: 0n,
    deadline,
  };

  const { request } = await publicClient.simulateContract({
    account: user, address: ADDR.router, abi: marginRouterAbi, functionName: "increasePosition", args: [params],
  });
  return walletClient.writeContract(request);
}
```

Native-ETH open is the same call with `equity: 0n` and a `value` field:

```ts
await walletClient.writeContract({
  account: user, address: ADDR.router, abi: marginRouterAbi, functionName: "increasePosition",
  args: [{ ...params, equity: 0n }], value: parseUnits("1", 18),
});
```

### 7.4 Read a position and its health

```ts
async function readPosition(owner: `0x${string}`, subId: bigint) {
  const account = await publicClient.readContract({
    address: ADDR.router, abi: marginRouterAbi, functionName: "accountOf", args: [owner, subId],
  });

  const [collateral, debt] = await publicClient.readContract({
    address: ADDR.adapter, abi: lendingAdapterAbi, functionName: "positionOf", args: [account, market],
  });
  const ltv = await publicClient.readContract({
    address: ADDR.adapter, abi: lendingAdapterAbi, functionName: "currentLtvWad", args: [account, market],
  });
  const maxLtv = await publicClient.readContract({
    address: ADDR.adapter, abi: lendingAdapterAbi, functionName: "maxLtvWad", args: [market],
  });

  return {
    account,
    collateralWeth: formatUnits(collateral, 18),
    debtUsdc: formatUnits(debt, 6),
    ltvPct: Number(formatUnits(ltv as bigint, 18)) * 100,
    maxLtvPct: Number(formatUnits(maxLtv as bigint, 18)) * 100,
  };
}

// has the account been deployed yet?
async function isDeployed(account: `0x${string}`) {
  const code = await publicClient.getCode({ address: account });
  return !!code && code !== "0x";
}
```

### 7.5 Close and decrease

```ts
const MAX_UINT256 = (1n << 256n) - 1n;

async function closePosition(user: `0x${string}`, subId: bigint) {
  // full close = decreasePosition with debtToRepay == type(uint256).max
  // size maxCollateralIn from current debt + a quote (omitted): cap the WETH sold
  const maxCollateralIn = parseUnits("5", 18);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 900);

  const { request } = await publicClient.simulateContract({
    account: user, address: ADDR.router, abi: marginRouterAbi, functionName: "decreasePosition",
    args: [{
      adapter: ADDR.adapter, market,
      debtToRepay: MAX_UINT256, maxCollateralIn,
      universalRouter: ADDR.universalRouter, routeCommands, routeInputs, maxLtvAfter: 0n, // ignored on a full close
      subId, deadline,
    }],
  });
  return walletClient.writeContract(request);
}

async function decreasePosition(user: `0x${string}`, subId: bigint) {
  const debtToRepay = parseUnits("1000", 6);   // repay 1000 USDC
  const maxCollateralIn = parseUnits("2", 18);  // sell at most 2 WETH
  const maxLtvAfter = parseUnits("0.7", 18);    // keep LTV <= 70%
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 900);

  const { request } = await publicClient.simulateContract({
    account: user, address: ADDR.router, abi: marginRouterAbi, functionName: "decreasePosition",
    args: [{ adapter: ADDR.adapter, market, debtToRepay, maxCollateralIn, universalRouter: ADDR.universalRouter, routeCommands, routeInputs, maxLtvAfter, subId, deadline }],
  });
  return walletClient.writeContract(request);
}
```

### 7.6 Front-end checklist

- Always `simulateContract` before `writeContract` to surface reverts (`SlippageBoundRequired`,
`PositionUnhealthy`, `AdapterNotAllowed`, `DeadlinePassed`, `NativeCollateralMismatch`) with a clear
message.
- Derive `maxDebtIn` / `maxCollateralIn` from a real quote plus a slippage buffer; do not use spot.
- Account decimals carefully: WETH is 18, USDC is 6.
- Surface the account address (`accountOf`) and its health (`currentLtvWad` vs `maxLtvWad`).

---

## 8. Choosing a venue and going short

### 8.1 Selecting a venue

The venue is chosen per call: pass the `MorphoLendingAdapter` to route through Morpho Blue, the
`AaveLendingAdapter` to route through the Aave v3 Pool, the `AaveV4LendingAdapter` to route through
an Aave v4 Spoke, or the `CompoundV3LendingAdapter` to route through a Compound v3 Comet. Nothing else
in the flow changes: all implement the same `ILendingAdapter` surface
and the router orchestrates them identically. Each adapter must be allowlisted by governance
(`router.setAdapterAllowed(adapter, true)`) before it can be used to *add* exposure; closing and
delevering never require an allowlisted adapter, so a position opened on any venue can always be
unwound. Whether a given `(collateral, debt)` pair is routable on a venue is read with
`adapter.isSupportedMarket(market)`.

`AaveLendingAdapter` is constructed from an Aave v3 `IPoolAddressesProvider`
(`constructor(IPoolAddressesProvider provider, address owner_)`); it resolves and stores the Pool
immutably (a proxy with a stable address across Aave upgrades), while the protocol data provider, a
plain address Aave can repoint, is re-resolved from the addresses provider on each use rather than
stored. Governance enables a pairing with
`setMarket(Currency collateral, Currency debt, bool allowed)` (owner-gated; both must be live Aave
reserves), and ownership is the same two-step `transferOwnership` / `acceptOwnership` /
`owner()` / `pendingOwner()` handoff as the Morpho adapter. Reads mirror the Morpho adapter:
`positionOf` returns the account's aToken and variableDebtToken balances, `maxLtvWad` returns the
collateral reserve's liquidation threshold, and `currentLtvWad` is the account-level LTV from Aave's
`getUserAccountData` (denominated in Aave's USD base currency, so it is decimal-agnostic). Because
these reads are account-level (true for both the v3 and v4 adapters), keep one Aave position per
`(owner, subId)` and use a distinct `subId` for each — co-locating two Aave markets under one account
blends the reads and can break a later close/decrease (see §3.2).

`AaveV4LendingAdapter` targets Aave v4's **hub-and-spoke** architecture and is constructed against a
single **Spoke** (`constructor(ISpoke spoke, address owner_)`); the Spoke is `lendingProtocol()` and
the call target for every market it routes. To serve a second Spoke, deploy a second adapter instance
and allowlist it. A v4 market is keyed by a per-Spoke `reserveId` rather than an asset address, so
governance enables a pairing with
`setMarket(Currency collateral, Currency debt, uint256 collateralReserveId, uint256 debtReserveId, bool allowed)`;
the call validates on-chain that each reserve's `underlying` matches the currency and that both
reserves are on the same Hub. Four v4 specifics are handled entirely inside the adapter, so the router
and account flows are unchanged:

- **Supply enables collateral atomically.** v4 `supply` does not auto-enable collateral, so the
adapter's `encodeEnableCollateral` hook encodes `setUsingAsCollateral`, which the account runs
immediately after every supply (idempotent, so top-ups are safe). The v3 adapter uses the same hook
to encode `setUserUseReserveAsCollateral`, making both Aave adapters immune to the first-supply
auto-enable gap; Morpho and Compound treat supplied collateral as collateral automatically and
return the empty skip signal.
- **Premium-inclusive debt.** v4 debt is drawn debt plus accrued premium; `positionOf` and the
full-repay path read `getUserTotalDebt`, and the router's close swap is sized off that figure.
- **`maxLtvWad`** reads the collateral reserve's `collateralFactor`. v4's true liquidation point also
depends on the position's risk premium and dynamic config; integrators wanting a strict
liquidation-distance check should also consult `healthFactor` from the Spoke's `getUserAccountData`.
- **`currentLtvWad`** is the account-level LTV derived from the Spoke's `getUserAccountData` (Value
units are USD scaled by the oracle decimals; the debt total carries an extra RAY factor that the
adapter normalizes), so it is decimal-agnostic like the v3 adapter.

v4's position-manager / intent apparatus (for third-party relayers) is irrelevant here: the account is
its own `onBehalfOf` and the direct caller, so it needs no registration, activation, or signatures.
v4 `withdraw` and `borrow` deliver the underlying to the account (not a receiver argument); the account
forwards it to the validated recipient, the same measure-and-forward `MarginAccount` already uses for
`borrow`.

`CompoundV3LendingAdapter` targets a single Compound v3 **Comet** and is constructed against it
(`constructor(IComet comet, address owner_)`); the Comet is `lendingProtocol()` and the call target for
every market. A Comet is **single-base**: it has exactly one borrowable base token and a set of
collateral assets. So every routable pair must have `debt == comet.baseToken()` and a `collateral` that
is a registered Comet collateral asset — governance enables a pair with
`setMarket(Currency collateral, Currency debt, bool allowed)`, which validates both on-chain (the base
match and that the collateral is a Comet collateral asset). To serve a different base, deploy a second
adapter against that Comet. Two Compound specifics are handled inside the adapter, so the router and
account flows are unchanged:

- **No separate borrow/repay.** Borrowing the base is `withdraw`ing it (drawing the base balance
negative) and repaying is `supply`ing it. The four `ILendingAdapter` primitives map onto Comet's
`supply` / `withdraw` / `withdrawTo` accordingly.
- **Full repay is the exact accrued balance.** Comet has no share-based "repay all" and no `max`
sentinel, so a full close (`decreasePosition` with `debtToRepay == type(uint256).max`) supplies exactly
`borrowBalanceOf(account)`. That balance accrues to `block.timestamp` in the view, so the borrow clears
to zero with no dust and all collateral can then be withdrawn.
- **Partial decreases have a venue-imposed minimum.** Comet re-checks the tighter **borrow** collateral
factor on the withdraw leg of a decrease (the router repays, then withdraws the swap cost), so a
position that has drifted above the borrow factor rejects small partial decreases: the repay must be
large enough to bring the position back under the borrow factor, or be a full close (which always
works). `maxLtvWad` surfaces only the liquidate factor, so size partial decreases against
`getAssetInfoByAddress(collateral).borrowCollateralFactor`, not `maxLtvWad`.
- **Base-asset supplies are out of scope.** A positive base balance (a Comet base supply) reads as
`borrowBalanceOf == 0`, and the base token cannot be registered as a market's collateral (`setMarket`
rejects it, since `getAssetInfoByAddress(base)` reverts), so the router cannot open, read, or unwind a
base-supply position - it manages collateral-backed base borrows only. A base supply can only arise via
an `execute` plan or a direct Comet call; unwind it the same way (an `execute` plan or the owner escape
hatch).

Reads mirror the other adapters: `positionOf` returns `(collateralBalanceOf, borrowBalanceOf)`,
`maxLtvWad` returns the collateral's **liquidate** collateral factor (Comet enforces the tighter
**borrow** collateral factor at borrow time, so a borrow can open below `maxLtvWad` yet be rejected by
Comet), and `currentLtvWad` is USD-valued through Comet's own price feeds (decimal-agnostic). The reads
are account-level in the base, so keep one Compound position per `(owner, subId)` and use a distinct
`subId` for each, as with the Aave adapters. The priced reads (`maxLtvWad`, `currentLtvWad`,
`describePosition`) also depend on the live Comet configuration: they call
`getAssetInfoByAddress(collateral)` unguarded, so if Compound governance ever removes a collateral
asset from the Comet, those reads (and the curated flows that consult them) revert opaquely until the
market is de-registered. Compound's removal process makes this realistic only after balances are
zeroed, and funds remain exitable via the owner escape hatch regardless.

### 8.2 Open a short ETH position via Aave

A short ETH position is `Market(collateral: USDC, debt: WETH)`: supply USDC, borrow WETH, sell the
borrowed WETH for more USDC collateral. The only differences from a long are the adapter, the market
pairing, and the token decimals: `equity` and `collateralToBuy` are USDC (6 decimals) and `maxDebtIn`
is WETH (18 decimals), the reverse of the long examples in §6.

```solidity
// Open a short ETH position on Aave: supply USDC, borrow WETH.
// `aaveAdapter` is an allowlisted AaveLendingAdapter; `usdcWethKey` is the v4 pool the swap routes
// through (currencies sorted: USDC < WETH).
function openShortEth(
    address usdc,
    address weth,
    uint256 equityUsdc,        // USDC equity, 6 decimals
    uint128 collateralToBuyUsdc, // extra USDC collateral to buy, 6 decimals
    uint128 maxDebtInWeth      // max WETH to borrow and sell, 18 decimals (from a quote + slippage)
) external returns (address account) {
    Market memory market = Market({collateral: Currency.wrap(usdc), debt: Currency.wrap(weth)});

    // one-time per token: let Permit2 move this contract's USDC, then authorize the router
    IERC20(usdc).approve(address(permit2), type(uint256).max);
    permit2.approve(usdc, address(router), uint160(equityUsdc), uint48(block.timestamp + 1 hours));

    account = router.increasePosition(
        IMarginRouter.IncreaseParams({
            adapter: aaveAdapter,            // route through Aave v3
            market: market,                  // collateral USDC, debt WETH
            equity: equityUsdc,              // 6d USDC
            collateralToBuy: collateralToBuyUsdc, // 6d USDC
            maxDebtIn: maxDebtInWeth,        // 18d WETH binding cap
            universalRouter: universalRouter, // UR with already-unlocked V4_SWAP (see §6.2)
            routeCommands: cmds,             // built via _v4Route (see §6.2)
            routeInputs: ins,
            maxLtvAfter: Ltv.wrap(0),
            subId: 0,
            deadline: block.timestamp + 15 minutes
        })
    );
}
```

`IncreaseParams` carries no direction field: passing `Market(collateral: USDC, debt: WETH)` is what makes
this a short. Everything else (increase, add collateral, decrease, close, reading state) works exactly
as in §5 and §6, with the adapter set to the Aave adapter and the decimals swapped. The example routes
through Aave v3; to route the identical short through Aave v4, pass an allowlisted `AaveV4LendingAdapter`
instead. The router, account, params, and decimals are unchanged.

> Front-end caveat: the §7.3 `sizeOpen` helper is hardcoded for an 18-decimal collateral / 6-decimal
> debt long. For a short the decimals are reversed: size `equity` and `collateralToBuy` in 6-decimal
> USDC and `maxDebtIn` in 18-decimal WETH. Always use each token's actual `decimals()` in sizing math
> rather than assuming a fixed layout.

### 8.3 Hedging with sub-accounts

Because the account address is derived from `(owner, subId)`, one owner can hold a long and a short of
ETH side by side in two isolated accounts. Open the long under `subId = 0` (Morpho or Aave) and the
short under `subId = 1` on Aave; `router.accountOf(owner, subId)` yields two distinct `MarginAccount`
clones. The positions are fully isolated: each has its own collateral, debt, and health, and closing
or delevering one does not touch the other.

Sizing both legs to the same ETH notional makes the combined exposure delta-neutral: a long of `N`
WETH collateral against a short of `N` WETH debt nets to roughly zero ETH price exposure, leaving the
funding-rate spread between the two venues. The two calls differ only by adapter, market, and `subId`:

```solidity
// Leg 1: long ETH on subId 0 (collateral WETH, debt USDC)
router.increasePosition(
    IMarginRouter.IncreaseParams({
        adapter: morphoAdapter,
        market: Market({collateral: Currency.wrap(weth), debt: Currency.wrap(usdc)}),
        equity: equityWeth,              // 18d WETH
        collateralToBuy: longBuyWeth,    // 18d WETH
        maxDebtIn: longMaxDebtInUsdc,    // 6d USDC
        universalRouter: universalRouter, // UR with already-unlocked V4_SWAP (see §6.2)
        routeCommands: longCmds,         // route buying WETH for USDC (see §6.2)
        routeInputs: longIns,
        maxLtvAfter: Ltv.wrap(0),
        subId: 0,
        deadline: block.timestamp + 15 minutes
    })
);

// Leg 2: short ETH on subId 1 (collateral USDC, debt WETH)
router.increasePosition(
    IMarginRouter.IncreaseParams({
        adapter: aaveAdapter,
        market: Market({collateral: Currency.wrap(usdc), debt: Currency.wrap(weth)}),
        equity: equityUsdc,              // 6d USDC
        collateralToBuy: shortBuyUsdc,   // 6d USDC
        maxDebtIn: shortMaxDebtInWeth,   // 18d WETH
        universalRouter: universalRouter, // UR with already-unlocked V4_SWAP (see §6.2)
        routeCommands: shortCmds,        // route buying USDC for WETH (see §6.2)
        routeInputs: shortIns,
        maxLtvAfter: Ltv.wrap(0),
        subId: 1,
        deadline: block.timestamp + 15 minutes
    })
);
```

This is exercised by a mainnet-fork test: a long of about +2 WETH collateral against a short of about
2 WETH debt leaves a net ETH delta near zero (within roughly 0.3% of the gross size, the residual
coming from swap slippage on each leg), and closing one leg leaves the other untouched.

---

## 9. Security model and trust assumptions

- **Soulbound accounts.** Owner and manager are immutable; there is no re-initialization or transfer.
Only the manager (router) or owner can move an account's funds, and only to the manager or owner.
- **Adapter trust.** Adapters are governance-curated and an allowlisted adapter is fully trusted:
governance is responsible for vetting adapters it allowlists (a malicious adapter could drain funds
routed through it). The account routes calls only to the adapter's declared `lendingProtocol()` with a
regular call (never a delegatecall), acts as its own `onBehalf`, and constrains every fund recipient to
the owner or manager — but these are durable structural guarantees, not a defense against a malicious
adapter, which the allowlist is what actually gates.
- **Governance.** The router's adapter allowlist and the adapter's market routing table are
governance-controlled. Ownership transfers are two-step and reject the zero address. Production
deployments should put governance behind a timelock or multisig.
- **Market lifecycle.** Retiring or re-pointing a market is a deliberate governance action, and the
curated router paths (open, increase, decrease, close, reads) only operate on a currently supported
market. Do not de-register or re-point a pair that has open positions: doing so removes the convenient
router path for those positions (a full close can read as a success-shaped no-op), and holders must
then exit through the owner `execute` escape hatch against the lending protocol directly. The Morpho
registry has no per-market revoke, so stopping routing to a single Morpho market means re-pointing it
or disallowing the adapter. On the Aave v4 adapter, reserve-id bindings are validated at registration
against the Spoke's live layout and are not re-checked per operation, so a market must be re-registered
if the Spoke's reserve layout changes.
- **Exit is always available.** Closing and delevering do not require an allowlisted adapter, and the
owner `execute` escape hatch can act directly on the lending protocol, so funds are never trapped by
router-side configuration.
- **Venue is swappable behind `ILendingAdapter`.** The lending venue is an implementation detail of
the adapter; a position can migrate to a new venue by allowlisting a new adapter, with no router or
account changes.
- **Lending and oracle risk is inherited.** Health, liquidation, and pricing are the lending
protocol's responsibility (Morpho Blue, Aave v3, Aave v4, or Compound v3, depending on the adapter);
the margin layer adds no independent oracle.
- **ERC-20 only.** Markets must use standard ERC-20 tokens (no fee-on-transfer or rebasing).

---

## 10. Deployment addresses

The margin contracts below are the Ethereum mainnet deployment (DeployMargin.s.sol, chain 1), verified
on-chain with `cast code`; the external dependencies follow. Other networks are deployment-specific.


| Contract                      | Address                                      | Notes                                                                             |
| ----------------------------- | -------------------------------------------- | --------------------------------------------------------------------------------- |
| MarginRouter                  | `0x000000000075e82F7B7DdC5DD1B4984b560eF5D4` | mainnet (mined vanity); UR-per-call API, unlock-free-path PositionUpdated          |
| MarginAccount implementation  | `0x36e5317CEE9F70c0A41A97A4676899Dfe9a10239` | mainnet; the soulbound clone template                                             |
| MorphoLendingAdapter          | `0x70fD13dF8C827ab71AE300D24b771C19B67d178A` | mainnet; implements IAmountResolver                                               |
| AaveLendingAdapter            | `0x79D243C83e2D351aBbe8010a7E95162998475719` | mainnet; implements IAmountResolver                                               |
| AaveV4LendingAdapter          | `0x917D08052E2994B75cF82bDaF6314b07532f2556` | mainnet; constructed against the Aave v4 Main Spoke; implements IAmountResolver   |
| CompoundV3LendingAdapter      | `0x3625D6F7ccA2e8F95aF2E6497075D1a3E32dC5C6` | mainnet; bound to the cUSDCv3 Comet; implements IAmountResolver                   |
| v4 PoolManager                | `0x000000000004444c5dc75cB358380D2e3dE08A90` | mainnet; the official Uniswap v4 deployment                                       |
| Permit2                       | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | canonical, same on all chains                                                     |
| Morpho Blue                   | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | mainnet                                                                           |
| Aave v3 PoolAddressesProvider | `0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e` | mainnet; resolves the Pool and protocol data provider for `AaveLendingAdapter`    |
| Aave v3 Pool                  | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` | mainnet; resolved from the addresses provider                                     |
| Aave v3 protocol data provider | `0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD` | mainnet; resolved from the addresses provider                                   |
| Aave v4 Main Spoke            | `0x94e7A5dCbE816e498b89aB752661904E2F56c485` | mainnet; the Spoke `AaveV4LendingAdapter` routes through (verify with `cast code`) |
| Aave v4 Core Hub              | `0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9` | mainnet; backs the Main Spoke's WETH and USDC reserves                            |
| Aave v4 Main Spoke oracle     | `0x99B2B6CEa9C3D2fd8F4d90f86741C44B212a6127` | mainnet; reserveId-keyed (`getReservesPrices`), 8-decimal USD base               |
| Compound v3 USDC Comet        | `0xc3d688B66703497DAA19211EEdff47f25384cdc3` | mainnet (cUSDCv3); base token USDC, the Comet `CompoundV3LendingAdapter` routes through |
| WETH                          | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | mainnet                                                                           |
| USDC                          | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | mainnet                                                                           |
| UNI                           | `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984` | mainnet; the Compound long-UNI market collateral                                 |


Morpho WETH/USDC market (collateral WETH, loan USDC) — the canonical liquid market the deploy scripts
register: oracle `0x0F948CBa8231Db7898ef36A4212581Ad7b1B4580`,
IRM `0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC`, LLTV `0.86e18`,
id `0x94b823e6bd8ea533b4e33fbc307faea0b307301bc48763acc4d4aa4def7636cd` (verified on-chain: ~$4M
supplied / ~$3.7M borrowed). A second, near-empty WETH/USDC market exists at oracle
`0xdC6fd5831277c693b1054e19E94047cB37c77615` (id `0x7dde86a1…`, ~$16K TVL); do not integrate against
it. Always confirm the market id and TVL with `cast` before pointing production at an oracle.

Aave v3 USDC reserve (the collateral for a short ETH market): liquidation threshold `7800` bps
(`0.78`), which `AaveLendingAdapter.maxLtvWad` returns as `0.78e18`. The addresses and this threshold
were verified on a mainnet fork at block 25319047.

Aave v4 Main Spoke reserve ids: WETH is reserveId `0` (the debt leg of a short, borrowable) and USDC
is reserveId `7` (the collateral leg, collateral factor `7800` bps, which
`AaveV4LendingAdapter.maxLtvWad` returns as `0.78e18`). Both reserves are on the Core Hub. The
addresses, reserve ids, and collateral factor were verified on a mainnet fork at block 25330047.

Compound v3 long-UNI market (collateral UNI, debt USDC) on the cUSDCv3 Comet: UNI's borrow collateral
factor is `0.68e18` (Comet enforces this at borrow time, capping leverage near ~3.1x) and its liquidate
collateral factor is `0.74e18`, which `CompoundV3LendingAdapter.maxLtvWad` returns. These were verified
on a mainnet fork at block 25598384.

> Never hardcode an address without verifying it on-chain (`cast code` / `cast call`) for the target
> network.

---

## 11. Reference

### Param structs

```solidity
struct IncreaseParams {        // increasePosition
    ILendingAdapter adapter;
    Market market;
    uint256 equity;        // collateral equity (ignored if msg.value > 0)
    uint128 collateralToBuy;
    uint128 maxDebtIn;     // mandatory binding slippage cap (flash-take / Permit2 allowance)
    address universalRouter;   // Universal Router for this swap (must carry already-unlocked V4_SWAP)
    bytes routeCommands;   // Universal Router route (buys collateralToBuy to your account)
    bytes[] routeInputs;   // per-command inputs for routeCommands
    Ltv maxLtvAfter;       // optional resulting-LTV bound (0 = skip; a non-zero bound must be < 1e18)
    uint256 subId;
    uint256 deadline;
}

// closePosition is a decreasePosition with debtToRepay == type(uint256).max (there is no
// separate close entry point or CloseParams struct).
struct DecreaseParams {    // decreasePosition (partial decrease, or full close via max debtToRepay)
    ILendingAdapter adapter;
    Market market;
    uint256 debtToRepay;   // type(uint256).max = full close
    uint128 maxCollateralIn; // mandatory on the swap path (ignored for a zero-debt close)
    address universalRouter;   // Universal Router for this swap (must carry already-unlocked V4_SWAP)
    bytes routeCommands;   // Universal Router route (buys debtToRepay to your account)
    bytes[] routeInputs;   // per-command inputs for routeCommands
    Ltv maxLtvAfter;       // mandatory on a partial decrease (must be < 1e18); ignored on a full close
    uint256 subId;
    uint256 deadline;
}

struct AddCollateralParams { // addCollateral
    ILendingAdapter adapter;
    Market market;
    uint256 amount;        // collateral to add (ignored if msg.value > 0)
    uint256 subId;
    uint256 deadline;
}
```

### MarginRouter functions


| Function                                             | Access               | Notes                                 |
| ---------------------------------------------------- | -------------------- | ------------------------------------- |
| `increasePosition(IncreaseParams) payable`           | anyone               | own account; a second increase adds leverage |
| `decreasePosition(DecreaseParams)`                   | anyone               | own account; partial delever or full close (`debtToRepay == max`); no allowlist requirement |
| `addCollateral(AddCollateralParams) payable`         | anyone               | own account                           |
| `execute(bytes unlockData, uint256 deadline) payable`| anyone               | own accounts; arbitrary plan (§4.1)   |
| `accountOf(address owner, uint256 subId) view`       | anyone               | predicted account address             |
| `governance() view` / `pendingGovernance() view`     | anyone               | current / pending governance          |
| `isAdapterAllowed(ILendingAdapter) view`             | anyone               | allowlist status                      |
| `setAdapterAllowed(ILendingAdapter, bool)`           | governance           | curate allowlist                      |
| `transferGovernance(address)` / `acceptGovernance()` | governance / pending | two-step handoff                      |


### MarginAccount functions

`owner()`, `manager()` (views); `supplyCollateral`, `withdrawCollateral`, `borrow`, `repay`, `sweep`
(manager or owner; recipients constrained to manager/owner); `execute(adapter, adapterCall)` (owner
only escape hatch).

### Lending adapter read functions

All four adapters — `MorphoLendingAdapter`, `AaveLendingAdapter` (Aave v3), `AaveV4LendingAdapter`, and
`CompoundV3LendingAdapter` — expose the same `ILendingAdapter` reads: `lendingProtocol()`,
`isSupportedMarket(Market)`, `positionOf(account, Market)`, `maxLtvWad(Market)`,
`currentLtvWad(account, Market)`, plus `owner()`, `pendingOwner()`, `acceptOwnership()`, and
`transferOwnership(address)` for the two-step ownership handoff. The encode surface (see §3.3) is the
five encoders `encodeSupplyCollateral` / `encodeEnableCollateral` / `encodeWithdrawCollateral` /
`encodeBorrow` / `encodeRepay`; on the Aave adapters `encodeEnableCollateral` returns the venue's
explicit collateral-enable call, on Morpho and Compound the empty skip signal. Market routing is curated with
`setMarket` (owner-gated), and only the `setMarket` signature differs by venue:

- `MorphoLendingAdapter` registers a Morpho `MarketParams` (validating the market exists on Morpho).
- `AaveLendingAdapter.setMarket(Currency collateral, Currency debt, bool allowed)` allowlists a pair
after validating both are live Aave v3 reserves.
- `AaveV4LendingAdapter.setMarket(Currency collateral, Currency debt, uint256 collateralReserveId, uint256 debtReserveId, bool allowed)`
registers a route after validating on-chain that each reserve's `underlying` matches the currency and
that both reserves are on the same Hub. Its `lendingProtocol()` is the bound Spoke.
- `CompoundV3LendingAdapter.setMarket(Currency collateral, Currency debt, bool allowed)` allowlists a
pair after validating `debt` is the bound Comet's base token and `collateral` is a registered Comet
collateral asset. Its `lendingProtocol()` is the bound Comet.

(Note: `MarketSet`, emitted by all four on `setMarket`, carries the two `reserveId`s for the v4
adapter.)

### Errors


| Source   | Error                                                            | Meaning                                                                                                                   |
| -------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| router   | `DeadlinePassed(uint256)`                                        | `block.timestamp` past `deadline`                                                                                         |
| router   | `SlippageBoundRequired()`                                        | a mandatory bound (`maxDebtIn` / `maxCollateralIn` / `maxLtvAfter`) or amount (`collateralToBuy` / `debtToRepay`) is zero |
| router   | `IneffectiveLtvBound(Ltv)`                                       | a non-zero `maxLtvAfter` is at or above 100% (`1e18`), so it could never bind (supply a bound below 100%, or 0 to skip)   |
| router   | `PositionUnhealthy()`                                            | resulting LTV exceeds the bound                                                                                           |
| router   | `NoDebtToRepay()`                                                | a partial decrease targeted a debt-free position (nothing to repay; exit with a full close instead)                       |
| router   | `AdapterNotAllowed(address)`                                     | adapter not on the allowlist (exposure-increasing flows)                                                                  |
| router   | `NativeCollateralMismatch()`                                     | native ETH sent but collateral is not WETH                                                                                |
| router   | `IncompleteFill(uint256 requested, uint256 received)`            | the exact-output position swap (increase or decrease/close) under-filled (thin pool); the swap is all-or-nothing           |
| router   | `NoActiveAccount()`                                              | an `execute` plan ran an account-scoped action with no preceding `SET_ACCOUNT`                                            |
| V4Router | `V4TooMuchRequestedPerHopSingle(uint256 minPrice, uint256 priceX36)` | a swap's realized per-hop price fell below the caller's `minHopPriceX36` bound                                        |
| account  | `NotAuthorized()`                                                | caller is neither manager nor owner                                                                                       |
| account  | `ReceiverNotAllowed(address)`                                    | recipient is neither manager nor owner                                                                                    |
| Owner    | `NotOwner(address)` / `ZeroOwner()` / `NotPendingOwner(address)` | ownership guards                                                                                                          |
| adapter (Morpho) | `MorphoMarketNotCreated()`                              | `setMarket` for a market that does not exist on Morpho                                                                    |
| adapter (Aave v3/v4) | `MarketNotSupported(Currency, Currency)`           | an encode/read or `setMarket` for a `(collateral, debt)` pair that is not allowlisted/registered (Aave v3: or whose assets are not live reserves) |
| adapter (Aave v3/v4) | `ZeroAddress()`                                    | a required address is zero at construction (Aave v3: the resolved Pool or data provider; Aave v4: the Spoke)             |
| adapter (Aave v3/v4) | `AccountMismatch(address, address)`               | a withdraw was encoded for an account other than the caller (the account always passes its own address)                 |
| adapter (Aave v4) | `ReserveMismatch(uint256, address, address)`         | `setMarket` where a reserve's on-chain `underlying` does not match the currency it is registered for                     |
| adapter (Aave v4) | `HubMismatch(address, address)`                      | `setMarket` where the collateral and debt reserves are on different Hubs (a single v4 position cannot span Hubs)         |
| registry | `MarketNotSupported(Currency, Currency)`                         | the `(collateral, debt)` pair has no registered market (Morpho registry)                                                  |


### Events

`PositionUpdated` (a resulting-state snapshot emitted after every supply/withdraw/borrow/repay on
every router path: curated flows, `execute` plans, and the unlock-free `addCollateral` / zero-debt
close), `PositionIncreased`, `PositionDecreased` (a full close is a
`PositionDecreased` with the position emptied), `CollateralAdded`, `AdapterAllowed`,
`GovernanceTransferStarted`, `GovernanceTransferred` (router; `GovernanceTransferred` also fires at
construction, from the zero address, for the initial governance); `MarketSet`,
`OwnershipTransferStarted`, `OwnershipTransferred` (adapter; the ownership events cover construction
and both steps of the two-step handoff); `CollateralSupplied`, `CollateralWithdrawn`, `Borrowed`,
`Repaid`, `Swept` (account); `AccountCreated` (account factory). Indexers can key on `PositionUpdated`
for resulting state uniformly across curated and `execute` paths; the `Position*` increase/decrease
events add the per-operation deltas on the curated path — see §4.1.

Event-field caveats:

- The delta events report **requested** amounts where their NatSpec says so: a partial decrease's
`debtRepaid` is the caller's `debtToRepay` (a request above the live debt clamps at the venue and the
field then over-reports), and an increase's `equity` is the caller's contribution only (the
`OPEN_DELTA` supply also absorbs any idle balance the account already held). `PositionUpdated` always
carries measured resulting state — prefer it for accounting.
- Every `describePosition`-derived emission is **best-effort**: if the venue read reverts (oracle
downtime, de-registered market), the snapshot and the rich delta event are skipped rather than
reverting the completed mutation, so a mutation during venue downtime can emit only account-level and
venue events.
- The account's `CollateralWithdrawn` logs the **account's own balance delta**, which is zero on
Morpho, Aave v3, and Compound (their withdrawals deliver straight to the receiver); only Aave v4
routes through the account and logs the delivered amount.