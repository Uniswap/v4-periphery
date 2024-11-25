// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/base/Multicall_v4.sol";

/// @dev If MockMulticall is to PositionManager, then RevertContract is to PoolManager
contract RevertContract {
    error Error1();
    error Error2(uint256 a, uint256 b);

    function revertWithString(string memory error) external pure {
        revert(error);
    }

    function revertWithError1() external pure {
        revert Error1();
    }

    function revertWithError2(uint256 a, uint256 b) external pure {
        revert Error2(a, b);
    }
}

contract MockMulticall is Multicall_v4 {
    error Error4Bytes(); // 4 bytes of selector
    error Error36Bytes(uint8 a); // 32 bytes + 4 bytes of selector
    error Error68Bytes(uint256 a, uint256 b); // 64 bytes + 4 bytes of selector
    error ErrorBytes(bytes data); // arbitrary byte length

    struct Tuple {
        uint256 a;
        uint256 b;
    }

    uint256 public msgValue;
    uint256 public msgValueDouble;

    RevertContract public revertContract = new RevertContract();

    function functionThatRevertsWithString(string memory error) external pure {
        revert(error);
    }

    function functionThatReturnsTuple(uint256 a, uint256 b) external pure returns (Tuple memory tuple) {
        tuple = Tuple({a: a, b: b});
    }

    function payableStoresMsgValue() external payable {
        msgValue = msg.value;
    }

    function payableStoresMsgValueDouble() external payable {
        msgValueDouble = 2 * msg.value;
    }

    function returnSender() external view returns (address) {
        return msg.sender;
    }

    function externalRevertString(string memory error) external view {
        revertContract.revertWithString(error);
    }

    function externalRevertError1() external view {
        revertContract.revertWithError1();
    }

    function externalRevertError2(uint256 a, uint256 b) external view {
        revertContract.revertWithError2(a, b);
    }

    function revertWith4Bytes() external pure {
        revert Error4Bytes();
    }

    function revertWith36Bytes(uint8 a) external pure {
        revert Error36Bytes(a);
    }

    function revertWith68Bytes(uint256 a, uint256 b) external pure {
        revert Error68Bytes(a, b);
    }

    function revertWithBytes(bytes memory data) external pure {
        revert ErrorBytes(data);
    }
}
