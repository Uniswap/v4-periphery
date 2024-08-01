// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "../../src/base/Multicall.sol";

contract MockMulticall is Multicall {
    error SimpleError();
    error ErrorWithParams(uint256 a, uint256 b);

    struct Tuple {
        uint256 a;
        uint256 b;
    }

    uint256 public msgValue;
    uint256 public msgValueDouble;

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
}
