# Uniswap v4 Periphery

Uniswap v4 is a new automated market maker protocol that provides extensibility and customizability to pools. `v4-periphery` hosts the logic that builds on top of the core pool logic like hook contracts, position managers, and even possibly libraries needed for integrations. The `v4-periphery` contracts in this repository are still in development and further periphery contracts have not yet been built.

## Contributing

If you’re interested in contributing please see the [contribution guidelines](https://github.com/Uniswap/v4-periphery/blob/main/CONTRIBUTING.md)!

## Local Deployment and Usage

To utilize the contracts and deploy to a local testnet, you can install the code in your repo with forge:

```solidity
forge install https://github.com/Uniswap/v4-periphery
```

If you are building hooks, it may be useful to inherit from the `BaseHook` contract:

```solidity

import {BaseHook} from 'v4-periphery/src/base/hooks/BaseHook.sol';

contract CoolHook is BaseHook {
    // Override the hook callbacks you want on your hook
    function beforeAddLiquidity(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params
    ) external override onlyByManager returns (bytes4) {
        // hook logic
        return BaseHook.beforeAddLiquidity.selector;
    }
}

```

## License

The license for Uniswap V4 Periphery is the GNU General Public License (GPL 2.0), see [LICENSE](https://github.com/Uniswap/v4-periphery/blob/main/LICENSE).
