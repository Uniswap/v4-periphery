# Margin Trading Indexer

A [Ponder](https://ponder.sh) indexer for the Uniswap margin trading stack (MarginRouter +
lending adapters). It reconstructs full position history — including fields the contracts
intentionally do not emit — purely from public onchain data, so any integrator offering
Uniswap-powered margin trading can serve transaction history without a privileged
write-through store.

## Quick start

```bash
cd indexer
npm install
cp .env.local.example .env.local   # set PONDER_RPC_URL_1
npm run dev                        # GraphQL at http://localhost:42069/graphql
```

Production: `npm start` with `DATABASE_URL` pointing at Postgres.

## What it indexes

| Source | Address (mainnet) | Purpose |
|---|---|---|
| MarginRouter | `0x0000000000F57fCd0d5a78a19907240F1169EDEC` | Lifecycle: `AccountCreated`, `PositionIncreased/Decreased`, `CollateralAdded`, `AdapterAllowed`, and `PositionUpdated` (resulting-state snapshot on every mutation, including `execute` plans) |
| MorphoLendingAdapter | `0x766C34DcFBA565a1b72ce83ECD96712376Ca1f3D` | `MarketSet` market registry (market id, oracle, LLTV) |
| Aave v3 adapter | `0x7E1A...098aC` | `MarketSet` market registry |
| Aave v4 adapter | `0xAb3C...AE2Eb` | `MarketSet` market registry |
| Compound v3 adapter | `0x7759...95e0d` | `MarketSet` market registry (venue `COMPOUND_V3`; Comet truth layer deferred) |
| Morpho Blue | `0xBBBB...FFCb` | Collateral/debt flows + `Liquidate`, attributed by `onBehalf` ∈ margin accounts |
| Aave v3 Pool | `0x8787...A4E2` | Flows + `LiquidationCall`, attributed by `onBehalfOf`/`user` |
| Aave v4 Spoke | `0x94e7...c485` | Flows + `LiquidationCall`, attributed by `onBehalfOf`/`user` |
| v4 PoolManager | `0x0000...8A90` | `Initialize` (pool metadata) from the margin deploy block; margin transactions' `Swap` logs are parsed from the transaction receipt by the router and flow layers (the swap caller is any Universal Router the route names) |

The full checksummed registry lives in `addresses.ts`.

## How the derivation works

The curated lifecycle events (`PositionIncreased`/`Decreased`, `CollateralAdded`) carry the
full position economics directly: equity, debt drawn, resulting totals, current/max LTV, and
health factor. Entry price is `debtDrawn / collateralBought` from a single log — the exact
execution cost including fees and price impact, protocol-agnostic across venues. The
lending-protocol logs (which precede the router event in each transaction) are still staged and
joined by tx hash, but only for venue/market attribution, liquidations, and flows that bypass the
router entirely (owner escape-hatch operations).

Positions composed through the general-purpose `execute` entrypoint emit no curated lifecycle
event, so the router also emits a `PositionUpdated` resulting-state snapshot (owner, account,
pair, resulting totals, current LTV, max/liquidation LTV, health factor) after every
supply/withdraw/borrow/repay on any path. The handler uses it to (1) fill the LTV/health/max-LTV
snapshot and reconcile totals on a live epoch, and (2) open an epoch for an `execute` position the
flow layer never created — an Aave v3 open whose single-reserve events could not resolve the pair,
or an Aave v4 / Compound v3 open (which have no flow-truth layer indexed yet). Such epochs carry
authoritative amounts, LTV, and health but leave economics (equity, entry price, leverage) empty
until a curated event adopts them; `openReported` stays false until then. `execute`-composed
positions are therefore observable at parity with curated ones, without any extra RPC.

## Field derivation map

Coverage of the transaction-history field list (see the internal
"Margin Transaction History: Field Derivation Map" doc). All amounts are raw token units
(join `token` for decimals); prices are X18 ratios of raw debt units per raw collateral
unit — scale by `10^(collateralDecimals - debtDecimals)` for a human price.

