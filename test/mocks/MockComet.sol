// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IComet} from "../../src/interfaces/external/compound-v3/IComet.sol";

/// @notice Minimal in-memory Compound v3 (Comet) stand-in for unit-testing the CompoundV3LendingAdapter
///         without a fork. Models the pieces the adapter reads: a single base token, a set of registered
///         collateral assets with configurable factors and price feeds, per-account collateral and base
///         borrow balances, and a USD price per feed. supply/withdraw mutate the account's balances the
///         way the real Comet does (supplying the base repays the borrow first), which is enough for
///         encode round-trips; it does not model interest accrual or health enforcement.
contract MockComet is IComet {
    address internal immutable _baseToken;
    address internal _baseFeed;
    uint256 internal _baseScale;

    mapping(address asset => AssetInfo) internal _assetInfo;
    mapping(address asset => bool) internal _isCollateral;
    mapping(address feed => uint256 price) internal _price;
    mapping(address account => mapping(address asset => uint256)) internal _collateral;
    mapping(address account => uint256) internal _borrow;

    error NotACollateralAsset();

    constructor(address base, address baseFeed, uint256 baseScale_) {
        _baseToken = base;
        _baseFeed = baseFeed;
        _baseScale = baseScale_;
    }

    // ---- configuration helpers (test-only) ----

    function registerCollateral(
        address asset,
        address priceFeed,
        uint64 scale,
        uint64 borrowCollateralFactor,
        uint64 liquidateCollateralFactor
    ) external {
        _assetInfo[asset] = AssetInfo({
            offset: 0,
            asset: asset,
            priceFeed: priceFeed,
            scale: scale,
            borrowCollateralFactor: borrowCollateralFactor,
            liquidateCollateralFactor: liquidateCollateralFactor,
            liquidationFactor: 0,
            supplyCap: type(uint128).max
        });
        _isCollateral[asset] = true;
    }

    function setPrice(address feed, uint256 price) external {
        _price[feed] = price;
    }

    /// @notice Repoint the base-token price feed, mirroring a Comet governance feed migration behind
    ///         the same proxy. Lets tests exercise a superseded-feed scenario.
    function setBaseTokenPriceFeed(address baseFeed) external {
        _baseFeed = baseFeed;
    }

    function setCollateralBalance(address account, address asset, uint256 amount) external {
        _collateral[account][asset] = amount;
    }

    function setBorrowBalance(address account, uint256 amount) external {
        _borrow[account] = amount;
    }

    // ---- IComet ----

    function supply(address asset, uint256 amount) external {
        if (asset == _baseToken) {
            uint256 owed = _borrow[msg.sender];
            _borrow[msg.sender] = amount >= owed ? 0 : owed - amount;
        } else {
            _collateral[msg.sender][asset] += amount;
        }
    }

    function withdraw(address asset, uint256 amount) external {
        if (asset == _baseToken) {
            _borrow[msg.sender] += amount;
        } else {
            _collateral[msg.sender][asset] -= amount;
        }
    }

    function withdrawTo(address, address asset, uint256 amount) external {
        if (asset == _baseToken) {
            _borrow[msg.sender] += amount;
        } else {
            _collateral[msg.sender][asset] -= amount;
        }
    }

    function baseToken() external view returns (address) {
        return _baseToken;
    }

    function baseTokenPriceFeed() external view returns (address) {
        return _baseFeed;
    }

    function baseScale() external view returns (uint256) {
        return _baseScale;
    }

    function getPrice(address priceFeed) external view returns (uint256) {
        return _price[priceFeed];
    }

    function getAssetInfoByAddress(address asset) external view returns (AssetInfo memory) {
        if (!_isCollateral[asset]) revert NotACollateralAsset();
        return _assetInfo[asset];
    }

    function collateralBalanceOf(address account, address asset) external view returns (uint128) {
        return uint128(_collateral[account][asset]);
    }

    function borrowBalanceOf(address account) external view returns (uint256) {
        return _borrow[account];
    }
}
