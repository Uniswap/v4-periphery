// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BaseAllowlistChecker} from "../../../src/hooks/permissionedPools/BaseAllowListChecker.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("MockToken", "MT") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockPermissionedToken is MockToken {
    mapping(address account => bool allowed) public isAllowed;

    error Unauthorized();

    function setAllowlist(address account, bool allowed) public {
        isAllowed[account] = allowed;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (!isAllowed[to]) revert Unauthorized();
        super._update(from, to, amount);
    }
}

contract MockAllowlistChecker is BaseAllowlistChecker {
    MockPermissionedToken public token;

    constructor(MockPermissionedToken token_) {
        token = token_;
    }

    function checkAllowlist(address account) public view override returns (bool) {
        return token.isAllowed(account);
    }
}

contract PermissionedPoolsBase is Test {
    MockPermissionedToken public permissionedToken;
    MockAllowlistChecker public allowlistChecker;

    function setUp() public virtual {
        permissionedToken = new MockPermissionedToken();
        allowlistChecker = new MockAllowlistChecker(permissionedToken);
    }
}
