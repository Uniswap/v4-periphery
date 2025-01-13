// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "./interfaces/IPositionDescriptor.sol";
import {PositionInfo} from "./libraries/PositionInfoLibrary.sol";
import {Descriptor} from "./libraries/Descriptor.sol";
import {CurrencyRatioSortOrder} from "./libraries/CurrencyRatioSortOrder.sol";
import {SafeCurrencyMetadata} from "./libraries/SafeCurrencyMetadata.sol";

/// @title Describes NFT token positions
/// @notice Produces a string containing the data URI for a JSON metadata string
contract PositionDescriptor is IPositionDescriptor {
    using StateLibrary for IPoolManager;

    // mainnet addresses
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant TBTC = 0x8dAEBADE922dF735c38C80C7eBD708Af50815fAa;
    address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address public immutable wrappedNative;
    bytes32 private immutable nativeCurrencyLabelBytes;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager, address _wrappedNative, bytes32 _nativeCurrencyLabelBytes) {
        poolManager = _poolManager;
        wrappedNative = _wrappedNative;
        nativeCurrencyLabelBytes = _nativeCurrencyLabelBytes;
    }

    /// @notice Returns the native currency label as a string
    function nativeCurrencyLabel() public view returns (string memory) {
        uint256 len = 0;
        while (len < 32 && nativeCurrencyLabelBytes[len] != 0) {
            len++;
        }
        bytes memory b = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            b[i] = nativeCurrencyLabelBytes[i];
        }
        return string(b);
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

        address currency0 = Currency.unwrap(poolKey.currency0);
        address currency1 = Currency.unwrap(poolKey.currency1);

        // If possible, flip currencies to get the larger currency as the base currency, so that the price (quote/base) is more readable
        // flip if currency0 priority is greater than currency1 priority
        bool _flipRatio = flipRatio(currency0, currency1);

        // If not flipped, quote currency is currency1, base currency is currency0
        // If flipped, quote currency is currency0, base currency is currency1
        address quoteCurrency = !_flipRatio ? currency1 : currency0;
        address baseCurrency = !_flipRatio ? currency0 : currency1;

        return Descriptor.constructTokenURI(
            Descriptor.ConstructTokenURIParams({
                tokenId: tokenId,
                quoteCurrency: quoteCurrency,
                baseCurrency: baseCurrency,
                quoteCurrencySymbol: SafeCurrencyMetadata.currencySymbol(quoteCurrency, nativeCurrencyLabel()),
                baseCurrencySymbol: SafeCurrencyMetadata.currencySymbol(baseCurrency, nativeCurrencyLabel()),
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

    /// @inheritdoc IPositionDescriptor
    function flipRatio(address currency0, address currency1) public view returns (bool) {
        return currencyRatioPriority(currency0) > currencyRatioPriority(currency1);
    }

    /// @inheritdoc IPositionDescriptor
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
            }
        }
        return 0;
    }
}
