// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * Script: DeployPosmTest
 * Purpose: Deploy PositionDescriptor and PositionManager (PosM) configured for a chain
 * Usage:
 *   forge script script/DeployPosm.s.sol:DeployPosmTest --rpc-url $RPC --private-key $PK --broadcast \
 *   --sig "run(address,address,uint256,address,bytes32)" <POOL_MANAGER> <PERMIT2> <UNSUBSCRIBE_GAS_LIMIT> <WETH9> <NATIVE_LABEL_BYTES>
 * Params:
 *   poolManager: v4 PoolManager address
 *   permit2: Permit2 contract address for token transfers
 *   unsubscribeGasLimit: gas allocated for unsubscribe notifications
 *   wrappedNative: WETH9 (or chain’s wrapped native) address
 *   nativeCurrencyLabelBytes: 32-byte label used by descriptor (e.g., symbol)
 */

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Deploy, IPositionDescriptor, IPositionManager} from "../test/shared/Deploy.sol";
import {IWETH9} from "../src/interfaces/external/IWETH9.sol";

/// @title DeployPosmTest Script
/// @notice Deploys PositionDescriptor and PositionManager for a given chain
contract DeployPosmTest is Script {
    /// @notice Optional pre-run setup
    function setUp() public {}

    /// @notice Deploy PositionDescriptor and PositionManager
    /// @param poolManager PoolManager address
    /// @param permit2 Permit2 address
    /// @param unsubscribeGasLimit Gas limit for unsubscribe notifications
    /// @param wrappedNative Wrapped native (e.g., WETH9) address
    /// @param nativeCurrencyLabelBytes 32-byte label for native currency
    /// @return positionDescriptor The deployed position descriptor
    /// @return posm The deployed position manager
    function run(
        address poolManager,
        address permit2,
        uint256 unsubscribeGasLimit,
        address wrappedNative,
        bytes32 nativeCurrencyLabelBytes
    ) public returns (IPositionDescriptor positionDescriptor, IPositionManager posm) {
        vm.startBroadcast();

        positionDescriptor = Deploy.positionDescriptor(poolManager, wrappedNative, nativeCurrencyLabelBytes, hex"00");
        console2.log("PositionDescriptor", address(positionDescriptor));

        posm = Deploy.positionManager(
            poolManager, permit2, unsubscribeGasLimit, address(positionDescriptor), wrappedNative, hex"03"
        );
        console2.log("PositionManager", address(posm));

        vm.stopBroadcast();
    }
}
