// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {PermissionFlag} from "../libraries/PermissionFlags.sol";

interface IAllowlistChecker is IERC165 {
    function checkAllowlist(address account) external view returns (PermissionFlag);
}
