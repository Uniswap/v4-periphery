// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/// @dev Replace import with your own hook
import {MockCounterHook} from "../test/mocks/MockCounterHook.sol";

/// @notice Mines the address and deploys the Counter.sol Hook contract
contract DeployHookScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    /// @dev Replace with the desired PoolManager on its corresponding chain
    IPoolManager constant POOLMANAGER = IPoolManager(address(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543));

    function setUp() public {}

    function run() public {
        // hook contracts must have specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(POOLMANAGER);

        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(MockCounterHook).creationCode, constructorArgs);

        // Deploy the hook using CREATE2
        vm.broadcast();
        MockCounterHook counter = new MockCounterHook{salt: salt}(IPoolManager(POOLMANAGER));
        require(address(counter) == hookAddress, "CounterScript: hook address mismatch");
    }
}
