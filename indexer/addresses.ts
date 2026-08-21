/**
 * Canonical margin-trading deployment registry, keyed by Ponder chain name.
 * ponder.config.ts derives its contract config from this map.
 *
 * The live mainnet margin suite (DeployMargin.s.sol broadcast, blocks 25740584-25740598), verified
 * onchain: contract code, governance 0x58e28b95a2ee57c4E90613AFce9e8CCEED3aB1E8, the adapter
 * allowlist, and every canonical market read back true. This deployment carries the
 * unlock-free-path PositionUpdated emissions (addCollateral and the zero-debt swap-free close) and
 * the IAmountResolver adapter surface, so the CollateralAdded pair-resolution fallbacks in
 * src/router.ts only matter for transactions older than `startBlock` (there are none: indexing
 * starts at the redeploy).
 */
export const deployments = {
  mainnet: {
    chainId: 1,
    /** MarginRouter (also emits the factory's AccountCreated). */
    marginRouter: "0x000000000075e82F7B7DdC5DD1B4984b560eF5D4",
    /** MorphoLendingAdapter. */
    morphoAdapter: "0x70fD13dF8C827ab71AE300D24b771C19B67d178A",
    /** AaveLendingAdapter (Aave v3). */
    aaveAdapter: "0x79D243C83e2D351aBbe8010a7E95162998475719",
    /** AaveV4LendingAdapter. */
    aaveV4Adapter: "0x917D08052E2994B75cF82bDaF6314b07532f2556",
    /** CompoundV3LendingAdapter. */
    compoundAdapter: "0x3625D6F7ccA2e8F95aF2E6497075D1a3E32dC5C6",
    /** Morpho Blue singleton. */
    morphoBlue: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
    /** Aave v3 Pool (resolved from the PoolAddressesProvider). */
    aaveV3Pool: "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
    /** Uniswap v4 PoolManager singleton. */
    poolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
    /** Compound v3 USDC Comet (cUSDCv3): the base=USDC market the Compound adapter routes through.
     *  Recorded for the deferred Comet truth layer (see src/aave.ts); not yet an indexed contract. */
    compoundComet: "0xc3d688B66703497DAA19211EEdff47f25384cdc3",
    /** First block of the margin suite deployment (the redeploy broadcast's first receipt).
     *  Everything is indexed from here, including PoolManager Initialize (pools created earlier
     *  have no `pool` metadata row; their fee tier is still on `swapEvent.fee`). */
    startBlock: 25740584,
  },
} as const;
