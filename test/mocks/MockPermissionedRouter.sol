// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PermissionedV4Router} from "../../src/hooks/permissionedPools/PermissionedV4Router.sol";
import {IPermissionsAdapterFactory} from "../../src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IPermissionsAdapter} from "../../src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";

/// @notice Concrete router for testing the abstract PermissionedV4Router.
///         Mirrors the old standalone PermissionedV4Router's execute interface.
contract MockPermissionedRouter is PermissionedV4Router, ReentrancyLock {
    IAllowanceTransfer public immutable PERMIT2;
    IWETH9 public immutable WETH9;

    error InvalidEthSender();
    error TransactionDeadlinePassed();
    error LengthMismatch();
    error InvalidCommandType(uint256 commandType);
    error ExecutionFailed(uint256 commandIndex, bytes message);
    error SliceOutOfBounds();

    uint256 constant COMMAND_V4_SWAP = 0x10;
    uint256 constant COMMAND_PERMIT2_PERMIT = 0x0a;
    bytes1 internal constant COMMAND_FLAG_ALLOW_REVERT = 0x80;
    bytes1 internal constant COMMAND_TYPE_MASK = 0x3f;

    constructor(
        IPoolManager poolManager_,
        IAllowanceTransfer permit2_,
        IPermissionsAdapterFactory permissionsAdapterFactory_,
        IWETH9 weth9_
    ) PermissionedV4Router(poolManager_, permissionsAdapterFactory_) {
        PERMIT2 = permit2_;
        WETH9 = weth9_;
    }

    receive() external payable {
        if (msg.sender != address(WETH9) && msg.sender != address(poolManager)) revert InvalidEthSender();
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        if (block.timestamp > deadline) revert TransactionDeadlinePassed();
        execute(commands, inputs);
    }

    function execute(bytes calldata commands, bytes[] calldata inputs) public payable isNotLocked {
        bool success;
        bytes memory output;
        uint256 numCommands = commands.length;
        if (inputs.length != numCommands) revert LengthMismatch();

        for (uint256 commandIndex = 0; commandIndex < numCommands; commandIndex++) {
            bytes1 command = commands[commandIndex];
            bytes calldata input = inputs[commandIndex];
            (success, output) = _dispatch(command, input);
            if (!success && (command & COMMAND_FLAG_ALLOW_REVERT == 0)) {
                revert ExecutionFailed({commandIndex: commandIndex, message: output});
            }
        }
    }

    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    function _dispatch(bytes1 commandType, bytes calldata inputs) internal returns (bool success, bytes memory output) {
        uint256 command = uint8(commandType & COMMAND_TYPE_MASK);
        success = true;
        if (command == COMMAND_PERMIT2_PERMIT) {
            IAllowanceTransfer.PermitSingle calldata permitSingle;
            assembly {
                permitSingle := inputs.offset
            }
            bytes calldata data = _toBytes(inputs, 6);
            (success, output) = address(PERMIT2)
                .call(
                    abi.encodeWithSignature(
                        "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)",
                        msgSender(),
                        permitSingle,
                        data
                    )
                );
        } else if (command == COMMAND_V4_SWAP) {
            _executeActions(inputs);
        } else {
            revert InvalidCommandType(command);
        }
    }

    function _payStandard(Currency currency, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            currency.transfer(address(poolManager), amount);
        } else {
            PERMIT2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));
        }
    }

    function _payPermissionedFromPayer(
        address payer,
        IPermissionsAdapter permissionsAdapter,
        address permissionedToken,
        uint256 amount
    ) internal override {
        PERMIT2.transferFrom(payer, address(permissionsAdapter), uint160(amount), permissionedToken);
        permissionsAdapter.wrapToPoolManager(amount);
    }

    function _toBytes(bytes calldata _bytes, uint256 _arg) private pure returns (bytes calldata res) {
        uint256 length;
        uint256 offset;
        uint256 relativeOffset;
        assembly {
            let lengthPtr := add(_bytes.offset, calldataload(add(_bytes.offset, shl(5, _arg))))
            length := calldataload(lengthPtr)
            offset := add(lengthPtr, 0x20)
            relativeOffset := sub(offset, _bytes.offset)
        }
        if (_bytes.length < length + relativeOffset) revert SliceOutOfBounds();
        assembly {
            res.length := length
            res.offset := offset
        }
    }
}
