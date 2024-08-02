// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {ERC721} from "solmate/src/tokens/ERC721.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ERC721PermitHashLibrary} from "../libraries/ERC721PermitHash.sol";
import {SignatureVerification} from "permit2/src/libraries/SignatureVerification.sol";

import {IERC721Permit} from "../interfaces/IERC721Permit.sol";
import {UnorderedNonce} from "./UnorderedNonce.sol";

/// @title ERC721 with permit
/// @notice Nonfungible tokens that support an approve via signature, i.e. permit
abstract contract ERC721Permit is ERC721, IERC721Permit, EIP712, UnorderedNonce {
    using SignatureVerification for bytes;

    /// @notice Computes the nameHash and versionHash
    constructor(string memory name_, string memory symbol_, string memory version_)
        ERC721(name_, symbol_)
        EIP712(name_, version_)
    {}

    /// @inheritdoc IERC721Permit
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc IERC721Permit
    function permit(address spender, uint256 tokenId, uint256 deadline, uint256 nonce, bytes calldata signature)
        external
        payable
    {
        if (block.timestamp > deadline) revert DeadlineExpired();

        address owner = ownerOf(tokenId);
        if (spender == owner) revert NoSelfPermit();

        bytes32 hash = ERC721PermitHashLibrary.hash(spender, tokenId, nonce, deadline);
        signature.verify(_hashTypedDataV4(hash), owner);

        _useUnorderedNonce(owner, nonce);
        _approve(owner, spender, tokenId);
    }

    /// @notice Change or reaffirm the approved address for an NFT
    /// @dev override Solmate's ERC721 approve so approve() and permit() share the _approve method
    /// The zero address indicates there is no approved address
    /// Throws error unless `msg.sender` is the current NFT owner,
    /// or an authorized operator of the current owner.
    /// @param spender The new approved NFT controller
    /// @param id The tokenId of the NFT to approve
    function approve(address spender, uint256 id) public override {
        address owner = _ownerOf[id];

        if (msg.sender != owner && !isApprovedForAll[owner][msg.sender]) revert Unauthorized();

        _approve(owner, spender, id);
    }

    function _approve(address owner, address spender, uint256 id) internal {
        getApproved[id] = spender;
        emit Approval(owner, spender, id);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        return spender == ownerOf(tokenId) || getApproved[tokenId] == spender
            || isApprovedForAll[ownerOf(tokenId)][spender];
    }
}
