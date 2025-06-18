// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAllowlistChecker, IERC165} from "./interfaces/IAllowlistChecker.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

abstract contract BaseAllowlistChecker is IAllowlistChecker, ERC165 {
    function checkAllowList(address account) public view virtual returns (bool);

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IAllowlistChecker).interfaceId || super.supportsInterface(interfaceId);
    }
}
