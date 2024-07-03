// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {FeeTaker} from "./../../../contracts/hooks/examples/FeeTaker.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "./../../../contracts/BaseHook.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

contract FeeTakingExtension is FeeTaker, Owned {
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;

    uint128 private constant TOTAL_BIPS = 10000;
    uint128 public immutable swapFeeBips;
    address public treasury;

    uint256 public afterSwapCounter;
    int128 public DONATION_AMOUNT = 1 gwei;

    constructor(IPoolManager _poolManager, uint128 _swapFeeBips, address _owner, address _treasury)
        FeeTaker(_poolManager)
        Owned(_owner)
    {
        swapFeeBips = _swapFeeBips;
        treasury = _treasury;
    }

    function _afterSwap(
        address,
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        afterSwapCounter++;
        bool currency0Specified = (params.amountSpecified < 0 == params.zeroForOne);
        Currency currencyUnspecified = currency0Specified ? key.currency1 : key.currency0;
        currencyUnspecified.transfer(address(manager), uint256(int256(DONATION_AMOUNT)));
        manager.settle(currencyUnspecified);
        return (BaseHook.afterSwap.selector, -DONATION_AMOUNT);
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

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}
