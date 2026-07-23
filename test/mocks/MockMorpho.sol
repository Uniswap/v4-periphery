// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketParams, Id, Position} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";

/// @notice Minimal Morpho Blue stand-in exposing the read functions MorphoLendingAdapter calls in
///         its non-accruing paths: idToMarketParams (setMarket validation) and position (shares
///         based full repay). Accrual-dependent reads (expectedBorrowAssets) read live market state
///         and are covered by fork tests against real Morpho rather than this mock.
contract MockMorpho {
    using MarketParamsLib for MarketParams;

    mapping(Id id => MarketParams params) internal _idToMarketParams;
    mapping(Id id => mapping(address user => Position position)) internal _position;

    function setMarketParams(MarketParams memory marketParams) external {
        _idToMarketParams[marketParams.id()] = marketParams;
    }

    function setPosition(Id id, address user, Position memory p) external {
        _position[id][user] = p;
    }

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        return _idToMarketParams[id];
    }

    function position(Id id, address user) external view returns (Position memory) {
        return _position[id][user];
    }
}
