import { createConfig } from "ponder";

import {
  aaveAdapterAbi,
  aaveV3PoolAbi,
  aaveV4AdapterAbi,
  marginRouterAbi,
  morphoAdapterAbi,
  morphoBlueAbi,
  poolManagerInitAbi,
  poolManagerSwapAbi,
} from "./abis";
import { deployments } from "./addresses";

const mainnet = deployments.mainnet;

export default createConfig({
  chains: {
    mainnet: { id: 1, rpc: process.env.PONDER_RPC_URL_1 },
  },
  contracts: {
    /** Lifecycle events: account creation, opens, closes, decreases, adds. */
    MarginRouter: {
      abi: marginRouterAbi,
      chain: "mainnet",
      address: mainnet.marginRouter,
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
    /**
     * Lending protocol truth: collateral/debt flows and liquidations. Not filterable
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
    /** Margin swaps only: the router is always the swap sender for position flows. */
    PoolManagerSwaps: {
      abi: poolManagerSwapAbi,
      chain: "mainnet",
      address: mainnet.poolManager,
      startBlock: mainnet.startBlock,
      filter: {
        event: "Swap",
        args: { sender: mainnet.marginRouter },
      },
    },
  },
});
