// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {FeeTaker} from "./FeeTaker.sol";

contract FeeTaking is FeeTaker, Owned {
    using SafeCast for uint256;

    uint128 private constant TOTAL_BIPS = 10000;
    uint128 public immutable swapFeeBips;
    address public treasury;

    constructor(IPoolManager _poolManager, uint128 _swapFeeBips, address _owner, address _treasury)
        FeeTaker(_poolManager)
        Owned(_owner)
    {
        swapFeeBips = _swapFeeBips;
        treasury = _treasury;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function _feeAmount(int128 amountUnspecified) internal view override returns (uint256) {
        return uint128(amountUnspecified) * swapFeeBips / TOTAL_BIPS;
    }

    function _recipient() internal view override returns (address) {
        return treasury;
    }
}
