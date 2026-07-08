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
| MarginRouter | `0x000000a16bfA211d163C244427acE70dD9014444` | Lifecycle: `AccountCreated`, `PositionOpened/Closed/Decreased`, `CollateralAdded`, `AdapterAllowed` |
| MorphoLendingAdapter | `0xAc150756CAa1e7b821AE2ef4b6f66030A715d474` | `MarketSet` market registry (market id, oracle, LLTV) |
| Aave v3 / v4 adapters | `0xFb28...0C21` / `0x9Fe1...486C` | `MarketSet` market registries |
| Morpho Blue | `0xBBBB...FFCb` | Collateral/debt flows + `Liquidate`, attributed by `onBehalf` ∈ margin accounts |
| Aave v3 Pool | `0x8787...A4E2` | Flows + `LiquidationCall`, attributed by `onBehalfOf`/`user` |
| v4 PoolManager | `0x0000...8A90` | `Initialize` (pool metadata) + `Swap` filtered to `sender == MarginRouter` — both from the margin deploy block |

## How the derivation works

Within every position transaction, the protocol logs (v4 `Swap`, lending
supply/borrow/repay/withdraw) precede the router's lifecycle event. Handlers stage those
rows, and the router-event handler joins them by transaction hash to derive the economics
the router does not emit. The open flow borrows exactly the swap's settle amount, so the
lending `Borrow` event is the exact execution cost of the levered tranche, fees and price
impact included — protocol-agnostic across Morpho and Aave, single- or multi-hop.

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
| Entry price | `position.avgEntryPriceX18`; per-fill `positionAction.priceX18` | `Borrow.assets * 1e18 / collateralBought` — exact fill incl. fees; volume-weighted across increases |
| Exit price | `position.exitPriceX18` | Repay vs collateral sold on close |
| Margin (equity) | `position.equity` | `SupplyCollateral.assets − collateralBought` per open, + `CollateralAdded`. **Not** write-through: derived from lending events |
| Leverage at open | `position.leverageX18AtOpen` | `totalSupplied / equity` at first open (same-token ratio) |
| Liquidation price | `position.lltv` + amounts | `debtPrincipal / (collateralAmount × lltv)` at any time; for live accuracy use onchain `currentLtvWad` (interest drift) |
| PnL (completed) | `position.realizedPnl` | `collateralReturned − equity`, collateral units; % = vs `equity` |
| PnL (active) | client-side | mark vs `avgEntryPriceX18` on live `positionOf` amounts |
| Created | `position.openedAt` | Block timestamp, no extra RPC |
| Completed: user-closed | `position.status = CLOSED` | `PositionClosed` |
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
- **Aave v4**: lifecycle rows work (router events), but flow amounts, equity derivation,
  and liquidation detection await the Spoke event ABI (see `src/aave.ts`).
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
- **Chains**: mainnet only today; add deployments to `addresses.ts` and mirror the
  contract entries in `ponder.config.ts`.
