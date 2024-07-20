// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {ERC721} from "solmate/tokens/ERC721.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {IERC721Permit} from "../interfaces/IERC721Permit.sol";
import {UnorderedNonce} from "./UnorderedNonce.sol";

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";

/// @title ERC721 with permit
/// @notice Nonfungible tokens that support an approve via signature, i.e. permit
abstract contract ERC721Permit is ERC721, IERC721Permit, EIP712, UnorderedNonce {
    /// @inheritdoc IERC721Permit
    /// @dev Value is equal to keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
    bytes32 public constant override PERMIT_TYPEHASH =
        0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;

    /// @notice Computes the nameHash and versionHash
    constructor(string memory name_, string memory symbol_, string memory version_)
        ERC721(name_, symbol_)
        EIP712(name_, version_)
    {}

    // TODO: implement here, or in posm
    function tokenURI(uint256) public pure override returns (string memory) {
        return "https://example.com";
    }

    /// @inheritdoc IERC721Permit
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc IERC721Permit
    function permit(address spender, uint256 tokenId, uint256 deadline, uint256 nonce, uint8 v, bytes32 r, bytes32 s)
        external
        override
    {
        if (block.timestamp > deadline) revert DeadlineExpired();

        address owner = ownerOf(tokenId);
        if (spender == owner) revert NoSelfPermit();

        bytes32 digest = getDigest(spender, tokenId, nonce, deadline);

        if (Address.isContract(owner)) {
            if (
                IERC1271(owner).isValidSignature(digest, abi.encodePacked(r, s, v))
                    != IERC1271.isValidSignature.selector
            ) {
                revert Unauthorized();
            }
        } else {
            address recoveredAddress = ecrecover(digest, v, r, s);
            if (recoveredAddress == address(0)) revert InvalidSignature();
            if (recoveredAddress != owner) revert Unauthorized();
        }

        _useUnorderedNonce(owner, nonce);
        _approve(owner, spender, tokenId);
    }

    function approve(address spender, uint256 id) public override {
        // override Solmate's ERC721 approve so approve() and permit() share the same code paths

        address owner = _ownerOf[id];

        if (msg.sender != owner && !isApprovedForAll[owner][msg.sender]) revert Unauthorized();

        _approve(owner, spender, id);
    }

    function _approve(address owner, address spender, uint256 id) internal {
        getApproved[id] = spender;
        emit Approval(owner, spender, id);
    }

    function getDigest(address spender, uint256 tokenId, uint256 _nonce, uint256 deadline)
        public
        view
        returns (bytes32 digest)
    {
        digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, _nonce, deadline))
            )
        );
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        return spender == ownerOf(tokenId) || getApproved[tokenId] == spender
            || isApprovedForAll[ownerOf(tokenId)][spender];
    }
}
