# Uniswap v4 Margin Trading — Protocol & Integration Guide

A periphery that lets a user open a leveraged spot position in a single transaction by composing a
Uniswap v4 swap with a borrow/supply against an external lending protocol. Three venues are integrated
today (Morpho Blue, Aave v3, and Aave v4), all behind the same router; the caller selects the venue
per call by passing the matching adapter. This document explains how the system works and how to
integrate with it from both smart contracts and a front end.

---

## 1. Overview

A "margin" position is leveraged spot exposure:

1. Borrow the **debt** token from the lending protocol.
2. Swap the **debt** token into the **collateral** token through a v4 pool (exact-output).
3. Supply the collateral (your equity plus the bought amount) to the lending protocol.

The sequence runs inside one `PoolManager` unlock using v4 flash accounting, which lets us swap debt tokens we don't have yet for the collateral we'll use to borrow it. The result is a position that is **long the collateral token and short the debt token**, at a leverage chosen by the caller and bounded only by the maximum LTV of the chosen market.

Each user's position lives in their own **`MarginAccount`** — a minimal, soulbound contract that is
itself the borrower/supplier in the lending protocol. The **`MarginRouter`** orchestrates the flows
and is the trusted manager of every account it deploys. A **lending adapter** (`MorphoLendingAdapter`
for Morpho Blue, `AaveLendingAdapter` for Aave v3, `AaveV4LendingAdapter` for Aave v4) translates
protocol-agnostic intents into the concrete calls the account executes. All implement the same
`ILendingAdapter` surface, so the router flows are identical regardless of venue.

---

## 2. Architecture

```
   User / EOA / integrating contract
        │  openPosition · closePosition · decreasePosition · addCollateral
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
  ┌──────────  Morpho Blue / Aave v3 Pool / Aave v4 Spoke  ──────────┐
```


