// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UniversalRouter} from "universal-router/contracts/UniversalRouter.sol";

/// @dev Compile anchor: forces the concrete UniversalRouter into the build (under the via_ir script
///      profile) so tests can deploy it via `vm.getCode("UniversalRouter.sol:UniversalRouter")`
///      without importing the concrete contract into a via_ir=false test compilation (which would
///      stack-too-deep). Never deployed or called; it exists only to pull UR into the artifact set.
library URCompileAnchor {
    function creationCodeHash() internal pure returns (bytes32) {
        return keccak256(type(UniversalRouter).creationCode);
    }
}
