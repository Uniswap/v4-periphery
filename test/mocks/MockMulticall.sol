// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "../../src/base/Multicall.sol";

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

contract MockMulticall is Multicall {
    error SimpleError();
    error ErrorWithParams(uint256 a, uint256 b);

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

    function functionThatRevertsWithSimpleError() external pure {
        revert SimpleError();
    }

    function functionThatRevertsWithErrorWithParams(uint256 a, uint256 b) external pure {
        revert ErrorWithParams(a, b);
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
}
