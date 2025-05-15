//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library CustomRevertDecoder {
    function decode(bytes memory err)
        internal
        pure
        returns (
            bytes4 wrappedErrorSelector,
            address revertingContract,
            bytes4 revertingFunctionSelector,
            bytes4 revertrevertReasonSelector,
            bytes memory revertReason,
            bytes4 additionalContextSelector
        )
    {
        assembly {
            wrappedErrorSelector := mload(add(err, 0x20))
            revertingContract := mload(add(err, 0x24))
            revertingFunctionSelector := mload(add(err, 0x44))

            let offsetRevertReason := mload(add(err, 0x64))
            let offsetAdditionalContext := mload(add(err, 0x84))
            let sizeRevertReason := mload(add(err, add(offsetRevertReason, 0x24)))

            revertrevertReasonSelector := mload(add(err, add(offsetRevertReason, 0x44)))
            additionalContextSelector := mload(add(err, add(offsetAdditionalContext, 0x44)))

            let ptr := mload(0x40)
            revertReason := ptr
            mstore(revertReason, sizeRevertReason)

            let w := not(0x1f)

            for { let s := and(add(sizeRevertReason, 0x20), w) } 1 {} {
                mstore(add(revertReason, s), mload(add(err, add(offsetRevertReason, add(0x24, s)))))
                s := add(s, w)
                if iszero(s) { break }
            }

            mstore(0x40, add(ptr, add(0x20, sizeRevertReason)))
        }
    }
}
