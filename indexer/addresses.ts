/**
 * Canonical margin-trading deployment registry, keyed by Ponder chain name.
 *
 * All addresses verified onchain (cast code / cast call) against the
 * DeployMargin.s.sol broadcast for chain 1. Add new chains here as the suite
 * is deployed; ponder.config.ts derives its contract config from this map.
 */
export const deployments = {
  mainnet: {
    chainId: 1,
    /** MarginRouter (also emits the factory's AccountCreated). */
    marginRouter: "0x000000a16bfA211d163C244427acE70dD9014444",
    /** MorphoLendingAdapter. */
    morphoAdapter: "0xAc150756CAa1e7b821AE2ef4b6f66030A715d474",
    /** AaveLendingAdapter (Aave v3). */
    aaveAdapter: "0xFb28e7f1a4d0E0f0e3Da2B40054Be64974410C21",
    /** AaveV4LendingAdapter. */
    aaveV4Adapter: "0x9Fe19c1803038732746416DC6F65171e7C37486C",
    /** Morpho Blue singleton. */
    morphoBlue: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
    /** Aave v3 Pool (resolved from the PoolAddressesProvider). */
    aaveV3Pool: "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
    /** Uniswap v4 PoolManager singleton. */
    poolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
    /** First block of the margin suite deployment. Everything is indexed from here,
     *  including PoolManager Initialize: pools created before this block have no
     *  `pool` metadata row, but the fee tier is still available on `swapEvent.fee`. */
    startBlock: 25482963,
  },
} as const;
