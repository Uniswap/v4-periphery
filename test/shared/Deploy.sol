// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPositionDescriptor} from "../../src/interfaces/IPositionDescriptor.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {StateView} from "../../src/lens/StateView.sol";
import {IV4Quoter} from "../../src/interfaces/IV4Quoter.sol";

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

    // no interface available, wrap in contract, this results in both versions being compiled, that's why we are importing the default version explicitly from the json file
    function stateView(address poolManager) internal returns (StateView stateView_) {
        bytes memory args = abi.encode(poolManager);
        bytes memory initcode = abi.encodePacked(vm.getCode("foundry-out/StateView.sol/StateView.default.json"), args);
        assembly {
            stateView_ := create(0, add(initcode, 0x20), mload(initcode))
        }
    }

    function v4Quoter(address poolManager) internal returns (IV4Quoter quoter) {
        bytes memory args = abi.encode(poolManager);
        bytes memory initcode = abi.encodePacked(vm.getCode("V4Quoter.sol:V4Quoter"), args);
        assembly {
            quoter := create(0, add(initcode, 0x20), mload(initcode))
        }
    }

    function positionDescriptor(address poolManager, address wrappedNative, string memory nativeCurrencyLabel)
        internal
        returns (IPositionDescriptor descriptor)
    {
        bytes memory args = abi.encode(poolManager, wrappedNative, nativeCurrencyLabel);
        bytes memory initcode = abi.encodePacked(vm.getCode("PositionDescriptor.sol:PositionDescriptor"), args);
        assembly {
            descriptor := create(0, add(initcode, 0x20), mload(initcode))
        }
    }
}
