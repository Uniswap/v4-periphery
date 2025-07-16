// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ActionConstants} from "../../libraries/ActionConstants.sol";
import {ReentrancyLock} from "../../base/ReentrancyLock.sol";
import {V4Router, IPoolManager, Currency} from "../../V4Router.sol";
import {
    IWrappedPermissionedTokenFactory,
    IWrappedPermissionedToken
} from "./interfaces/IWrappedPermissionedTokenFactory.sol";
import {IWETH9} from "../../interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PermissionFlags} from "./libraries/PermissionFlags.sol";

contract PermissionedV4Router is V4Router, ReentrancyLock {
    IAllowanceTransfer public immutable PERMIT2;
    IWrappedPermissionedTokenFactory public immutable WRAPPED_TOKEN_FACTORY;
    IWETH9 public immutable WETH9;

    error Unauthorized();
    error HookNotImplemented();
    error InvalidEthSender();
    error CommandNotImplemented();
    error TransactionDeadlinePassed();
    error LengthMismatch();
    error SliceOutOfBounds();
    /// @notice Thrown when a required command has failed
    error ExecutionFailed(uint256 commandIndex, bytes message);

    // Commands
    uint256 constant COMMAND_V4_SWAP = 0x10;
    uint256 constant COMMAND_PERMIT2_PERMIT = 0x0a;
    bytes1 internal constant COMMAND_FLAG_ALLOW_REVERT = 0x80;
    bytes1 internal constant COMMAND_TYPE_MASK = 0x3f;

    constructor(
        IPoolManager poolManager_,
        IAllowanceTransfer permit2,
        IWrappedPermissionedTokenFactory wrappedTokenFactory,
        IWETH9 weth9
    ) V4Router(poolManager_) {
        PERMIT2 = permit2;
        WRAPPED_TOKEN_FACTORY = wrappedTokenFactory;
        WETH9 = weth9;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert TransactionDeadlinePassed();
        _;
    }

    /// @notice To receive ETH from WETH
    receive() external payable {
        if (msg.sender != address(WETH9) && msg.sender != address(poolManager)) revert InvalidEthSender();
    }

    /// @notice Executes encoded commands along with provided inputs. Reverts if deadline has expired.
    /// @param commands A set of concatenated commands, each 1 byte in length
    /// @param inputs An array of byte strings containing abi encoded inputs for each command
    /// @param deadline The deadline by which the transaction must be executed
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
    {
        execute(commands, inputs);
    }

    /// @notice Executes encoded commands along with provided inputs.
    /// @param commands A set of concatenated commands, each 1 byte in length
    /// @param inputs An array of byte strings containing abi encoded inputs for each command
    function execute(bytes calldata commands, bytes[] calldata inputs) public payable isNotLocked {
        bool success;
        bytes memory output;
        uint256 numCommands = commands.length;
        if (inputs.length != numCommands) revert LengthMismatch();

        // loop through all given commands, execute them and pass along outputs as defined
        for (uint256 commandIndex = 0; commandIndex < numCommands; commandIndex++) {
            bytes1 command = commands[commandIndex];

            bytes calldata input = inputs[commandIndex];

            (success, output) = dispatch(command, input);

            if (!success && successRequired(command)) {
                revert ExecutionFailed({commandIndex: commandIndex, message: output});
            }
        }
    }

    /// @notice Decodes and executes the given command with the given inputs
    /// @param commandType The command type to execute
    /// @param inputs The inputs to execute the command with
    /// @dev 2 masks are used to enable use of a nested-if statement in execution for efficiency reasons
    /// @return success True on success of the command, false on failure
    /// @return output The outputs or error messages, if any, from the command
    function dispatch(bytes1 commandType, bytes calldata inputs)
        public
        payable
        returns (bool success, bytes memory output)
    {
        uint256 command = uint8(commandType & COMMAND_TYPE_MASK);
        success = true;
        if (command == COMMAND_PERMIT2_PERMIT) {
            // equivalent: abi.decode(inputs, (IAllowanceTransfer.PermitSingle, bytes))
            IAllowanceTransfer.PermitSingle calldata permitSingle;
            assembly {
                permitSingle := inputs.offset
            }
            bytes calldata data = toBytes(inputs, 6); // PermitSingle takes first 6 slots (0..5)

            (success, output) = address(PERMIT2).call(
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
            revert CommandNotImplemented();
        }
    }

    /// @notice Public view function to be used instead of msg.sender, as the contract performs self-reentrancy and at
    /// times msg.sender == address(this). Instead msgSender() returns the initiator of the lock
    /// @dev overrides BaseActionsRouter.msgSender in V4Router
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    function _pay(Currency currency, address payer, uint256 amount) internal override {
        address permissionedToken = WRAPPED_TOKEN_FACTORY.verifiedPermissionedTokenOf(Currency.unwrap(currency));
        if (permissionedToken == address(0)) {
            // token is not a permissioned token, use the default implementation
            if (payer == address(this)) {
                currency.transfer(address(poolManager), amount);
            } else {
                // Casting from uint256 to uint160 is safe due to limits on the total supply of a pool
                PERMIT2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));
            }
            return;
        }
        // token is permissioned, wrap the token and transfer it to the pool manager
        IWrappedPermissionedToken wrappedPermissionedToken = IWrappedPermissionedToken(Currency.unwrap(currency));
        if (payer == address(this)) {
            // allowlist check necessary to ensure a disallowed user cannot sell a permissioned token
            if (!wrappedPermissionedToken.isAllowed(msgSender(), PermissionFlags.SWAP_ALLOWED)) {
                revert Unauthorized();
            }
            Currency.wrap(permissionedToken).transfer(address(wrappedPermissionedToken), amount);
            wrappedPermissionedToken.wrapToPoolManager(amount);
        } else {
            // token is a permissioned token, wrap the token
            PERMIT2.transferFrom(payer, address(wrappedPermissionedToken), uint160(amount), permissionedToken);
            wrappedPermissionedToken.wrapToPoolManager(amount);
        }
    }

    /// @notice Calculates the amount for a settle action
    function _mapSettleAmount(uint256 amount, Currency currency) internal view override returns (uint256) {
        address permissionedToken = WRAPPED_TOKEN_FACTORY.verifiedPermissionedTokenOf(Currency.unwrap(currency));
        // use the default implementation unless the currency is a permissioned token with a balance on the router
        if (permissionedToken == address(0) || amount != ActionConstants.CONTRACT_BALANCE) {
            return super._mapSettleAmount(amount, currency);
        }
        return Currency.wrap(permissionedToken).balanceOfSelf();
    }

    function successRequired(bytes1 command) internal pure returns (bool) {
        return command & COMMAND_FLAG_ALLOW_REVERT == 0;
    }

    /// @notice Decode the `_arg`-th element in `_bytes` as a dynamic array
    /// @dev This function is copied from BytesLib in universal-router to avoid adding it into the repositoriy
    function toLengthOffset(bytes calldata _bytes, uint256 _arg)
        private
        pure
        returns (uint256 length, uint256 offset)
    {
        uint256 relativeOffset;
        assembly {
            // The offset of the `_arg`-th element is `32 * arg`, which stores the offset of the length pointer.
            // shl(5, x) is equivalent to mul(32, x)
            let lengthPtr := add(_bytes.offset, calldataload(add(_bytes.offset, shl(5, _arg))))
            length := calldataload(lengthPtr)
            offset := add(lengthPtr, 0x20)
            relativeOffset := sub(offset, _bytes.offset)
        }
        if (_bytes.length < length + relativeOffset) revert SliceOutOfBounds();
    }

    /// @notice Decode the `_arg`-th element in `_bytes` as `bytes`
    /// @dev This function is copied from BytesLib in universal-router to avoid adding it into the repositoriy
    function toBytes(bytes calldata _bytes, uint256 _arg) private pure returns (bytes calldata res) {
        (uint256 length, uint256 offset) = toLengthOffset(_bytes, _arg);
        assembly {
            res.length := length
            res.offset := offset
        }
    }
}
