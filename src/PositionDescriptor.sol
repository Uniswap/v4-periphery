// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "./interfaces/IPositionDescriptor.sol";
import {PositionInfo, PositionInfoLibrary} from "./libraries/PositionInfoLibrary.sol";
import {Descriptor} from "./libraries/Descriptor.sol";
import {AddressRatioSortOrder} from "./libraries/AddressRatioSortOrder.sol";
import {SafeAddressMetadata} from "./libraries/SafeAddressMetadata.sol";

/// @title Describes NFT token positions
/// @notice Produces a string containing the data URI for a JSON metadata string
contract PositionDescriptor is IPositionDescriptor {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using PositionInfoLibrary for PositionInfo;

    error InvalidTokenId(uint256 tokenId);

    // mainnet addresses
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant TBTC = 0x8dAEBADE922dF735c38C80C7eBD708Af50815fAa;
    address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address public immutable wrappedNative;
    string public nativeAddressLabel;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager, address _wrappedNative, string memory _nativeAddressLabel) {
        poolManager = _poolManager;
        wrappedNative = _wrappedNative;
        nativeAddressLabel = _nativeAddressLabel;
    }

    /// @inheritdoc IPositionDescriptor
    function tokenURI(IPositionManager positionManager, uint256 tokenId)
        external
        view
        override
        returns (string memory)
    {
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        if (positionInfo.poolId() == 0) {
            revert InvalidTokenId(tokenId);
        }
        (, int24 tick,,) = poolManager.getSlot0(poolKey.toId());

        address address0 = Currency.unwrap(poolKey.currency0);
        address address1 = Currency.unwrap(poolKey.currency1);

        // If possible, flip addresses to get the larger one as the base, so that the price (quote/base) is more readable
        // flip if address0 priority is greater than address1 priority
        bool _flipRatio = flipRatio(address0, address1);

        // If not flipped, quote address is address1, base address is address0
        // If flipped, quote address is address0, base address is address1
        address quoteAddress = !_flipRatio ? address1 : address0;
        address baseAddress = !_flipRatio ? address0 : address1;

        return Descriptor.constructTokenURI(
            Descriptor.ConstructTokenURIParams({
                tokenId: tokenId,
                quoteAddress: quoteAddress,
                baseAddress: baseAddress,
                quoteAddressSymbol: SafeAddressMetadata.addressSymbol(quoteAddress, nativeAddressLabel),
                baseAddressSymbol: SafeAddressMetadata.addressSymbol(baseAddress, nativeAddressLabel),
                quoteAddressDecimals: SafeAddressMetadata.addressDecimals(quoteAddress),
                baseAddressDecimals: SafeAddressMetadata.addressDecimals(baseAddress),
                flipRatio: _flipRatio,
                tickLower: positionInfo.tickLower(),
                tickUpper: positionInfo.tickUpper(),
                tickCurrent: tick,
                tickSpacing: poolKey.tickSpacing,
                fee: poolKey.fee,
                poolManager: address(poolManager),
                hooks: address(poolKey.hooks)
            })
        );
    }

    /// @notice Returns true if address0 has higher priority than address1
    /// @param address0 The first address
    /// @param address1 The second address
    /// @return flipRatio True if address0 has higher priority than address1
    function flipRatio(address address0, address address1) public view returns (bool) {
        return addressRatioPriority(address0) > addressRatioPriority(address1);
    }

    /// @notice Returns the priority of an address.
    /// For certain addresses on mainnet, the smaller the address, the higher the priority
    /// @param addr The address
    /// @return priority The priority of the address
    function addressRatioPriority(address addr) public view returns (int256) {
        // Addresses in order of priority on mainnet: USDC, USDT, DAI, (ETH, WETH), TBTC, WBTC
        // wrapped native is different address on different chains. passed in constructor

        // native address
        if (addr == address(0) || addr == wrappedNative) {
            return AddressRatioSortOrder.DENOMINATOR;
        }
        if (block.chainid == 1) {
            if (addr == USDC) {
                return AddressRatioSortOrder.NUMERATOR_MOST;
            } else if (addr == USDT) {
                return AddressRatioSortOrder.NUMERATOR_MORE;
            } else if (addr == DAI) {
                return AddressRatioSortOrder.NUMERATOR;
            } else if (addr == TBTC) {
                return AddressRatioSortOrder.DENOMINATOR_MORE;
            } else if (addr == WBTC) {
                return AddressRatioSortOrder.DENOMINATOR_MOST;
            } else {
                return 0;
            }
        }
        return 0;
    }
}