| Contract               | Role                                                                                                                                                                                                                                         |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MarginRouter`         | The entry point. Builds and runs each flow inside a `PoolManager` unlock. Inherits `V4Router`, `ReentrancyLock`, `Permit2Forwarder`, `Multicall_v4`, `NativeWrapper`, and the account factory. The router is the `manager` of every account. |
| `MarginAccount`        | A per-user clone (Solady clone-with-immutable-args). It is the lending counterparty (`onBehalf == account`), so it acts as itself and needs no delegated authorization. Owner and manager are baked into bytecode (soulbound).               |
| lending adapters       | Singleton encoders over a governed `(collateral, debt)` routing table. `MorphoLendingAdapter` targets Morpho Blue; `AaveLendingAdapter` targets the Aave v3 Pool; `AaveV4LendingAdapter` targets a single Aave v4 Spoke. Each returns the `(target, value, callData)` an account executes and holds no funds. The caller picks a venue by passing the matching adapter. |
| `ILendingAdapter`      | The protocol-agnostic surface the router and account depend on. New lending protocols are supported by new adapters.                                                                                                                         |
| value types            | `Market` (the `(collateral, debt)` pair), `Ltv` (WAD ratio), `LeverageX18` (WAD multiplier), `MarketRegistry`, `Owner`.                                                                                                                      |


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

### 3.2 The MarginAccount

- **One account per `(owner, subId)`.** `subId` is a caller-chosen index so one address can hold many
independent positions. The address is deterministic: `router.accountOf(owner, subId)` returns it
whether or not it has been deployed yet.
- **One Aave position per account.** Aave (v3, and a given v4 Spoke) tracks health and reserve
balances across the whole account, not per `(collateral, debt)` pair, so each Aave position must live
in its own `(owner, subId)` account: open a second Aave market under a *new* `subId`, never the same
one. The router does not enforce this. Re-using a `subId` for two markets on the same Aave deployment
blends their collateral/debt and can make a later `closePosition`/`decreasePosition` revert or withdraw
collateral still backing the other debt. Morpho markets are isolated and not subject to this.
- **Soulbound.** The owner and the manager (the router) are baked into the clone's bytecode at
deployment. There is no initializer and no transfer path.
- **Self-custody with a manager.** The account's fund-moving primitives (`supplyCollateral`,
`withdrawCollateral`, `borrow`, `repay`, `sweep`) are callable only by the **manager (router)** or
the **owner**. Recipients of withdrawals/borrows/sweeps are constrained to the manager or owner, so
funds can never be redirected to a third party.
- **Owner escape hatch.** `execute(adapter, market, callData)` is owner-only and forwards a call to
the adapter's lending protocol as the account. This lets the owner always manage or exit a position
directly on the lending protocol without the router (for example if the router is paused or an
adapter is removed).

### 3.3 Lending adapter and the allowlist

The adapter is an **encoder**: each `encode`* returns `(target, value, callData)`, and the account
executes it after checking the target is the adapter's `lendingProtocol()` and the value is zero.
Governance maintains an **allowlist** of adapters. The allowlist gates only the operations that *add*
exposure — `openPosition`, `addCollateral`. **Closing and delevering never require
an allowlisted adapter**, so a position can always be unwound even if its adapter is later removed.

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
(liquidation LTV, `maxLtvWad`) at borrow time, so an open that would exceed it reverts. `decreasePosition`
additionally enforces a caller-supplied `maxLtvAfter` bound. `Ltv` is a WAD value (`1e18 == 100%`).

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

Every position swap is a **single-hop exact-output** swap:

- `maxDebtIn` (open/increase) / `maxCollateralIn` (close/decrease) is the **mandatory, binding**
slippage bound: the absolute cap on the swap input. Derive it from a quote, not spot price.
- `minHopPriceX36` is an **optional** additional per-hop price bound (X36 fixed-point). Zero disables
only that secondary check; it does not relax the binding absolute cap. It is redundant with the
absolute cap for a single hop, so it may be left zero. When set, it is enforced against the swap's
**realized** output, so an under-filled swap that executes below the bound reverts
(`V4TooMuchRequestedPerHopSingle`).
- `deadline` is a Unix timestamp; the call reverts (`DeadlinePassed`) if `block.timestamp` exceeds it.
- **Opens are all-or-nothing on amount.** A v4 exact-output swap can partially fill on a thin pool.
`openPosition` requires the swap to deliver the full `collateralToBuy` and revert
(`IncompleteFill`) otherwise, rather than opening a smaller position than requested. `minHopPriceX36`
bounds the *price*; the exact-output amount is bounded by this all-or-nothing check.

---

## 4. Operations

All entry points operate on the caller's own account, derived from the authenticated caller and
`subId`; an account address is never accepted from calldata.


| Operation                    | Params                | Effect                                                                                                                                                                       |
| ---------------------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `openPosition` (payable)     | `OpenParams`          | Deploys the account if needed, pulls equity, opens a leveraged position. Calling again on an account that already holds a position adds leverage to it; set `equity = 0` and send no value for a pure leverage increase. |
| `addCollateral` (payable)    | `AddCollateralParams` | Supplies more collateral without changing debt (delevers / improves health). No swap.                                                                                        |
| `decreasePosition`           | `DecreaseParams`      | Repays `debtToRepay` by selling collateral; position stays open. Enforces `maxLtvAfter`.                                                                                     |
| `closePosition`              | `CloseParams`         | Repays all debt by selling collateral, withdraws all collateral, returns the residual (realized PnL) to the caller. A zero-debt position is withdrawn directly with no swap. |


**Open mechanics:** swap debt → `collateralToBuy` collateral (exact-out, input capped by
`maxDebtIn`) → take to the account → supply the account's full collateral balance → borrow the debt
owed → settle.

**Close mechanics:** swap collateral → exactly the current debt (exact-out, input capped by
`maxCollateralIn`) → take to the account → repay all by shares → withdraw all collateral → settle →
return the residual collateral delta to the caller.

**Decrease mechanics:** swap collateral → `debtToRepay` → repay → withdraw the collateral the swap
consumed → settle → assert the resulting LTV is `<= maxLtvAfter`.

---

## 5. Reading position state

Read through the adapter (amounts are interest-accrued):

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

    // WETH/USDC pool the leverage swap routes through (currencies sorted: USDC < WETH)
    PoolKey internal poolKey;

    constructor(IMarginRouter _router, ILendingAdapter _adapter, IAllowanceTransfer _permit2, PoolKey memory _key) {
        router = _router;
        adapter = _adapter;
        permit2 = _permit2;
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

        account = router.openPosition(
            IMarginRouter.OpenParams({
                adapter: adapter,
                market: market,
                poolKey: poolKey,
                equity: equity,
                collateralToBuy: collateralToBuy,
                maxDebtIn: maxDebtIn,
                minHopPriceX36: 0, // optional secondary bound; maxDebtIn is the binding cap
                subId: 0,
                deadline: block.timestamp + 15 minutes
            })
        );
    }
}
```

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

    account = router.openPosition{value: msg.value}(
        IMarginRouter.OpenParams({
            adapter: adapter,
            market: market,
            poolKey: poolKey,
            equity: 0, // ignored when msg.value > 0
            collateralToBuy: collateralToBuy,
            maxDebtIn: maxDebtIn,
            minHopPriceX36: 0,
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
    router.openPosition(
        IMarginRouter.OpenParams({
            adapter: adapter, market: market, poolKey: poolKey,
            equity: 0, collateralToBuy: buy, maxDebtIn: maxDebtIn,
            minHopPriceX36: 0, subId: 0, deadline: block.timestamp + 15 minutes
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
            adapter: adapter, market: market, poolKey: poolKey,
            debtToRepay: debtToRepay, maxCollateralIn: maxCollateralIn,
            minHopPriceX36: 0, maxLtvAfter: Ltv.wrap(0.7e18),
            subId: 0, deadline: block.timestamp + 15 minutes
        })
    );
}

// fully close; residual collateral (realized PnL) is sent to msg.sender
function close(Market memory market, uint128 maxCollateralIn) external {
    router.closePosition(
        IMarginRouter.CloseParams({
            adapter: adapter, market: market, poolKey: poolKey,
            maxCollateralIn: maxCollateralIn, minHopPriceX36: 0,
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
    IMarginAccount(account).execute(adapter, market, morphoRepayCall);
}
```

### 6.7 Notes for contract integrators

- The router derives the account from the authenticated caller (`msg.sender` of the entry point).
When your contract calls `openPosition`, the position belongs to your contract, and its residual on
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
  adapter: "0x<LENDING_ADAPTER>",      // fill in per deployment (Morpho, Aave v3, or Aave v4)
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
> `openPosition`. The on-chain `approve` above is the simplest path.

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
    poolKey,
    equity,
    collateralToBuy,
    maxDebtIn,
    minHopPriceX36: 0n,
    subId: 0n,
    deadline,
  };

  const { request } = await publicClient.simulateContract({
    account: user, address: ADDR.router, abi: marginRouterAbi, functionName: "openPosition", args: [params],
  });
  return walletClient.writeContract(request);
}
```

Native-ETH open is the same call with `equity: 0n` and a `value` field:

```ts
await walletClient.writeContract({
  account: user, address: ADDR.router, abi: marginRouterAbi, functionName: "openPosition",
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
async function closePosition(user: `0x${string}`, subId: bigint) {
  // size maxCollateralIn from current debt + a quote (omitted): cap the WETH sold
  const maxCollateralIn = parseUnits("5", 18);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 900);

  const { request } = await publicClient.simulateContract({
    account: user, address: ADDR.router, abi: marginRouterAbi, functionName: "closePosition",
    args: [{ adapter: ADDR.adapter, market, poolKey, maxCollateralIn, minHopPriceX36: 0n, subId, deadline }],
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
    args: [{ adapter: ADDR.adapter, market, poolKey, debtToRepay, maxCollateralIn, minHopPriceX36: 0n, maxLtvAfter, subId, deadline }],
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
`AaveLendingAdapter` to route through the Aave v3 Pool, or the `AaveV4LendingAdapter` to route through
an Aave v4 Spoke. Nothing else in the flow changes: all implement the same `ILendingAdapter` surface
and the router orchestrates them identically. Each adapter must be allowlisted by governance
(`router.setAdapterAllowed(adapter, true)`) before it can be used to *add* exposure; closing and
delevering never require an allowlisted adapter, so a position opened on any venue can always be
unwound. Whether a given `(collateral, debt)` pair is routable on a venue is read with
`adapter.isSupportedMarket(market)`.

`AaveLendingAdapter` is constructed from an Aave v3 `IPoolAddressesProvider`
(`constructor(IPoolAddressesProvider provider, address owner_)`); it resolves and stores the Pool and
the protocol data provider immutably. Governance enables a pairing with
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

- **Supply enables collateral atomically.** v4 `supply` does not auto-enable collateral, so
`encodeSupplyCollateral` batches `supply` and `setUsingAsCollateral` in a `Spoke.multicall`
(a delegatecall-to-self that preserves `msg.sender`, so the supply still pulls the underlying against
the account's allowance).
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

    account = router.openPosition(
        IMarginRouter.OpenParams({
            adapter: aaveAdapter,            // route through Aave v3
            market: market,                  // collateral USDC, debt WETH
            poolKey: usdcWethKey,
            equity: equityUsdc,              // 6d USDC
            collateralToBuy: collateralToBuyUsdc, // 6d USDC
            maxDebtIn: maxDebtInWeth,        // 18d WETH binding cap
            minHopPriceX36: 0,
            subId: 0,
            deadline: block.timestamp + 15 minutes
        })
    );
}
```

`OpenParams` carries no direction field: passing `Market(collateral: USDC, debt: WETH)` is what makes
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
router.openPosition(
    IMarginRouter.OpenParams({
        adapter: morphoAdapter,
        market: Market({collateral: Currency.wrap(weth), debt: Currency.wrap(usdc)}),
        poolKey: usdcWethKey,
        equity: equityWeth,              // 18d WETH
        collateralToBuy: longBuyWeth,    // 18d WETH
        maxDebtIn: longMaxDebtInUsdc,    // 6d USDC
        minHopPriceX36: 0,
        subId: 0,
        deadline: block.timestamp + 15 minutes
    })
);

// Leg 2: short ETH on subId 1 (collateral USDC, debt WETH)
router.openPosition(
    IMarginRouter.OpenParams({
        adapter: aaveAdapter,
        market: Market({collateral: Currency.wrap(usdc), debt: Currency.wrap(weth)}),
        poolKey: usdcWethKey,
        equity: equityUsdc,              // 6d USDC
        collateralToBuy: shortBuyUsdc,   // 6d USDC
        maxDebtIn: shortMaxDebtInWeth,   // 18d WETH
        minHopPriceX36: 0,
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
- **Adapter trust.** Adapters are governance-curated. The account constrains the call target to the
adapter's declared lending protocol and forbids value transfers and delegatecall — but an
allowlisted adapter is trusted; governance is responsible for vetting adapters it allowlists.
- **Governance.** The router's adapter allowlist and the adapter's market routing table are
governance-controlled. Ownership transfers are two-step and reject the zero address. Production
deployments should put governance behind a timelock or multisig.
- **Exit is always available.** Closing and delevering do not require an allowlisted adapter, and the
owner `execute` escape hatch can act directly on the lending protocol, so funds are never trapped by
router-side configuration.
- **Venue is swappable behind `ILendingAdapter`.** The lending venue is an implementation detail of
the adapter; a position can migrate to a new venue by allowlisting a new adapter, with no router or
account changes.
- **Lending and oracle risk is inherited.** Health, liquidation, and pricing are the lending
protocol's responsibility (Morpho Blue, Aave v3, or Aave v4, depending on the adapter); the margin
layer adds no independent oracle.
- **ERC-20 only.** Markets must use standard ERC-20 tokens (no fee-on-transfer or rebasing).

---

## 10. Deployment addresses

Margin contracts are deployment-specific; fill in the deployed `MarginRouter`, `MorphoLendingAdapter`,
`AaveLendingAdapter`, and `AaveV4LendingAdapter` for your target network. The following external
dependencies are verified on Ethereum mainnet:


| Contract                      | Address                                      | Notes                                                                             |
| ----------------------------- | -------------------------------------------- | --------------------------------------------------------------------------------- |
| MarginRouter                  | `0x<MARGIN_ROUTER>`                          | per deployment                                                                    |
| MorphoLendingAdapter          | `0x<MORPHO_ADAPTER>`                         | per deployment                                                                    |
| AaveLendingAdapter            | `0x<AAVE_ADAPTER>`                           | per deployment                                                                    |
| AaveV4LendingAdapter          | `0x<AAVE_V4_ADAPTER>`                        | per deployment; constructed against the Aave v4 Main Spoke                        |
| v4 PoolManager                | `0x<V4_POOL_MANAGER>`                        | from the official Uniswap v4 deployments for the network; verify with `cast code` |
| Permit2                       | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | canonical, same on all chains                                                     |
| Morpho Blue                   | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | mainnet                                                                           |
| Aave v3 PoolAddressesProvider | `0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e` | mainnet; resolves the Pool and protocol data provider for `AaveLendingAdapter`    |
| Aave v3 Pool                  | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` | mainnet; resolved from the addresses provider                                     |
| Aave v3 protocol data provider | `0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD` | mainnet; resolved from the addresses provider                                   |
| Aave v4 Main Spoke            | `0x94e7A5dCbE816e498b89aB752661904E2F56c485` | mainnet; the Spoke `AaveV4LendingAdapter` routes through (verify with `cast code`) |
| Aave v4 Core Hub              | `0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9` | mainnet; backs the Main Spoke's WETH and USDC reserves                            |
| Aave v4 Main Spoke oracle     | `0x99B2B6CEa9C3D2fd8F4d90f86741C44B212a6127` | mainnet; reserveId-keyed (`getReservesPrices`), 8-decimal USD base               |
| WETH                          | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | mainnet                                                                           |
| USDC                          | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | mainnet                                                                           |


Morpho WETH/USDC market (collateral WETH, loan USDC): oracle `0xdC6fd5831277c693b1054e19E94047cB37c77615`,
IRM `0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC`, LLTV `0.86e18`,
id `0x7dde86a1e94561d9690ec678db673c1a6396365f7d1d65e129c5fff0990ff758`.

Aave v3 USDC reserve (the collateral for a short ETH market): liquidation threshold `7800` bps
(`0.78`), which `AaveLendingAdapter.maxLtvWad` returns as `0.78e18`. The addresses and this threshold
were verified on a mainnet fork at block 25319047.

Aave v4 Main Spoke reserve ids: WETH is reserveId `0` (the debt leg of a short, borrowable) and USDC
is reserveId `7` (the collateral leg, collateral factor `7800` bps, which
`AaveV4LendingAdapter.maxLtvWad` returns as `0.78e18`). Both reserves are on the Core Hub. The
addresses, reserve ids, and collateral factor were verified on a mainnet fork at block 25330047.

> Never hardcode an address without verifying it on-chain (`cast code` / `cast call`) for the target
> network.

---

## 11. Reference

### Param structs

```solidity
struct OpenParams {        // openPosition
    ILendingAdapter adapter;
    Market market;
    PoolKey poolKey;
    uint256 equity;        // collateral equity (ignored if msg.value > 0)
    uint128 collateralToBuy;
    uint128 maxDebtIn;     // mandatory binding slippage cap
    uint256 minHopPriceX36;// optional per-hop bound (0 = off)
    uint256 subId;
    uint256 deadline;
}

struct CloseParams {       // closePosition
    ILendingAdapter adapter;
    Market market;
    PoolKey poolKey;
    uint128 maxCollateralIn; // mandatory on the swap path (ignored for a zero-debt close)
    uint256 minHopPriceX36;
    uint256 subId;
    uint256 deadline;
}

struct DecreaseParams {    // decreasePosition
    ILendingAdapter adapter;
    Market market;
    PoolKey poolKey;
    uint256 debtToRepay;
    uint128 maxCollateralIn;
    uint256 minHopPriceX36;
    Ltv maxLtvAfter;       // mandatory; resulting LTV must be <= this
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
| `openPosition(OpenParams) payable`                   | anyone               | own account; a second open adds leverage |
| `closePosition(CloseParams)`                         | anyone               | own account; no allowlist requirement |
| `decreasePosition(DecreaseParams)`                   | anyone               | own account; no allowlist requirement |
| `addCollateral(AddCollateralParams) payable`         | anyone               | own account                           |
| `accountOf(address owner, uint256 subId) view`       | anyone               | predicted account address             |
| `governance() view` / `pendingGovernance() view`     | anyone               | current / pending governance          |
| `isAdapterAllowed(ILendingAdapter) view`             | anyone               | allowlist status                      |
| `setAdapterAllowed(ILendingAdapter, bool)`           | governance           | curate allowlist                      |
| `transferGovernance(address)` / `acceptGovernance()` | governance / pending | two-step handoff                      |


### MarginAccount functions

`owner()`, `manager()` (views); `supplyCollateral`, `withdrawCollateral`, `borrow`, `repay`, `sweep`
(manager or owner; recipients constrained to manager/owner); `execute` (owner only).

### Lending adapter read functions

All three adapters — `MorphoLendingAdapter`, `AaveLendingAdapter` (Aave v3), and
`AaveV4LendingAdapter` — expose the same `ILendingAdapter` reads: `lendingProtocol()`,
`isSupportedMarket(Market)`, `positionOf(account, Market)`, `maxLtvWad(Market)`,
`currentLtvWad(account, Market)`, plus `owner()`, `pendingOwner()`, `acceptOwnership()`, and
`transferOwnership(address)` for the two-step ownership handoff. Market routing is curated with
`setMarket` (owner-gated), and only the `setMarket` signature differs by venue:

- `MorphoLendingAdapter` registers a Morpho `MarketParams` (validating the market exists on Morpho).
- `AaveLendingAdapter.setMarket(Currency collateral, Currency debt, bool allowed)` allowlists a pair
after validating both are live Aave v3 reserves.
- `AaveV4LendingAdapter.setMarket(Currency collateral, Currency debt, uint256 collateralReserveId, uint256 debtReserveId, bool allowed)`
registers a route after validating on-chain that each reserve's `underlying` matches the currency and
that both reserves are on the same Hub. Its `lendingProtocol()` is the bound Spoke. (Note: `MarketSet`,
emitted by all three on `setMarket`, carries the two `reserveId`s for the v4 adapter.)

### Errors


| Source   | Error                                                            | Meaning                                                                                                                   |
| -------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| router   | `DeadlinePassed(uint256)`                                        | `block.timestamp` past `deadline`                                                                                         |
| router   | `SlippageBoundRequired()`                                        | a mandatory bound (`maxDebtIn` / `maxCollateralIn` / `maxLtvAfter`) or amount (`collateralToBuy` / `debtToRepay`) is zero |
| router   | `PositionUnhealthy()`                                            | resulting LTV exceeds the bound                                                                                           |
| router   | `AdapterNotAllowed(address)`                                     | adapter not on the allowlist (exposure-increasing flows)                                                                  |
| router   | `NativeCollateralMismatch()`                                     | native ETH sent but collateral is not WETH                                                                                |
| router   | `IncompleteFill(uint256 requested, uint256 received)`            | the exact-output swap on open/increase under-filled (thin pool); the open is all-or-nothing                               |
| V4Router | `V4TooMuchRequestedPerHopSingle(uint256 minPrice, uint256 priceX36)` | a swap's realized per-hop price fell below the caller's `minHopPriceX36` bound                                        |
| account  | `NotAuthorized()`                                                | caller is neither manager nor owner                                                                                       |
| account  | `ReceiverNotAllowed(address)`                                    | recipient is neither manager nor owner                                                                                    |
| Market   | `MarketSwapMismatch()`                                           | pool currencies do not match the market pair                                                                              |
| Owner    | `NotOwner(address)` / `ZeroOwner()` / `NotPendingOwner(address)` | ownership guards                                                                                                          |
| adapter (Morpho) | `MorphoMarketNotCreated()`                              | `setMarket` for a market that does not exist on Morpho                                                                    |
| adapter (Aave v3/v4) | `MarketNotSupported(Currency, Currency)`           | an encode/read or `setMarket` for a `(collateral, debt)` pair that is not allowlisted/registered (Aave v3: or whose assets are not live reserves) |
| adapter (Aave v3/v4) | `ZeroAddress()`                                    | a required address is zero at construction (Aave v3: the resolved Pool or data provider; Aave v4: the Spoke)             |
| adapter (Aave v3/v4) | `AccountMismatch(address, address)`               | a withdraw was encoded for an account other than the caller (the account always passes its own address)                 |
| adapter (Aave v4) | `ReserveMismatch(uint256, address, address)`         | `setMarket` where a reserve's on-chain `underlying` does not match the currency it is registered for                     |
| adapter (Aave v4) | `HubMismatch(address, address)`                      | `setMarket` where the collateral and debt reserves are on different Hubs (a single v4 position cannot span Hubs)         |
| registry | `MarketNotSupported(Currency, Currency)`                         | the `(collateral, debt)` pair has no registered market (Morpho registry)                                                  |


### Events

`PositionOpened`, `PositionClosed`, `PositionDecreased`, `CollateralAdded`,
`AdapterAllowed`, `GovernanceTransferStarted`, `GovernanceTransferred` (router); `MarketSet` (adapter);
`AccountCreated` (account factory).