/**
 * Canonical margin-trading deployment registry, keyed by Ponder chain name.
 * ponder.config.ts derives its contract config from this map.
 *
 * PENDING REDEPLOY. These are the deterministic CREATE2 addresses of the margin suite as it deploys
 * from the current source (router mined at salt
 * 0x00000000000000000000000000000000000000007683eee69543020390281140, governance
 * 0x58e28b95a2ee57c4E90613AFce9e8CCEED3aB1E8). They were verified with a `DeployMargin.s.sol` dry-run
 * against a mainnet fork: the router reproduces its mined vanity and every canonical market
 * registers. They differ from the previously deployed suite because the account/adapter bytecode
 * changed, so every margin address moved. Ship the indexer with these alongside the on-chain
 * broadcast, and set `startBlock` to the redeploy block at that time.
 */
export const deployments = {
  mainnet: {
    chainId: 1,
    /** MarginRouter (also emits the factory's AccountCreated). */
    marginRouter: "0x0000000007e3176429aDD4f6F0280d5dbd11aeC8",
    /** MorphoLendingAdapter. */
    morphoAdapter: "0x08e4C6b61D99B6f2AD472c16ECE641F63F5635D5",
    /** AaveLendingAdapter (Aave v3). */
    aaveAdapter: "0x2c0bDc6786D285665337Ce7d544C8bC80a23A55C",
    /** AaveV4LendingAdapter. */
    aaveV4Adapter: "0xaC98DBcdC8c9f665372BbBE68C6A9123A8CbA6Eb",
    /** CompoundV3LendingAdapter. */
    compoundAdapter: "0xAaD2B75B9557748a16216f991613deFE42134c36",
    /** Morpho Blue singleton. */
    morphoBlue: "0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb",
    /** Aave v3 Pool (resolved from the PoolAddressesProvider). */
    aaveV3Pool: "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2",
    /** Uniswap v4 PoolManager singleton. */
    poolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
    /** Compound v3 USDC Comet (cUSDCv3): the base=USDC market the Compound adapter routes through.
     *  Recorded for the deferred Comet truth layer (see src/aave.ts); not yet an indexed contract. */
    compoundComet: "0xc3d688B66703497DAA19211EEdff47f25384cdc3",
    /** First block of the margin suite deployment. Everything is indexed from here, including
     *  PoolManager Initialize (pools created earlier have no `pool` metadata row; their fee tier is
     *  still on `swapEvent.fee`). TODO: set to the redeploy block once the suite above is broadcast;
     *  25598384 belonged to the superseded deployment. */
    startBlock: 25598384,
  },
} as const;
