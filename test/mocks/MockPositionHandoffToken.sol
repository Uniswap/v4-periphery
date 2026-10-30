// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

/// @dev Funding token that hands a position to another account when it is pulled.
contract MockPositionHandoffToken is MockERC20 {
    IERC721 immutable posm;
    uint256 public tokenId;
    address public to;

    constructor(IERC721 _posm) MockERC20("Handoff", "HO", 18) {
        posm = _posm;
    }

    function setHandoff(uint256 _tokenId, address _to) external {
        tokenId = _tokenId;
        to = _to;
    }

    function transferFrom(address from, address recipient, uint256 amount) public override returns (bool) {
        if (to != address(0)) posm.transferFrom(posm.ownerOf(tokenId), to, tokenId);
        return super.transferFrom(from, recipient, amount);
    }
}
