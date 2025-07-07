// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPositionDescriptor} from "../../src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {IV4Quoter} from "../../src/interfaces/IV4Quoter.sol";
import {IStateView} from "../../src/interfaces/IStateView.sol";
import {PermissionedV4Router} from "../../src/hooks/permissionedPools/PermissionedV4Router.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

library Deploy {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function positionManager(
        address poolManager,
        address permit2,
        uint256 unsubscribeGasLimit,
        address positionDescriptor_,
        address wrappedNative,
        bytes memory salt
    ) internal returns (IPositionManager manager) {
        bytes memory args = abi.encode(poolManager, permit2, unsubscribeGasLimit, positionDescriptor_, wrappedNative);
        bytes memory initcode = abi.encodePacked(vm.getCode("PositionManager.sol:PositionManager"), args);
        assembly {
            manager := create2(0, add(initcode, 0x20), mload(initcode), salt)
        }
    }

    function permissionedPositionManager(
        address poolManager,
        address permit2,
        uint256 unsubscribeGasLimit,
        address positionDescriptor_,
        address wrappedNative,
        address wrappedTokenFactory,
        address permissionedHooks,
        bytes memory salt
    ) internal returns (IPositionManager manager) {
        bytes memory args = abi.encode(
            poolManager,
            permit2,
            unsubscribeGasLimit,
            positionDescriptor_,
            wrappedNative,
            wrappedTokenFactory,
            permissionedHooks
        );
        bytes memory initcode =
            abi.encodePacked(vm.getCode("PermissionedPositionManager.sol:PermissionedPositionManager"), args);
        assembly {
            manager := create2(0, add(initcode, 0x20), mload(initcode), salt)
        }
    }

    function stateView(address poolManager, bytes memory salt) internal returns (IStateView stateView_) {
        bytes memory args = abi.encode(poolManager);
        bytes memory initcode = abi.encodePacked(vm.getCode("StateView.sol:StateView"), args);
        assembly {
            stateView_ := create2(0, add(initcode, 0x20), mload(initcode), salt)
        }
    }

    function v4Quoter(address poolManager, bytes memory salt) internal returns (IV4Quoter quoter) {
        bytes memory args = abi.encode(poolManager);
        bytes memory initcode = abi.encodePacked(vm.getCode("V4Quoter.sol:V4Quoter"), args);
        assembly {
            quoter := create2(0, add(initcode, 0x20), mload(initcode), salt)
        }
    }

    function transparentUpgradeableProxy(address implementation, address admin, bytes memory data, bytes memory salt)
        internal
        returns (TransparentUpgradeableProxy proxy)
    {
        bytes memory args = abi.encode(implementation, admin, data);
        bytes memory initcode =
            abi.encodePacked(vm.getCode("TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"), args);
        assembly {
            proxy := create2(0, add(initcode, 0x20), mload(initcode), salt)
        }
    }

    function positionDescriptor(
        address poolManager,
        address wrappedNative,
        bytes32 nativeCurrencyLabelBytes,
        bytes memory salt
    ) internal returns (IPositionDescriptor descriptor) {
        bytes memory args = abi.encode(poolManager, wrappedNative, nativeCurrencyLabelBytes);
        bytes memory initcode = abi.encodePacked(vm.getCode("PositionDescriptor.sol:PositionDescriptor"), args);
        assembly {
            descriptor := create2(0, add(initcode, 0x20), mload(initcode), salt)
        }
    }

    function create2(bytes memory initcode, bytes32 salt) internal returns (address contractAddress) {
        assembly {
            contractAddress := create2(0, add(initcode, 32), mload(initcode), salt)
            if iszero(contractAddress) {
                let ptr := mload(0x40)
                let errorSize := returndatasize()
                returndatacopy(ptr, 0, errorSize)
                revert(ptr, errorSize)
            }
        }
    }
}
