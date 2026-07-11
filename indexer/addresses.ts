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
    marginRouter: "0x0000000666Adc6Ecc1A344fDB78F369B64F84444",
    /** MorphoLendingAdapter. */
    morphoAdapter: "0xe32286F0217d7dF340Fbc002d65d65bf1049A8C4",
    /** AaveLendingAdapter (Aave v3). */
    aaveAdapter: "0xb0cAca4f622E6391dA0Ce6b5fBA8B1c7470b15dB",
    /** AaveV4LendingAdapter. */
    aaveV4Adapter: "0xCfbdeb0F5281bEd39A57b93cB9C345aD7AB0FC20",
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
    startBlock: 25505653,
  },
} as const;
