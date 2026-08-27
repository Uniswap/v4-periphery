/**
 * Canonical margin-trading deployment registry, keyed by Ponder chain name.
 * ponder.config.ts derives its contract config from this map.
 *
 * The live mainnet margin suite (DeployMargin.s.sol broadcast, blocks 25842465-25842483, commit
 * 0df9a61), verified onchain: contract code, governance
 * 0x58e28b95a2ee57c4E90613AFce9e8CCEED3aB1E8, the adapter allowlist, and every canonical market
 * read back true. This is the post-audit suite: it carries the full OpenZeppelin fix set (delta
 * fill checks, encodeEnableCollateral, measured-repay gating, owner-lifecycle events) on top of
 * the unlock-free-path PositionUpdated emissions and the IAmountResolver adapter surface, so the
 * CollateralAdded pair-resolution fallbacks in src/router.ts only matter for transactions older
 * than `startBlock` (there are none: indexing starts at the redeploy). The superseded 2026-08-12
 * router 0x000000000075e82F7B7DdC5DD1B4984b560eF5D4 remains live onchain but is not indexed.
 */
export const deployments = {
  mainnet: {
    chainId: 1,
    /** MarginRouter (also emits the factory's AccountCreated). */
    marginRouter: "0x0000000000F57fCd0d5a78a19907240F1169EDEC",
    /** MorphoLendingAdapter. */
    morphoAdapter: "0x766C34DcFBA565a1b72ce83ECD96712376Ca1f3D",
    /** AaveLendingAdapter (Aave v3). */
    aaveAdapter: "0x7E1A543Bd8ed2F16D61DA4b6bC2eC5d240D098aC",
    /** AaveV4LendingAdapter. */
    aaveV4Adapter: "0xAb3C2661c810295Db32125942f04b92c61fAE2Eb",
    /** CompoundV3LendingAdapter. */
    compoundAdapter: "0x77598B845d0200fc707bD32A8Ad6DCF85C995e0d",
    /** Morpho Blue singleton. */
    morphoBlue: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
    /** Aave v3 Pool (resolved from the PoolAddressesProvider). */
    aaveV3Pool: "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
    /** Aave v3 protocol data provider (resolved from the PoolAddressesProvider; same registry as
     *  docs/margin-trading.md section 10, verified onchain during the audit). Used only for
     *  read-time variable-debt token resolution; Aave can repoint it, in which case update here. */
    aaveV3DataProvider: "0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD",
    /** Uniswap v4 PoolManager singleton. */
    poolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
    /** Compound v3 USDC Comet (cUSDCv3): the base=USDC market the Compound adapter routes through.
     *  Recorded for the deferred Comet truth layer (see src/aave.ts); not yet an indexed contract. */
    compoundComet: "0xc3d688B66703497DAA19211EEdff47f25384cdc3",
    /** First block of the margin suite deployment (the redeploy broadcast's first receipt).
     *  Everything is indexed from here, including PoolManager Initialize (pools created earlier
     *  have no `pool` metadata row; their fee tier is still on `swapEvent.fee`). */
    startBlock: 25842465,
  },
} as const;
