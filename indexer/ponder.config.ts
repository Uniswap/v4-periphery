import { createConfig, factory } from "ponder";

import {
  aaveAdapterAbi,
  aaveV3PoolAbi,
  aaveV4AdapterAbi,
  aaveV4SpokeAbi,
  compoundAdapterAbi,
  marginAccountAbi,
  marginRouterAbi,
  morphoAdapterAbi,
  morphoBlueAbi,
  poolManagerInitAbi,
} from "./abis";
import { deployments } from "./addresses";

const mainnet = deployments.mainnet;

export default createConfig({
  chains: {
    mainnet: { id: 1, rpc: process.env.PONDER_RPC_URL_1 },
  },
  contracts: {
    /** Lifecycle events: account creation, increases (open), decreases (close), adds. The
     *  handlers fetch each margin transaction's receipt to extract its v4 Swap logs: the swap
     *  caller is whatever Universal Router the route named (any address, per call), so PoolManager
     *  logs cannot be pre-filtered by sender (see recordTxSwaps in src/router.ts). */
    MarginRouter: {
      abi: marginRouterAbi,
      chain: "mainnet",
      address: mainnet.marginRouter,
      startBlock: mainnet.startBlock,
    },
    /**
     * Every MarginAccount clone, derived from the router's AccountCreated. Its events name BOTH
     * currencies, which is the only way to resolve an Aave flow whose reserve is shared by several
     * registered markets and whose account holds no position yet — the first-ever-open case, where the
     * registry has nothing to disambiguate with and no curated router event arrives to complete it.
     * Amounts are NOT read here; the venue events remain the single writer.
     */
    MarginAccounts: {
      abi: marginAccountAbi,
      chain: "mainnet",
      address: factory({
        address: mainnet.marginRouter,
        // Reuse the router ABI's own item rather than a parseAbiItem string, so the two cannot drift.
        event: marginRouterAbi.find((item) => item.type === "event" && item.name === "AccountCreated")!,
        parameter: "account",
      }),
      startBlock: mainnet.startBlock,
    },
    /** Venue registries: which lending market each (collateral, debt) pair routes to. */
    MorphoAdapter: {
      abi: morphoAdapterAbi,
      chain: "mainnet",
      address: mainnet.morphoAdapter,
      startBlock: mainnet.startBlock,
    },
    AaveAdapter: {
      abi: aaveAdapterAbi,
      chain: "mainnet",
      address: mainnet.aaveAdapter,
      startBlock: mainnet.startBlock,
    },
    AaveV4Adapter: {
      abi: aaveV4AdapterAbi,
      chain: "mainnet",
      address: mainnet.aaveV4Adapter,
      startBlock: mainnet.startBlock,
    },
    CompoundAdapter: {
      abi: compoundAdapterAbi,
      chain: "mainnet",
      address: mainnet.compoundAdapter,
      startBlock: mainnet.startBlock,
    },
    /**
     * Lending protocol truth: liquidations and escape-hatch flows. Not filterable
     * by our accounts at the log layer (onBehalf is dynamic), so handlers discard
     * events whose onBehalf/borrower is not a known margin account.
     */
    MorphoBlue: {
      abi: morphoBlueAbi,
      chain: "mainnet",
      address: mainnet.morphoBlue,
      startBlock: mainnet.startBlock,
    },
    AaveV3Pool: {
      abi: aaveV3PoolAbi,
      chain: "mainnet",
      address: mainnet.aaveV3Pool,
      startBlock: mainnet.startBlock,
    },
    AaveV4Spoke: {
      abi: aaveV4SpokeAbi,
      chain: "mainnet",
      address: mainnet.aaveV4Spoke,
      startBlock: mainnet.startBlock,
    },
    /**
     * Pool metadata for the "v4 / fee tier / hooks" sub-label. Indexed from the
     * margin deploy block, not v4 genesis: pools initialized earlier resolve with
     * no metadata row (their fee tier is still on `swapEvent.fee`).
     */
    PoolManagerInit: {
      abi: poolManagerInitAbi,
      chain: "mainnet",
      address: mainnet.poolManager,
      startBlock: mainnet.startBlock,
    },
  },
});
