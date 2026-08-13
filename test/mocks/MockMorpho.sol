// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketParams, Id, Position, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoStorageLib} from "morpho-blue/libraries/periphery/MorphoStorageLib.sol";

/// @notice Minimal Morpho Blue stand-in exposing the reads MorphoLendingAdapter needs:
///         idToMarketParams (setMarket validation), position (shares-based full repay), and enough of
///         market()/extSloads for MorphoBalancesLib.expectedBorrowAssets to resolve the reported debt
///         the repay clamp compares against. Interest accrual is skipped when a market's `lastUpdate`
///         equals the current block timestamp (elapsed == 0), so no IRM is called; set it that way in
///         tests that seed a borrow. Live accrual is still covered by the fork tests.
contract MockMorpho {
    using MarketParamsLib for MarketParams;

    mapping(Id id => MarketParams params) internal _idToMarketParams;
    mapping(Id id => mapping(address user => Position position)) internal _position;
    mapping(Id id => Market market) internal _market;
    // extSloads-visible storage: MorphoLib reads packed borrow shares through this slot, so mirror the
    // seeded position into it (keyed by the same slot MorphoStorageLib computes).
    mapping(bytes32 slot => bytes32 value) internal _slots;

    function setMarketParams(MarketParams memory marketParams) external {
        _idToMarketParams[marketParams.id()] = marketParams;
    }

    function setPosition(Id id, address user, Position memory p) external {
        _position[id][user] = p;
        // Mirror borrow shares (low 128 bits) and collateral (high 128 bits) into the packed slot that
        // MorphoLib.borrowShares reads via extSloads, so expectedBorrowAssets sees the same balance.
        _slots[MorphoStorageLib.positionBorrowSharesAndCollateralSlot(id, user)] =
            bytes32((uint256(p.collateral) << 128) | uint256(p.borrowShares));
    }

    /// @notice Sets the market totals expectedBorrowAssets converts shares against. Set `lastUpdate` to
    ///         the current block timestamp to skip interest accrual and avoid an IRM call.
    function setMarketState(Id id, Market memory m) external {
        _market[id] = m;
    }

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        return _idToMarketParams[id];
    }

    function position(Id id, address user) external view returns (Position memory) {
        return _position[id][user];
    }

    function market(Id id) external view returns (Market memory) {
        return _market[id];
    }

    function extSloads(bytes32[] memory slots) external view returns (bytes32[] memory res) {
        res = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            res[i] = _slots[slots[i]];
        }
    }
}
