// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {IReservesLens} from "../src/interfaces/IReservesLens.sol";
import {ReservesLens} from "../src/lens/ReservesLens.sol";

contract DeployReservesLens is Script {
    address private constant CANONICAL_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function setUp() public {}

    /// @notice Deploys through the cross-chain deterministic deployment proxy.
    /// @dev Example: forge script --broadcast --sig 'run(bytes32)' --rpc-url <RPC_URL>
    ///      --private-key <PRIV_KEY> script/DeployReservesLens.s.sol:DeployReservesLens <SALT>
    function run(bytes32 salt) public returns (IReservesLens lens) {
        bytes memory initcode = type(ReservesLens).creationCode;
        address expected = _computeAddress(salt, keccak256(initcode));
        require(CANONICAL_CREATE2_DEPLOYER.code.length != 0, "canonical CREATE2 deployer missing");

        vm.startBroadcast();
        if (expected.code.length == 0) {
            (bool success,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(salt, initcode));
            require(success && expected.code.length != 0, "ReservesLens deployment failed");
        }
        vm.stopBroadcast();

        lens = IReservesLens(expected);
        console2.log("ReservesLens", expected);
        console2.logBytes32(keccak256(expected.code));
    }

    function _computeAddress(bytes32 salt, bytes32 initcodeHash) private pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CANONICAL_CREATE2_DEPLOYER, salt, initcodeHash))))
        );
    }
}
