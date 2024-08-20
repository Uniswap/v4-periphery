// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionConfig} from "../src/libraries/PositionConfig.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./interfaces/IPositionDescriptor.sol";
import "./libraries/Descriptor.sol";
import "./interfaces/IPositionManager.sol";
import "./libraries/CurrencyRatioSortOrder.sol";
import "./libraries/SafeERC20Namer.sol";

import "forge-std/console2.sol";

/// @title Describes NFT token positions
/// @notice Produces a string containing the data URI for a JSON metadata string
contract PositionDescriptor is IPositionDescriptor {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant TBTC = 0x8dAEBADE922dF735c38C80C7eBD708Af50815fAa;
    address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address public immutable WETH9;
    /// @dev A null-terminated string
    bytes32 public immutable nativeCurrencyLabelBytes;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager, address _WETH9, bytes32 _nativeCurrencyLabel) {
        poolManager = _poolManager;
        WETH9 = _WETH9;
        nativeCurrencyLabelBytes = _nativeCurrencyLabel;
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
    function tokenURI(uint256 tokenId, PositionConfig calldata config) external view override returns (string memory) {
        // no way of getting the config from just the tokenId.
        // could get configId from tokenId, but no way to get config from configId because it is a hash

        (, int24 tick,,) = poolManager.getSlot0(config.poolKey.toId());

        PoolKey memory poolKey = config.poolKey;
        int24 tickLower = config.tickLower;
        int24 tickUpper = config.tickUpper;
        Currency currency0 = Currency(config.poolKey.currency0);
        Currency currency1 = Currency(config.poolKey.currency1);

        bool _flipRatio = flipRatio(Currency.unwrap(currency0), Currency.unwrap(currency1));
        Currency quoteCurrency = !_flipRatio ? currency1 : currency0;
        Currency baseCurrency = !_flipRatio ? currency0 : currency1;

        return Descriptor.constructTokenURI(
            Descriptor.ConstructTokenURIParams({
                tokenId: tokenId,
                quoteCurrency: quoteCurrency,
                baseCurrency: baseCurrency,
                quoteCurrencySymbol: Currency.unwrap(quoteCurrency) == WETH9 || quoteCurrency.isNative()
                    ? nativeCurrencyLabel()
                    : SafeERC20Namer.tokenSymbol(Currency.unwrap(quoteCurrency)),
                baseCurrencySymbol: Currency.unwrap(baseCurrency) == WETH9 || baseCurrency.isNative()
                    ? nativeCurrencyLabel()
                    : SafeERC20Namer.tokenSymbol(Currency.unwrap(baseCurrency)),
                quoteCurrencyDecimals: quoteCurrency.isNative()
                    ? 18
                    : IERC20Metadata(Currency.unwrap(quoteCurrency)).decimals(),
                baseCurrencyDecimals: baseCurrency.isNative()
                    ? 18
                    : IERC20Metadata(Currency.unwrap(baseCurrency)).decimals(),
                flipRatio: _flipRatio,
                tickLower: tickLower,
                tickUpper: tickUpper,
                tickCurrent: tick,
                tickSpacing: poolKey.tickSpacing,
                fee: poolKey.fee,
                poolManager: address(poolManager),
                hooks: address(poolKey.hooks)
            })
        );
    }

    function flipRatio(address currency0, address currency1) public view returns (bool) {
        return currencyRatioPriority(currency0) > currencyRatioPriority(currency1);
    }

    function currencyRatioPriority(address currency) public view returns (int256) {
        if (currency == WETH9) {
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
