// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityRange} from "../types/LiquidityRange.sol";

interface INonfungiblePositionManager {
    struct TokenPosition {
        address owner;
        LiquidityRange range;
    }

    // NOTE: more gas efficient as LiquidityAmounts is used offchain
    function mint(
        LiquidityRange calldata position,
        uint256 liquidity,
        uint256 deadline,
        address recipient,
        bytes calldata hookData
    ) external payable returns (BalanceDelta delta);

    // NOTE: more expensive since LiquidityAmounts is used onchain
    // function mint(MintParams calldata params) external payable returns (uint256 tokenId, BalanceDelta delta);

    /// @notice Increase liquidity for an existing position
    /// @param tokenId The ID of the position
    /// @param liquidity The amount of liquidity to add
    /// @param hookData Arbitrary data passed to the hook
    /// @param claims Whether the liquidity increase uses ERC-6909 claim tokens
    /// @return delta Corresponding balance changes as a result of increasing liquidity
    function increaseLiquidity(uint256 tokenId, uint256 liquidity, bytes calldata hookData, bool claims)
        external
        returns (BalanceDelta delta);

    /// @notice Decrease liquidity for an existing position
    /// @param tokenId The ID of the position
    /// @param liquidity The amount of liquidity to remove
    /// @param hookData Arbitrary data passed to the hook
    /// @param claims Whether the removed liquidity is sent as ERC-6909 claim tokens
    /// @return delta Corresponding balance changes as a result of decreasing liquidity applied to user (number of tokens credited to tokensOwed)
    function decreaseLiquidity(uint256 tokenId, uint256 liquidity, bytes calldata hookData, bool claims)
        external
        returns (BalanceDelta delta);

    // TODO Can decide if we want burn to auto encode a decrease/collect.
    /// @notice Burn a position and delete the tokenId
    /// @dev It enforces that there is no open liquidity or tokens to be collected
    /// @param tokenId The ID of the position
    /// @return delta Corresponding balance changes as a result of burning the position
    function burn(uint256 tokenId) external returns (BalanceDelta delta);

    // TODO: in v3, we can partially collect fees, but what was the usecase here?
    /// @notice Collect fees for a position
    /// @param tokenId The ID of the position
    /// @param recipient The address to send the collected tokens to
    /// @param hookData Arbitrary data passed to the hook
    /// @param claims Whether the collected fees are sent as ERC-6909 claim tokens
    /// @return delta Corresponding balance changes as a result of collecting fees
    function collect(uint256 tokenId, address recipient, bytes calldata hookData, bool claims)
        external
        returns (BalanceDelta delta);

    /// @notice Execute a batch of external calls by unlocking the PoolManager
    /// @param data an array of abi.encodeWithSelector(<selector>, <args>) for each call
    /// @return delta The final delta changes of the caller
    function unlockAndExecute(bytes[] memory data, Currency[] memory currencies) external returns (bytes memory);

    /// @notice Returns the fees owed for a position. Includes unclaimed fees + custodied fees + claimable fees
    /// @param tokenId The ID of the position
    /// @return token0Owed The amount of token0 owed
    /// @return token1Owed The amount of token1 owed
    function feesOwed(uint256 tokenId) external view returns (uint256 token0Owed, uint256 token1Owed);

    function nextTokenId() external view returns (uint256);
}
