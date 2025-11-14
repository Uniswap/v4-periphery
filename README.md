# Uniswap v4 Periphery

A production-focused set of contracts and utilities that build on Uniswap v4 core. This repository provides routers with batched actions and per-hop slippage checks, position management via an ERC-721 position manager (PosM) supporting mint/increase/decrease/burn flows with settlement/take helpers, quoting/lens contracts for off-chain estimation via revert-encoding, base building blocks for hooks (e.g., BaseHook, SafeCallback, DeltaResolver), and libraries used by integrators.

The periphery is under active development; APIs may evolve as v4 matures. Review audits in `audits/` and run the comprehensive Foundry test suite before integrating. When integrating, ensure remappings point to `@uniswap/v4-core` and `v4-periphery`, target Solidity 0.8.24+ on the Cancun EVM, and prefer via-IR with the optimizer enabled.

## Contents
- `src/V4Router.sol`: internal swap routing with batched actions, per-hop slippage checks, settlement/take helpers
- `src/PositionManager.sol`: ERC-721 position NFT minting/management (PosM), liquidity modify flows, notifier integration
- `src/lens/V4Quoter.sol`: off-chain quoting via revert-encoding (not gas-efficient; do not call on-chain)
- `src/lens/StateView.sol`: read-only views into pool and position state
- `src/base/*`: shared infrastructure (`BaseActionsRouter`, `SafeCallback`, `DeltaResolver`, `ReentrancyLock`, `NativeWrapper`, `Notifier`)
- `src/libraries/*`: calldata decoding, slippage checks, path utilities, amounts math, etc.
- `src/hooks/*`: example token wrapper hooks (e.g. WETH, wstETH)
- `script/*`: Foundry deploy/util scripts
- `test/*`: extensive Foundry tests and gas benchmarks

## Requirements
- Foundry (`forge`, `cast`)
- Uniswap v4 core as a dependency (via `remappings.txt`/`foundry.toml`)
- Solidity 0.8.24+ (some contracts use transient storage opcodes; tested on Cancun EVM)

## Install & Build
```bash
forge install https://github.com/Uniswap/v4-periphery
forge build
```
If using as a submodule, add remappings for `@uniswap/v4-core` and `v4-periphery` and run `forge build`.

Example remappings (adjust to your repo):
```ini
@uniswap/v4-core/=lib/v4-core/
v4-periphery/=lib/v4-periphery/
forge-std/=lib/forge-std/src/
solmate/=lib/solmate/src/
```
Foundry config hints (`foundry.toml`):
- `solc_version = "0.8.26"` (compatible with `0.8.24+`)
- `evm_version = "cancun"`
- `via_ir = true`
- enable optimizer with appropriate runs per file

## Quickstart
- Position management: call `modifyLiquidities` with a batched action payload to mint/increase/decrease/burn positions while atomically settling/taking credits.
- Swaps: invoke router actions (`SWAP_EXACT_IN`, `SWAP_EXACT_OUT`, single/multi-hop) with optional per-hop slippage controls, then settle/take.
- Quoting: use `V4Quoter` off-chain to estimate amounts and gas before executing on-chain.

Example: Hook skeleton
```solidity
import {BaseHook} from 'v4-periphery/src/utils/BaseHook.sol';
import {IHooks} from '@uniswap/v4-core/src/interfaces/IHooks.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';

contract CoolHook is BaseHook {
    constructor(IPoolManager manager) BaseHook(manager) {}
    function getHookPermissions() public pure override returns (IHooks.Permissions memory) {
        // enable only the callbacks you need
        return IHooks.Permissions({
            beforeInitialize: true,
            beforeAddLiquidity: true,
            beforeSwap: true,
            beforeSwapReturnDelta: false,
            afterSwap: false,
            afterInitialize: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeDonate: false,
            afterDonate: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
```

## Scripts
```bash
forge script script/DeployV4Quoter.s.sol --rpc-url $RPC --private-key $PK --broadcast
forge script script/DeployPositionManager.s.sol --rpc-url $RPC --broadcast
forge script script/DeployV4Router.s.sol --rpc-url $RPC --broadcast
```
Use environment variables or `.env`; do not commit secrets.

## Testing
```bash
forge test -vvv
```
- Gas snapshots in `snapshots/`
- Scenario tests cover swaps, liquidity flows, notifier behavior, and edge cases
- Fuzzing defaults can be tuned via `foundry.toml` (e.g., `fuzz_runs`)

## Design Notes
- Actions are executed inside `PoolManager.unlock` via `SafeCallback.unlockCallback`, ensuring only the v4 `PoolManager` drives execution.
- Deltas: `_take` and `_settle` in `DeltaResolver` manage positive/negative credits; special constants like `OPEN_DELTA` and `CONTRACT_BALANCE` enable ergonomic flows.
- Slippage: `SlippageCheck` validates principal deltas on liquidity operations; router enforces min-out/max-in across hops and per-hop slippage checks.
- Reentrancy: transient lock via `ReentrancyLock`; `msgSender()` returns the locker for correct attribution.

## Audits & Security
- Audit drafts and reports are available in `audits/`
- Callback protection: only `PoolManager` may call `unlockCallback`
- ETH handling: `NativeWrapper` only accepts ETH from trusted sources (e.g., `WETH9` or `PoolManager`)
- Follow best practices for key management and deployment; validate inputs and slippage parameters

## Contributing
Please read the [CONTRIBUTING.md](./CONTRIBUTING.md). Run lint/tests before submitting PRs.

## License
MIT. See [LICENSE](./LICENSE).
