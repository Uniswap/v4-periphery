# Sample Queries

Runnable GraphQL against the indexer (`http://localhost:42069/graphql` in dev). All hex
values are lowercase in storage and filters. `X18` prices are raw-unit ratios; scale by
`10^(collateralDecimals - debtDecimals)` (join `tokens`) for human prices.

## 1. All margin accounts owned by a user

An owner has one account per `subId`; every position belongs to an account.

```graphql
{
  accounts(where: { owner: "0x1199a3f7bef0211db99d843e330f32400548c8ae" }) {
    items { address subId createdAt createdTxHash }
  }
}
```

## 2. All positions for an owner, any status

The complete portfolio, newest first. This is the "Active + Completed" superset.

```graphql
{
  positions(
    where: { owner: "0x1199a3f7bef0211db99d843e330f32400548c8ae" }
    orderBy: "openedAt"
    orderDirection: "desc"
  ) {
    items {
      id account collateral debt venue status
      equity totalCollateralBought totalDebtDrawn
      avgEntryPriceX18 leverageX18AtOpen lltv
      collateralAmount debtPrincipal
      openedAt openTxHash openPoolId
      closedAt collateralReturned exitPriceX18 realizedPnl
      liquidated liquidatedAt seizedCollateral liquidationRepaidDebt badDebt
    }
  }
}
```

## 3. Active positions only (the "Active" tab)

```graphql
{
  positions(
    where: { owner: "0x1199a3f7bef0211db99d843e330f32400548c8ae", status: OPEN }
  ) {
    items {
      id collateral debt venue
      equity avgEntryPriceX18 leverageX18AtOpen
      collateralAmount debtPrincipal lltv
      openedAt openPoolId
    }
  }
}
```

UI derivations from this row:
- **Entry price** = `avgEntryPriceX18 * 10^(collateralDecimals - debtDecimals) / 1e18`
- **Liquidation price (event-tracked)** = `debtPrincipal * 1e18 / (collateralAmount * lltv)`
  scaled the same way; for exactness against accrued interest use a live
  `adapter.positionOf` / `currentLtvWad` read
- **PnL (active)** = mark vs entry on `collateralAmount` / `debtPrincipal`

## 4. Completed tab (user-closed and liquidated)

```graphql
{
  positions(
    where: {
      owner: "0x1199a3f7bef0211db99d843e330f32400548c8ae",
      status_in: [CLOSED, LIQUIDATED]
    }
    orderBy: "updatedAt"
    orderDirection: "desc"
  ) {
    items {
      id status venue equity
      collateralReturned exitPriceX18 realizedPnl
      liquidatedAt liquidationTxHash seizedCollateral liquidationRepaidDebt badDebt
    }
  }
}
```

- User-closed rows carry `collateralReturned` / `exitPriceX18` / `realizedPnl`
  (`collateralReturned - equity`, collateral units).
- Liquidated rows carry the liquidation economics instead.

## 5. Transaction-history feed for one position

Every lifecycle action with its deltas and per-fill execution price.

```graphql
{
  positionActions(
    where: { positionId: "<position.id>" }
    orderBy: "timestamp"
    orderDirection: "asc"
  ) {
    items {
      type timestamp txHash blockNumber
      collateralDelta debtDelta equityDelta
      priceX18 poolId
    }
  }
}
```

## 6. Pool sub-label for a position ("v4 · 0.05% · no hook")

```graphql
{
  pools(where: { poolId: "<position.openPoolId>" }) {
    items { poolId fee tickSpacing hooks currency0 currency1 }
  }
}
```

## 7. Raw account activity, including owner escape-hatch operations

Flows with no router lifecycle event (e.g. a direct `execute` collateral withdrawal)
appear here with `applied: false` and no `positionAction` row.

```graphql
{
  lendingEvents(
    where: { account: "0x7430d056212fe4a35992c65166d22e5c2823583c" }
    orderBy: "blockNumber"
    orderDirection: "asc"
  ) {
    items { kind venue assets seizedAssets applied morphoMarketId txHash timestamp }
  }
}
```

## 8. Token metadata for display scaling

```graphql
{
  tokens { items { address symbol decimals } }
}
```

## 9. Venue registry (which lending markets are routable)

```graphql
{
  lendingMarkets { items { id venue collateral debt allowed morphoMarketId lltv } }
  adapters { items { address venue allowed } }
}
```

## 10. Point lookups and pagination

```graphql
{ account(address: "0x7430d056212fe4a35992c65166d22e5c2823583c") { owner subId } }
```

Cursor pagination on any collection:

```graphql
{
  positionActions(limit: 2, orderBy: "timestamp", orderDirection: "asc") {
    items { type timestamp }
    pageInfo { hasNextPage endCursor }
  }
}
```

Pass `after: <endCursor>` for the next page.
