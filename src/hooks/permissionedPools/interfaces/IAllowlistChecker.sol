// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IAllowlistChecker is IERC165 {
    function checkAllowList(address account) external view returns (bool);
}
