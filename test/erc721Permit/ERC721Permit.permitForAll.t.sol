// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {SignatureVerification} from "permit2/src/libraries/SignatureVerification.sol";

import {ERC721PermitHash} from "../../src/libraries/ERC721PermitHash.sol";
import {MockERC721Permit} from "../mocks/MockERC721Permit.sol";
import {IERC721Permit_v4} from "../../src/interfaces/IERC721Permit_v4.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {IUnorderedNonce} from "../../src/interfaces/IUnorderedNonce.sol";

contract ERC721PermitForAllTest is Test {
    MockERC721Permit erc721Permit;
    address alice;
    uint256 alicePK;
    address bob;
    uint256 bobPK;

    string constant name = "Mock ERC721Permit_v4";
    string constant symbol = "MOCK721";

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");

        erc721Permit = new MockERC721Permit(name, symbol);
    }

    // --- Test the overriden setApprovalForAll ---
    function test_fuzz_setApprovalForAll(address operator) public {
        assertEq(erc721Permit.isApprovedForAll(address(this), operator), false);

        vm.expectEmit(true, true, true, true, address(erc721Permit));
        emit IERC721.ApprovalForAll(address(this), operator, true);
        erc721Permit.setApprovalForAll(operator, true);
        assertEq(erc721Permit.isApprovedForAll(address(this), operator), true);
    }

    function test_fuzz_setApprovalForAll_revoke(address operator) public {
        assertEq(erc721Permit.isApprovedForAll(address(this), operator), false);
        erc721Permit.setApprovalForAll(operator, true);
        assertEq(erc721Permit.isApprovedForAll(address(this), operator), true);

        vm.expectEmit(true, true, true, true, address(erc721Permit));
        emit IERC721.ApprovalForAll(address(this), operator, false);
        erc721Permit.setApprovalForAll(operator, false);
        assertEq(erc721Permit.isApprovedForAll(address(this), operator), false);
    }

    // --- Test the signature-based approvals (permitForAll) ---
    function test_permitForAllTypeHash() public pure {
        assertEq(
            ERC721PermitHash.PERMIT_FOR_ALL_TYPEHASH,
            keccak256("PermitForAll(address operator,bool approved,uint256 nonce,uint256 deadline)")
        );
    }

    function test_fuzz_permitForAllHash(address operator, bool approved, uint256 nonce, uint256 deadline) public pure {
        bytes32 expectedHash =
            keccak256(abi.encode(ERC721PermitHash.PERMIT_FOR_ALL_TYPEHASH, operator, approved, nonce, deadline));
        assertEq(expectedHash, ERC721PermitHash.hashPermitForAll(operator, approved, nonce, deadline));
    }

    /// @dev operator uses alice's signature to approve itself
    function test_fuzz_erc721permitForAll_operator(address operator) public {
        vm.assume(operator != alice);
        vm.prank(alice);
        uint256 tokenId = erc721Permit.mint();

        uint256 nonce = 1;
        bytes32 digest = _getPermitForAllDigest(operator, true, nonce, block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // no approvals existed
        assertEq(erc721Permit.getApproved(tokenId), address(0));
        assertEq(erc721Permit.isApprovedForAll(alice, operator), false);

        // nonce was unspent
        (uint256 wordPos, uint256 bitPos) = _getBitmapFromNonce(nonce);
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);

        // -- PermitForAll -- //
        vm.startPrank(operator);
        vm.expectEmit(true, true, true, true, address(erc721Permit));
        emit IERC721.ApprovalForAll(alice, operator, true);
        erc721Permit.permitForAll(alice, operator, true, block.timestamp, nonce, signature);
        vm.stopPrank();

        // approvals set
        assertEq(erc721Permit.getApproved(tokenId), address(0));
        assertEq(erc721Permit.isApprovedForAll(alice, operator), true);

        // nonce was spent
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 2); // 2 = 0010
    }

    /// @dev a third party caller uses alice's signature to give `operator` the approval
    function test_fuzz_erc721permitForAll_caller(address caller, address operator) public {
        vm.assume(operator != alice);
        vm.prank(alice);
        uint256 tokenId = erc721Permit.mint();

        uint256 nonce = 1;
        bytes32 digest = _getPermitForAllDigest(operator, true, nonce, block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // no approvals existed
        assertEq(erc721Permit.getApproved(tokenId), address(0));
        assertEq(erc721Permit.isApprovedForAll(alice, operator), false);

        // nonce was unspent
        (uint256 wordPos, uint256 bitPos) = _getBitmapFromNonce(nonce);
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);

        // -- PermitForAll -- //
        vm.startPrank(caller);
        vm.expectEmit(true, true, true, true, address(erc721Permit));
        emit IERC721.ApprovalForAll(alice, operator, true);
        erc721Permit.permitForAll(alice, operator, true, block.timestamp, nonce, signature);
        vm.stopPrank();

        // approvals set
        assertEq(erc721Permit.getApproved(tokenId), address(0));
        assertEq(erc721Permit.isApprovedForAll(alice, operator), true);

        // nonce was spent
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 2); // 2 = 0010
    }

    function test_fuzz_erc721permitForAll_nonceAlreadyUsed(uint256 nonce) public {
        // alice gives bob operator permissions
        _permitForAll(alicePK, alice, bob, true, nonce);

        // alice cannot reuse the nonce
        bytes32 digest = _getPermitForAllDigest(bob, true, nonce, block.timestamp);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.startPrank(alice);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        erc721Permit.permitForAll(alice, bob, true, block.timestamp, nonce, signature);
        vm.stopPrank();
    }

    function test_fuzz_erc721permitForAll_invalidSigner(uint256 nonce) public {
        bytes32 digest = _getPermitForAllDigest(bob, true, nonce, block.timestamp);

        // bob attempts signing an approval for himself
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // approvals unset
        assertEq(erc721Permit.isApprovedForAll(alice, bob), false);

        // nonce was unspent
        (uint256 wordPos, uint256 bitPos) = _getBitmapFromNonce(nonce);
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);

        vm.startPrank(bob);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        erc721Permit.permitForAll(alice, bob, true, block.timestamp, nonce, signature);
        vm.stopPrank();

        // approvals unset
        assertEq(erc721Permit.isApprovedForAll(alice, bob), false);

        // nonce was unspent
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);
    }

    function test_fuzz_erc721permitForAll_SignatureDeadlineExpired(address operator) public {
        uint256 nonce = 1;
        uint256 deadline = vm.getBlockTimestamp();
        bytes32 digest = _getPermitForAllDigest(operator, true, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // no approvals existed
        assertEq(erc721Permit.isApprovedForAll(alice, operator), false);

        // nonce was unspent
        (uint256 wordPos, uint256 bitPos) = _getBitmapFromNonce(nonce);
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);

        // fast forward to exceed deadline
        skip(1);

        // -- PermitForAll but deadline expired -- //
        vm.startPrank(operator);
        vm.expectRevert(IERC721Permit_v4.SignatureDeadlineExpired.selector);
        erc721Permit.permitForAll(alice, operator, true, deadline, nonce, signature);
        vm.stopPrank();

        // approvals unset
        assertEq(erc721Permit.isApprovedForAll(alice, operator), false);

        // nonce was unspent
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);
    }

    /// @dev a signature for permit() cannot be used for permitForAll()
    function test_fuzz_erc721Permit_invalidSignatureForAll(address operator) public {
        vm.prank(alice);
        uint256 tokenId = erc721Permit.mint();

        uint256 nonce = 1;
        uint256 deadline = block.timestamp;
        bytes32 digest = _getPermitDigest(operator, tokenId, nonce, deadline);

        // alice signs a permit for operator
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // approvals unset
        assertEq(erc721Permit.isApprovedForAll(alice, bob), false);

        // nonce was unspent
        (uint256 wordPos, uint256 bitPos) = _getBitmapFromNonce(nonce);
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);

        // signature does not work with permitForAll
        vm.startPrank(bob);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        erc721Permit.permitForAll(alice, bob, true, deadline, nonce, signature);
        vm.stopPrank();

        // approvals unset
        assertEq(erc721Permit.isApprovedForAll(alice, bob), false);

        // nonce was unspent
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);
    }

    /// @dev a signature for permitForAll() cannot be used for permit()
    function test_fuzz_erc721PermitForAll_invalidSignatureForPermit(address operator) public {
        vm.prank(alice);
        uint256 tokenId = erc721Permit.mint();

        uint256 nonce = 1;
        uint256 deadline = block.timestamp;
        bytes32 digest = _getPermitForAllDigest(operator, true, nonce, deadline);

        // alice signs a permit for operator
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // approvals unset
        assertEq(erc721Permit.getApproved(tokenId), address(0));

        // nonce was unspent
        (uint256 wordPos, uint256 bitPos) = _getBitmapFromNonce(nonce);
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);

        // signature does not work with permit
        vm.startPrank(bob);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        erc721Permit.permit(bob, tokenId, deadline, nonce, signature);
        vm.stopPrank();

        // approvals unset
        assertEq(erc721Permit.getApproved(tokenId), address(0));

        // nonce was unspent
        assertEq(erc721Permit.nonces(alice, wordPos) & (1 << bitPos), 0);
    }

    /// @dev a nonce used in permit is unusable for permitForAll
    function test_fuzz_erc721PermitForAll_permitNonceUsed(uint256 nonce) public {
        vm.prank(alice);
        uint256 tokenId = erc721Permit.mint();

        uint256 deadline = block.timestamp;
        bytes32 digest = _getPermitDigest(bob, tokenId, nonce, deadline);
        // alice signs a permit for bob
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // bob gives himself approval
        vm.prank(bob);
        erc721Permit.permit(bob, tokenId, deadline, nonce, signature);
        assertEq(erc721Permit.getApproved(tokenId), bob);
        assertEq(erc721Permit.isApprovedForAll(alice, bob), false);

        // alice tries re-using the nonce for permitForAll
        digest = _getPermitForAllDigest(bob, true, nonce, deadline);
        (v, r, s) = vm.sign(alicePK, digest);
        signature = abi.encodePacked(r, s, v);

        // Nonce does not work with permitForAll
        vm.startPrank(bob);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        erc721Permit.permitForAll(alice, bob, true, deadline, nonce, signature);
        vm.stopPrank();
    }

    /// @notice revoking a nonce prevents it from being used in permitForAll()
    function test_fuzz_erc721PermitForAll_revokedNonceUsed(uint256 nonce) public {
        // alice revokes the nonce
        vm.prank(alice);
        erc721Permit.revokeNonce(nonce);

        uint256 deadline = block.timestamp;
        bytes32 digest = _getPermitForAllDigest(bob, true, nonce, deadline);
        // alice signs a permit for bob
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Nonce does not work with permitForAll
        vm.startPrank(bob);
        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        erc721Permit.permitForAll(alice, bob, true, deadline, nonce, signature);
        vm.stopPrank();
    }

    // Helpers related to permitForAll
    function _permitForAll(uint256 privateKey, address owner, address operator, bool approved, uint256 nonce)
        internal
    {
        bytes32 digest = _getPermitForAllDigest(operator, approved, nonce, block.timestamp);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(operator);
        erc721Permit.permitForAll(owner, operator, approved, block.timestamp, nonce, signature);
    }

    function _getPermitForAllDigest(address operator, bool approved, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32 digest)
    {
        digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                erc721Permit.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(ERC721PermitHash.PERMIT_FOR_ALL_TYPEHASH, operator, approved, nonce, deadline))
            )
        );
    }

    function _getPermitDigest(address spender, uint256 tokenId, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32 digest)
    {
        digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                erc721Permit.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(ERC721PermitHash.PERMIT_TYPEHASH, spender, tokenId, nonce, deadline))
            )
        );
    }

    // copied the private function from UnorderedNonce.sol
    function _getBitmapFromNonce(uint256 nonce) private pure returns (uint256 wordPos, uint256 bitPos) {
        wordPos = uint248(nonce >> 8);
        bitPos = uint8(nonce);
    }
}