| UI field | Table.column | Derivation |
|---|---|---|
| Position/account discovery | `account`, `position.owner` | `AccountCreated`, indexed by owner |
| Pair | `position.collateral` / `.debt` | Router events |
| Pair sub-label (fee tier, hooks) | `position.openPoolId` → `pool` | Same-tx v4 `Swap` → `Initialize` metadata. No calldata decode or write-through needed |
| Lending venue | `position.venue` | Which protocol's events fired in the open tx |
| Direction | derived | Long the collateral, short the debt (client-side label) |
| Size | `position.totalCollateralBought`, `.collateralAmount` | `PositionOpened` accumulation; running amount maintained from lending events (principal only — live reads for interest-accrued debt) |
| Entry price | `position.avgEntryPriceX18`; per-fill `positionAction.priceX18` | `debtDrawn * 1e18 / collateralBought` from `PositionIncreased`; volume-weighted across increases |
| Exit price | `position.exitPriceX18` | Repay vs collateral sold on close |
| Margin (equity) | `position.equity` | Emitted directly on `PositionIncreased`; accumulated with `CollateralAdded` |
| Leverage at open | `position.leverageX18AtOpen` | `collateralTotal / equity` at first open (same-token ratio) |
| Liquidation price | `position.lltv` + amounts | `debtPrincipal / (collateralAmount × lltv)`; `lltv` (max/liquidation LTV) and `lastLtvWad`/`lastHealthFactorWad` snapshot router-reported state at the last mutation on any path (`PositionUpdated`, curated or `execute`); live accuracy needs an onchain `describePosition` read (interest drift) |
| PnL (completed) | `position.realizedPnl` | `collateralReturned − equity`, collateral units; % = vs `equity` |
| PnL (active) | client-side | mark vs `avgEntryPriceX18` on live `positionOf` amounts |
| Created | `position.openedAt` | Block timestamp, no extra RPC |
| Completed: user-closed | `position.status = CLOSED` | `PositionDecreased` with zero resulting totals (close is folded into decrease) |
| Completed: liquidated | `position.status = LIQUIDATED`, `liquidat*` columns | Morpho `Liquidate` / Aave `LiquidationCall` with borrower ∈ margin accounts; partial liquidations keep `OPEN` + `liquidated = true` |
| Raw account feed (incl. owner escape-hatch ops) | `lendingEvent` | Every attributed lending flow, even ones with no router event |

## Example queries

Positions for an owner (active + completed):

```graphql
{
  positions(where: { owner: "0x1199A3f7bEf0211db99d843e330f32400548c8AE" }) {
    items {
      id collateral debt venue status
      equity totalCollateralBought avgEntryPriceX18 leverageX18AtOpen
      openedAt openPoolId lltv
      collateralReturned exitPriceX18 realizedPnl
      liquidated liquidatedAt seizedCollateral
    }
  }
}
```

History feed for a position:

```graphql
{
  positionActions(where: { positionId: "..." }, orderBy: "timestamp", orderDirection: "asc") {
    items { type timestamp txHash collateralDelta debtDelta equityDelta priceX18 poolId }
  }
}
```

## Known limitations

- **Interest accrual**: `debtPrincipal` tracks principal from events; live debt (and
  therefore live liquidation price / PnL) needs an onchain `positionOf` read.
- **Aave v4 / Compound v3**: lifecycle rows (curated router events) and resulting-state
  snapshots (`PositionUpdated`, including `execute`-composed opens) both work, so amounts, LTV,
  and health are tracked. Still pending the venue truth layer (Aave Spoke / Comet event ABIs):
  per-flow `lendingEvent` rows, equity for `execute`-only positions (no curated event to supply
  it, so `openReported` stays false), and liquidation detection (see `src/aave.ts`).
- **Aave pair ambiguity**: Aave events carry one reserve; when several registered pairs
  share it, attribution falls back to the account's live positions and, failing that, the
  router event in the same tx. Supply-only actions to an account with multiple positions
  sharing a collateral token may stay unattributed in `lendingEvent`.
- **Multiple opens in one multicall tx**: swap attribution takes the first unconsumed
  swap; economics remain correct per pair, pool labels may cross-attribute.
- **Pre-existing pools**: `Initialize` is indexed from the margin deploy block, so a
  pool created before it has no `pool` metadata row (hooks/tickSpacing/currencies).
  The fee tier is still recorded per swap on `swapEvent.fee`. To resolve older pools
  fully, lower the PoolManager start block (v4 genesis is 21688329) and use Postgres
  rather than the embedded PGlite for the larger backfill.
- **Full-close dust sweep**: a full close sweeps residual dust back in the debt token via a `Swept`
  event that is not indexed in v1, so realized PnL can drift by the measured dust buffer
  (`sizeFullClose`) — dust-sized by construction.
- **Chains**: mainnet only today; add deployments to `addresses.ts` and mirror the
  contract entries in `ponder.config.ts`.
