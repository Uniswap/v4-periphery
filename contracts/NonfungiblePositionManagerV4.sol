// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";

import {INonfungiblePositionManagerV4} from "./interfaces/INonfungiblePositionManagerV4.sol";
import {PeripheryValidation} from "./base/PeripheryValidation.sol";
import {PeripheryPayments} from "./base/PeripheryPayments.sol";
import {SelfPermit} from "./base/SelfPermit.sol";
import {Multicall} from "./base/Multicall.sol";

error InvalidTokenID();
error NotApproved();
error NotCleared();
error NonexistentToken();

contract NonfungiblePositionManagerV4 is
    INonfungiblePositionManagerV4,
    ERC721,
    PeripheryValidation,
    PeripheryPayments,
    SelfPermit,
    Multicall
{
    IPoolManager public immutable poolManager;

    // details about the Uniswap position
    struct Position {
        // the nonce for permits
        uint96 nonce;
        // the address that is approved for spending this token
        address operator;
        // the hashed poolKey of the pool with which this token is connected
        bytes32 poolId;
        // the tick range of the position
        int24 tickLower;
        int24 tickUpper;
        // the liquidity of the position
        uint128 liquidity;
        // the fee growth of the aggregate position as of the last action on the individual position
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // how many uncollected tokens are owed to the position, as of the last computation
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @dev Pool keys by poolIds
    mapping(bytes32 => PoolKey) private _poolIdToPoolKey;

    /// @dev The token ID position data
    mapping(uint256 => Position) private _positions;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint176 private _nextId = 1;

    /// @dev The address of the token descriptor contract, which handles generating token URIs for position tokens
    address private immutable _tokenDescriptor;

    // TODO: does it still need WETH address in the constructor here?
    // TODO: use ERC721Permit2 here
    constructor(IPoolManager _poolManager, address _tokenDescriptor_)
        ERC721("Uniswap V4 Positions NFT-V1", "UNI-V4-POS")
    {
        poolManager = _poolManager;
        _tokenDescriptor = _tokenDescriptor_;
    }

    /// @inheritdoc INonfungiblePositionManagerV4
    function positions(uint256 tokenId)
        external
        view
        override
        returns (
            uint96 nonce,
            address operator,
            Currency currency0,
            Currency currency1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position memory position = _positions[tokenId];
        if (position.poolId == 0) revert InvalidTokenID();
        PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        return (
            position.nonce,
            position.operator,
            poolKey.currency0,
            poolKey.currency1,
            poolKey.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.tokensOwed0,
            position.tokensOwed1
        );
    }

    /// @inheritdoc INonfungiblePositionManagerV4
    function createAndInitializePoolIfNecessary(PoolKey memory poolkey, uint160 sqrtPriceX96, bytes memory initData)
        external
        payable
    {
        // TODO: implement this
    }

    /// @inheritdoc INonfungiblePositionManagerV4
    function mint(MintParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // TODO: implement this
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert NotApproved();
        _;
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, IERC721Metadata) returns (string memory) {
        // TODO: implement this
    }

    /// @inheritdoc INonfungiblePositionManagerV4
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // TODO: implement this
    }

    /// @inheritdoc INonfungiblePositionManagerV4
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        override
        isAuthorizedForToken(params.tokenId)
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        // TODO: implement this
    }

    /// @inheritdoc INonfungiblePositionManagerV4
    function collect(CollectParams calldata params)
        external
        payable
        override
        isAuthorizedForToken(params.tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        // TODO: implement this
    }

    /// @inheritdoc INonfungiblePositionManagerV4
    function burn(uint256 tokenId) external payable override isAuthorizedForToken(tokenId) {
        Position storage position = _positions[tokenId];
        if (position.liquidity != 0 || position.tokensOwed0 != 0 || position.tokensOwed1 != 0) revert NotCleared();
        delete _positions[tokenId];
        _burn(tokenId);
    }

    /// @inheritdoc IERC721
    function getApproved(uint256 tokenId) public view override(ERC721, IERC721) returns (address) {
        if (!_exists(tokenId)) revert NonexistentToken();

        return _positions[tokenId].operator;
    }

    /// @dev Overrides _approve to use the operator in the position, which is packed with the position permit nonce
    function _approve(address to, uint256 tokenId) internal override(ERC721) {
        _positions[tokenId].operator = to;
        emit Approval(ownerOf(tokenId), to, tokenId);
    }

    function tokenByIndex(uint256 index) external view returns (uint256) {
        // TODO: implement this
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        // TODO: implement this
    }

    function totalSupply() external view returns (uint256) {
        // TODO: implement this
    }
}
