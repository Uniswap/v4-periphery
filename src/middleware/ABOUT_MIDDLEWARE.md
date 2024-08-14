# Middleware Docs
Hooks can be made to do bad things. Because anyone can create their own arbitrary logic for a hook contract, it's difficult for third parties to decide which hooks are "safe" and which are "dangerous". We propose a hook middleware that performs sanity checks on the result of a hooks to block malicious actions.

### Implementation
Middleware factory creates middlewares. Each middleware is the hook and points to another hook as the implementation.

https://github.com/user-attachments/assets/a7016ed2-2863-42aa-bc69-54fe2549e016

This allows for some convenient configurations where a pool can use a hook and another pool can use the middlewared hook.

<img src="https://github.com/user-attachments/assets/a6734509-3f82-4e9e-8652-058a1b34eea4" alt="middleware configurations" width="500">

*all valid configurations that can be deployed. animations for illustration only.*

Best of all, attaching a middleware to a hook is easy and usually requires no extra coding.

### Caveats
- (because of the proxy pattern) constructors will never be called, so it may be necessary to revise the implementation contract to use an initialize function if the constructor needs to set non-immutable variables.
- let's say hook A calls a permissioned function on external contract E. a middleware pointing to hook A would then not be able to call contract E.
- be mindful of proxy storage collisions between the middleware and the implementation.

### Deployment
Developers should mine a salt to generate the correct flags for the middleware. While not strictly required, it’s recommended to match the hook’s flags with the middleware’s flags.

# Middleware Remove
An incorrectly written or malicious hook could revert while removing liquidity, potentially bricking funds or holding user funds hostage. A hook may also take a significant amount of deltas when removing liquidity, trapping the user into a high withdraw fee.

MiddlewareRemove is one possible middleware, designed to catch this problem.

It has two key properties:
1. If an implementation call violates a principle (defined below) the entire implementation call undoes itself, and the action proceeds as if it never was called.
   - eg: a user withdraws, the beforeRemove reverts, but the afterRemove succeeds. The withdrawal proceeds, running only the afterRemove hook.
3. If an implementation call does not violate principals, the user can not purpousely force a vanilla withdraw.
   - eg: a FeeTaking hook takes a 1% fee and the middleware specifies a 100 maxFeeBips. A user cannot alter the pool state to purpousely circumvent the hook.

### Implementation
`MiddlewareRemoveFactory` takes a parameter `maxFeeBips` and deploys either a `MiddlewareRemoveNoDeltas` (0 fee) or `MiddlewareRemove` contract (capped fee). This middleware checks for the following:

- **Reverts:** Implementation calls can not revert
- **Gas Limit:** Implementation calls can not use more than 5 million gas units
- **Function Selector:** Implementation calls must return the correct function selector, either `BaseHook.beforeRemoveLiquidity.selector` or `BaseHook.afterRemoveLiquidity.selector`
- **Correct Modification of Deltas:** Implementation calls can not modify any deltas during beforeRemoveLiquidity.

| MiddlewareRemoveNoDeltas | MiddlewareRemove |
| --- | --- |
| can not modify any deltas during beforeAfterLiquidity | can only modify deltas attributed to the hook or caller, only on the two currencies of the pair |
|  | the deltas modified must match the returned BalanceDelta |
|  | this amount is capped at an immutable percent of user output specified by maxFeeBips. _eg: if a user removes 1000 USDC and 1 ETH and maxFeeBips is 100, the hook can take maximum 10 USDC and/or 0.01 ETH._ |

If any of these conditions are violated, the contract will skip the hook call entirely.

### Rationale
While routers can protect against front-running during swaps and adding liquidity, they cannot prevent a hook from withholding tokens. This onchain middleware wraps every case that could cause a withdrawal to fail. Although this middleware does not prevent the hook from swapping before a user removes liquidity (which may change the token composition withdrawn), such behavior is not necessarily malicious towards the user.

The `maxFeeBips` parameter provides developers with greater flexibility, allowing them to set a clear cap on deltas they are allowed to take from the user.

### Deployment Parameters
- **implementation**
- **maxFeeBips:** An immutable value that caps the amount of deltas returned by the hook, providing a safeguard against excessive fees.

### Deployment Example
```solidity
uint256 maxFeeBips = 0;
(, bytes32 salt) = MiddlewareMiner.find(address(factory), flags, address(manager), implementation, maxFeeBips);
address hookAddress = factory.createMiddleware(implementation, maxFeeBips, salt);

```

### Gas Snapshots
|  | Unprotected | Protected | Diff |
| --- | --- | --- | --- |
| Before + After remove (only proxy) | 124,822 | 128,379 | 3,557 |
| Before + After remove (OVERRIDE) | 124,822 | 133,820 | 8,998 |
| Before + After remove | 124,822 | 135,757 | 10,935 |
| Before + After remove + returns deltas | 124,851 | 138,303 | 13,452 |
| Before + After remove + takes fee | 181,009 | 197,499 | 16,490 |

### Override
There is a small gas overhead when using the middleware.

An advanced caller who is confident that the checks will pass can skip them by passing a hookData starting with OVERRIDE_BYTES. The remaining bytes will then be used to do a standard hook call.

# Middleware Protect
A malicious hook could frontrun a user in the beforeSwap hook, extracting value at the cost of the user.

MiddlewareProtect is one possible middleware, designed to revert if this happens.

Before any hooks are called, it quotes the output amount. Then, in the afterSwap hook, it compares the output amount to the quote. If they differ, the swap reverts.

> [!IMPORTANT]  
> You must mine the implementation hook address.

> [!NOTE]
> If your middleware uses the beforeSwap flag, it must also use the afterSwap flag, even if the implementation does not use afterSwap.

### Gas Snapshots
|  | Unprotected | Protected | Diff |
| --- | --- | --- | --- |
| Single-tick swap | 124,869 | 151,501 | 26,632 |
| Multi-tick swap | 143,854 | 184,020 | 40,166 |