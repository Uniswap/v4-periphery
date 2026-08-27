// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {ISwapAndAdd} from "../../../src/interfaces/ISwapAndAdd.sol";
import {BttBase} from "./BttBase.sol";

contract AuthAndResolveRecipientTest is BttBase {
    address internal owner;
    address internal operator;
    address internal stranger;
    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();
        owner = makeAddr("owner");
        operator = makeAddr("operator");
        stranger = makeAddr("stranger");
        MockERC20(Currency.unwrap(currency0)).mint(owner, 100e18);
        MockERC20(Currency.unwrap(currency1)).mint(owner, 100e18);
        _approveZapFor(owner, currency0);
        _approveZapFor(owner, currency1);

        ISwapAndAdd.AddParams memory p = _addParams(5e18, 5e18);
        p.recipient = owner;
        vm.prank(owner);
        (tokenId,,,) = zap.add(p);
    }

    function test_WhenCallerIsOwner_ReturnsRequested() public {
        // it returns the requested recipient
        address requested = makeAddr("dest");
        vm.prank(owner);
        address resolved = zap.exposedAuthAndResolveRecipient(tokenId, requested);
        assertEq(resolved, requested, "owner may choose recipient");
    }

    function test_WhenCallerIsTokenApproved_ReturnsOwner() public {
        // it returns the owner (operator cannot redirect)
        vm.prank(owner);
        IERC721(address(lpm)).approve(operator, tokenId);
        vm.prank(operator);
        address resolved = zap.exposedAuthAndResolveRecipient(tokenId, operator);
        assertEq(resolved, owner, "operator output forced to owner");
    }

    function test_WhenCallerIsApprovedForAll_ReturnsOwner() public {
        // it returns the owner (operator cannot redirect)
        vm.prank(owner);
        IERC721(address(lpm)).setApprovalForAll(operator, true);
        vm.prank(operator);
        address resolved = zap.exposedAuthAndResolveRecipient(tokenId, operator);
        assertEq(resolved, owner, "operator-for-all output forced to owner");
    }

    function test_WhenCallerIsStranger_Reverts() public {
        // it reverts with {NotAuthorizedForToken}
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.NotAuthorizedForToken.selector, tokenId));
        zap.exposedAuthAndResolveRecipient(tokenId, stranger);
    }
}
