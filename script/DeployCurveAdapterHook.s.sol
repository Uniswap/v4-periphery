// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {CurveAdapterHook} from "../src/hooks/CurveAdapterHook.sol";
import {ICurveOracle} from "../src/hooks/CurveAdapterHook.sol";

/// @notice Deploys the CurveAdapterHook contract with proper hook flags
contract DeployCurveAdapterHookScript is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    /// @dev Replace with the desired PoolManager on its corresponding chain
    IPoolManager constant POOLMANAGER = IPoolManager(address(0x000000000004444c5dc75cB358380D2e3dE08A90));
    
    /// @dev Replace with the actual Curve oracle contract address
    address constant CURVE_ORACLE = address(0x07D91f5fb9Bf7798734C3f606dB065549F6893bb);
    
    /// @dev Replace with the actual Curve 2pool contract address
    address constant CURVE_2POOL = address(0x4f493B7dE8aAC7d55F71853688b1F7C8F0243C85);

    function setUp() public {}

    function run() public {
        // Hook contracts must have specific flags encoded in the address
        // Based on BaseLiquidityAdapterHook permissions:
        // - beforeInitialize: true
        // - beforeSwap: true  
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.BEFORE_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(POOLMANAGER, CURVE_ORACLE, CURVE_2POOL);

        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(CurveAdapterHook).creationCode, constructorArgs);

        console.log("Mined hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));
        console.log("PoolManager:", address(POOLMANAGER));
        console.log("CurveOracle:", CURVE_ORACLE);
        console.log("Curve2Pool:", CURVE_2POOL);

        // Deploy the hook using CREATE2
        vm.broadcast();
        CurveAdapterHook curveAdapter = new CurveAdapterHook{salt: salt}(
            IPoolManager(POOLMANAGER),
            ICurveOracle(CURVE_ORACLE),
            CURVE_2POOL
        );
        
        require(address(curveAdapter) == hookAddress, "CurveAdapterHookScript: hook address mismatch");
        
        console.log("CurveAdapterHook deployed at:", address(curveAdapter));
    }
}
