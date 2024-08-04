// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.5;

/// @title ERC721 with permit
/// @notice Extension to ERC721 that includes a permit function for signature based approvals
interface IERC721Permit {
    error DeadlineExpired();
    error NoSelfPermit();
    error Unauthorized();

    /// @notice Approve of a specific token ID for spending by spender via signature
    /// @param spender The account that is being approved
    /// @param tokenId The ID of the token that is being approved for spending
    /// @param deadline The deadline timestamp by which the call must be mined for the approve to work
    /// @param signature Concatenated data from a valid secp256k1 signature from the holder, i.e. abi.encodePacked(r, s, v)
    /// @dev payable so it can be multicalled with NATIVE related actions
    function permit(address spender, uint256 tokenId, uint256 deadline, uint256 nonce, bytes calldata signature)
        external
        payable;
}
