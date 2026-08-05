// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UniversalRouter} from "universal-router/contracts/UniversalRouter.sol";

/// @dev Build-only compile anchor (never deployed or imported). Forces the concrete UniversalRouter
///      into the artifact set so the margin route helpers can deploy it via
///      `vm.getCode("UniversalRouter.sol:UniversalRouter")`.
///
///      It lives in `src/` on purpose: `forge test` compiles every `src/` file at the default
///      `via_ir = true` profile, but does NOT compile `script/` (so a script anchor is missing from the
///      artifact set under `forge test`, which is how CI runs). It cannot live under `test/`, because
///      `test/**` is pinned to `via_ir = false` and UniversalRouter stack-too-deeps without the IR
///      pipeline. Keeping it here makes the router resolvable under both `forge build` and `forge test`.
library URCompileAnchor {
    function creationCodeHash() internal pure returns (bytes32) {
        return keccak256(type(UniversalRouter).creationCode);
    }
}
