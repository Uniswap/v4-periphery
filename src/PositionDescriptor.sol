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
import {CurrencyRatioSortOrder} from "./libraries/CurrencyRatioSortOrder.sol";
import {SafeCurrencyMetadata} from "./libraries/SafeCurrencyMetadata.sol";

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
    string public nativeCurrencyLabel;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager, address _wrappedNative, string memory _nativeCurrencyLabel) {
        poolManager = _poolManager;
        wrappedNative = _wrappedNative;
        nativeCurrencyLabel = _nativeCurrencyLabel;
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

        // If possible, flip currencies to get the larger currency as the base currency, so that the price (quote/base) is more readable
        // flip if currency0 priority is greater than currency1 priority
        bool _flipRatio = flipRatio(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));

        // If not flipped, quote currency is currency1, base currency is currency0
        // If flipped, quote currency is currency0, base currency is currency1
        Currency quoteCurrency = !_flipRatio ? poolKey.currency1 : poolKey.currency0;
        Currency baseCurrency = !_flipRatio ? poolKey.currency0 : poolKey.currency1;

        return Descriptor.constructTokenURI(
            Descriptor.ConstructTokenURIParams({
                tokenId: tokenId,
                quoteCurrency: quoteCurrency,
                baseCurrency: baseCurrency,
                quoteCurrencySymbol: SafeCurrencyMetadata.currencySymbol(quoteCurrency, nativeCurrencyLabel),
                baseCurrencySymbol: SafeCurrencyMetadata.currencySymbol(baseCurrency, nativeCurrencyLabel),
                quoteCurrencyDecimals: SafeCurrencyMetadata.currencyDecimals(quoteCurrency),
                baseCurrencyDecimals: SafeCurrencyMetadata.currencyDecimals(baseCurrency),
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

    /// @notice Returns true if currency0 has higher priority than currency1
    /// @param currency0 The first currency address
    /// @param currency1 The second currency address
    /// @return flipRatio True if currency0 has higher priority than currency1
    function flipRatio(address currency0, address currency1) public view returns (bool) {
        return currencyRatioPriority(currency0) > currencyRatioPriority(currency1);
    }

    /// @notice Returns the priority of a currency.
    /// For certain currencies on mainnet, the smaller the currency, the higher the priority
    /// @param currency The currency address
    /// @return priority The priority of the currency
    function currencyRatioPriority(address currency) public view returns (int256) {
        // Currencies in order of priority on mainnet: USDC, USDT, DAI, (ETH, WETH), TBTC, WBTC
        // wrapped native is different address on different chains. passed in constructor

        // native currency
        if (currency == address(0) || currency == wrappedNative) {
            return CurrencyRatioSortOrder.DENOMINATOR;
        }
        if (block.chainid == 1) {
            if (currency == USDC) {
                return CurrencyRatioSortOrder.NUMERATOR_MOST;
            } else if (currency == USDT) {
                return CurrencyRatioSortOrder.NUMERATOR_MORE;
            } else if (currency == DAI) {
                return CurrencyRatioSortOrder.NUMERATOR;
            } else if (currency == TBTC) {
                return CurrencyRatioSortOrder.DENOMINATOR_MORE;
            } else if (currency == WBTC) {
                return CurrencyRatioSortOrder.DENOMINATOR_MOST;
            } else {
                return 0;
            }
        }
        return 0;
    }
}
