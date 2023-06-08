# Uniswap v4 Periphery

Uniswap v4 is a new automated market maker protocol that provides extensibility and customizability to pools. `v4-periphery` hosts the logic that builds on top of the core pool logic like hook contracts, position managers, and even possibly libraries needed for integrations. v4-periphery contracts including some of the canonical hooks are either still in development, or have not been built yet.

**Repository Structure**

There are a few canonical hook contracts that are currently being developed including the TWAMM and the Limit Order hook. To showcase the power of hooks, there is also an example folder that implements some interesting use cases. Note that none of these are production-ready, and the example hooks likely would not be the canonical design for those use cases but are useful to understand how hooks operate on pools.

```solidity
contracts/
---hooks/
     | TWAMM.sol
     | LimitOrder.sol
			---examples/
            | GeomeanOracle.sol
            | VolatilityOracle.sol
---libraries/
		 | Oracle.sol
BaseHook.sol
test/
```

**Local Deployment and Usage**

To utilize the contracts and deploy to a local testnet, you can install the code in your repo with forge:

```solidity
forge install https://github.com/Uniswap/periphery-next
```

If you are building hooks, it may be useful to inherit from the `BaseHook` contract:

```solidity
import {BaseHook} from 'periphery-next/contracts/BaseHook.sol'

contract CoolHook is BaseHook {
		// Override the hook callbacks you want on your hook
		function beforeModifyPosition(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params
    ) external override poolManagerOnly returns (bytes4) {
        // hook logic
				return BaseHook.beforeModifyPosition.selector;
    }

}
```

## Contributing

If you’re interested in contributing please see the [contribution guidelines](https://github.com/Uniswap/periphery-next/blob/main/CONTRIBUTING.md)!

Not all types of hooks will be safe or valuable to users. This repository will maintain a limited set of hook contracts. Even a well designed and safe hook contract may not be accepted in this repo.

## License

The license for Uniswap V4 Periphery is the GNU General Public License (GPL 2.0), see LICENSE(https://github.com/Uniswap/periphery-next/blob/main/LICENSE).