/**
 * Canonical margin-trading deployment registry, keyed by Ponder chain name.
 *
 * All addresses verified onchain against the DeployMargin.s.sol broadcast for
 * chain 1 (the earlier test deployment is intentionally not indexed).
 * ponder.config.ts derives its contract config from this map.
 */
export const deployments = {
  mainnet: {
    chainId: 1,
    /** MarginRouter (also emits the factory's AccountCreated). */
    marginRouter: "0x0000000004BBC92D0657580CAe35aEBF054E5CDC",
    /** MorphoLendingAdapter. */
    morphoAdapter: "0x9A7f8F5A9496D3c9dc0BEEfb44cCaC17CAAF28fa",
    /** AaveLendingAdapter (Aave v3). */
    aaveAdapter: "0x8EeacdB24c7650478496845A61f03fF6BC263222",
    /** AaveV4LendingAdapter. */
    aaveV4Adapter: "0x3a9Cc5eEbAC911E5a316de1F2bCD166016d7469E",
    /** Morpho Blue singleton. */
    morphoBlue: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
    /** Aave v3 Pool (resolved from the PoolAddressesProvider). */
    aaveV3Pool: "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
    /** Uniswap v4 PoolManager singleton. */
    poolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
    /** First block of the margin suite deployment. Everything is indexed from
     *  here, including PoolManager Initialize: pools created before this block
     *  have no `pool` metadata row, but the fee tier is still available on
     *  `swapEvent.fee`. */
    startBlock: 25598384,
  },
} as const;
