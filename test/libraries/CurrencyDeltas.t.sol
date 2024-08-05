// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {MockCurrencyDeltaReader} from "../mocks/MockCurrencyDeltaReader.sol";

contract CurrencyDeltasTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    MockCurrencyDeltaReader reader;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        reader = new MockCurrencyDeltaReader(manager);

        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        IERC20 token1 = IERC20(Currency.unwrap(currency1));

        token0.approve(address(reader), type(uint256).max);
        token1.approve(address(reader), type(uint256).max);

        // send tokens to PoolManager so tests can .take()
        token0.transfer(address(manager), 1_000_000e18);
        token1.transfer(address(manager), 1_000_000e18);

        // convert some ERC20s into ERC6909
        claimsRouter.deposit(currency0, address(this), 1_000_000e18);
        claimsRouter.deposit(currency1, address(this), 1_000_000e18);
        manager.approve(address(reader), currency0.toId(), type(uint256).max);
        manager.approve(address(reader), currency1.toId(), type(uint256).max);
    }

    function test_fuzz_currencyDeltas(uint8 depth, uint256 seed, uint128 amount0, uint128 amount1) public {
        int128 delta0Expected = 0;
        int128 delta1Expected = 0;

        bytes[] memory calls = new bytes[](depth);
        for (uint256 i = 0; i < depth; i++) {
            amount0 = uint128(bound(amount0, 1, 100e18));
            amount1 = uint128(bound(amount1, 1, 100e18));
            uint256 _seed = seed % (i + 1);
            if (_seed % 8 == 0) {
                calls[i] = abi.encodeWithSelector(MockCurrencyDeltaReader.settle.selector, currency0, amount0);
                delta0Expected += int128(amount0);
            } else if (_seed % 8 == 1) {
                calls[i] = abi.encodeWithSelector(MockCurrencyDeltaReader.settle.selector, currency1, amount1);
                delta1Expected += int128(amount1);
            } else if (_seed % 8 == 2) {
                calls[i] = abi.encodeWithSelector(MockCurrencyDeltaReader.burn.selector, currency0, amount0);
                delta0Expected += int128(amount0);
            } else if (_seed % 8 == 3) {
                calls[i] = abi.encodeWithSelector(MockCurrencyDeltaReader.burn.selector, currency1, amount1);
                delta1Expected += int128(amount1);
            } else if (_seed % 8 == 4) {
                calls[i] = abi.encodeWithSelector(MockCurrencyDeltaReader.take.selector, currency0, amount0);
                delta0Expected -= int128(amount0);
            } else if (_seed % 8 == 5) {
                calls[i] = abi.encodeWithSelector(MockCurrencyDeltaReader.take.selector, currency1, amount1);
                delta1Expected -= int128(amount1);
            } else if (_seed % 8 == 6) {
                calls[i] = abi.encodeWithSelector(MockCurrencyDeltaReader.mint.selector, currency0, amount0);
                delta0Expected -= int128(amount0);
            } else if (_seed % 8 == 7) {
                calls[i] = abi.encodeWithSelector(MockCurrencyDeltaReader.mint.selector, currency1, amount1);
                delta1Expected -= int128(amount1);
            }
        }

        BalanceDelta delta = reader.execute(calls, currency0, currency1);
        assertEq(delta.amount0(), delta0Expected);
        assertEq(delta.amount1(), delta1Expected);
    }
}
