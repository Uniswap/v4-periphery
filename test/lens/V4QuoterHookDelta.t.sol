// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy, IV4Quoter} from "../shared/Deploy.sol";
import {QuoterRevert} from "../../src/libraries/QuoterRevert.sol";
import {MockArbitraryAfterSwapDeltaHook} from "../mocks/MockArbitraryAfterSwapDeltaHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";

contract V4QuoterHookDeltaTest is Test, Deployers {
    IV4Quoter internal quoter;
    PoolModifyLiquidityTest internal positionManager;
    MockArbitraryAfterSwapDeltaHook internal hook;

    Currency internal currency2;
    PoolKey internal hookedKey;
    address internal hookAddr;

    function setUp() public {
        deployFreshManager();
        quoter = Deploy.v4Quoter(address(manager), hex"00");
        positionManager = new PoolModifyLiquidityTest(manager);

        currency0 = _deployCurrency("Token0", "TK0");
        currency1 = _deployCurrency("Token1", "TK1");
        currency2 = _deployCurrency("Token2", "TK2");

        hookAddr = address(uint160(Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        address implementation = address(new MockArbitraryAfterSwapDeltaHook(manager));
        vm.etch(hookAddr, implementation.code);
        hook = MockArbitraryAfterSwapDeltaHook(hookAddr);

        hookedKey = _poolKey(currency0, currency1, hookAddr);
        _setupPool(hookedKey);
        _setupPool(_poolKey(currency1, currency2, address(0)));

        MockERC20(Currency.unwrap(currency0)).mint(hookAddr, 2 ** 120);
        MockERC20(Currency.unwrap(currency1)).mint(hookAddr, 2 ** 120);
    }

    function test_quoteExactInputSingle_hookTakesMoreThanOutput_revertsUnexpectedRevertBytes() public {
        hook.setFixedUnspecifiedDelta(int128(2 ether));

        _expectSafeCastOverflow();
        quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: hookedKey, zeroForOne: true, exactAmount: 1 ether, hookData: bytes("")
            })
        );
    }

    function test_quoteExactInputSingle_oneForZero_hookTakesMoreThanOutput_revertsUnexpectedRevertBytes() public {
        hook.setFixedUnspecifiedDelta(int128(2 ether));

        _expectSafeCastOverflow();
        quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: hookedKey, zeroForOne: false, exactAmount: 1 ether, hookData: bytes("")
            })
        );
    }

    function test_quoteExactInput_hookTakesMoreThanOutput_revertsUnexpectedRevertBytes() public {
        hook.setFixedUnspecifiedDelta(int128(2 ether));

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(currency1, 3000, 60, IHooks(address(0)), bytes(""));
        path[1] = PathKey(currency0, 3000, 60, IHooks(hookAddr), bytes(""));

        _expectSafeCastOverflow();
        quoter.quoteExactInput(IV4Quoter.QuoteExactParams({exactCurrency: currency2, path: path, exactAmount: 1 ether}));
    }

    function test_quoteExactInputSingle_uint128Max_revertsSafeCastOverflow() public {
        _expectSafeCastOverflow();
        quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: hookedKey, zeroForOne: true, exactAmount: type(uint128).max, hookData: bytes("")
            })
        );
    }

    function test_quoteExactOutputSingle_hookOverfundsInput_revertsUnexpectedRevertBytes() public {
        hook.setSubsidizeExactOutput(1);

        _expectSafeCastOverflow();
        quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: hookedKey, zeroForOne: true, exactAmount: 1 ether, hookData: bytes("")
            })
        );
    }

    function test_quoteExactOutputSingle_oneForZero_hookOverfundsInput_revertsUnexpectedRevertBytes() public {
        hook.setSubsidizeExactOutput(1);

        _expectSafeCastOverflow();
        quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: hookedKey, zeroForOne: false, exactAmount: 1 ether, hookData: bytes("")
            })
        );
    }

    function test_quoteExactOutput_hookOverfundsInput_revertsUnexpectedRevertBytes() public {
        hook.setSubsidizeExactOutput(1);

        _expectSafeCastOverflow();
        quoter.quoteExactOutput(_exactOutputPathWithHookProcessedLast(1 ether));
    }

    function test_quoteExactOutputSingle_hookFundsInputExactly_quotesZeroInput() public {
        hook.setSubsidizeExactOutput(0);

        (uint256 amountIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: hookedKey, zeroForOne: true, exactAmount: 1 ether, hookData: bytes("")
            })
        );

        assertEq(amountIn, 0);
    }

    function test_quoteExactOutputSingle_inputDeltaInt128Min_quotesTwoTo127() public {
        hook.setForceInputDeltaToMin();

        (uint256 amountIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: hookedKey, zeroForOne: true, exactAmount: 1 ether, hookData: bytes("")
            })
        );

        assertEq(amountIn, 2 ** 127);
    }

    function test_quoteExactOutput_fullyFundedHop_quotesZeroInput() public {
        hook.setSubsidizeExactOutput(0);

        (uint256 amountIn,) = quoter.quoteExactOutput(_exactOutputPathWithHookProcessedFirst(1 ether));

        assertEq(amountIn, 0);
    }

    function _exactOutputPathWithHookProcessedLast(uint128 amountOut)
        private
        view
        returns (IV4Quoter.QuoteExactParams memory params)
    {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(currency0, 3000, 60, IHooks(hookAddr), bytes(""));
        path[1] = PathKey(currency1, 3000, 60, IHooks(address(0)), bytes(""));
        return IV4Quoter.QuoteExactParams({exactCurrency: currency2, path: path, exactAmount: amountOut});
    }

    function _exactOutputPathWithHookProcessedFirst(uint128 amountOut)
        private
        view
        returns (IV4Quoter.QuoteExactParams memory params)
    {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(currency2, 3000, 60, IHooks(address(0)), bytes(""));
        path[1] = PathKey(currency1, 3000, 60, IHooks(hookAddr), bytes(""));
        return IV4Quoter.QuoteExactParams({exactCurrency: currency0, path: path, exactAmount: amountOut});
    }

    function _expectSafeCastOverflow() private {
        vm.expectRevert(
            abi.encodeWithSelector(
                QuoterRevert.UnexpectedRevertBytes.selector, abi.encodeWithSelector(SafeCast.SafeCastOverflow.selector)
            )
        );
    }

    function _deployCurrency(string memory name, string memory symbol) private returns (Currency currency) {
        MockERC20 token = new MockERC20(name, symbol, 18);
        token.mint(address(this), 2 ** 120);
        return Currency.wrap(address(token));
    }

    function _poolKey(Currency currencyA, Currency currencyB, address hookAddress)
        private
        pure
        returns (PoolKey memory)
    {
        if (Currency.unwrap(currencyA) > Currency.unwrap(currencyB)) {
            (currencyA, currencyB) = (currencyB, currencyA);
        }
        return PoolKey(currencyA, currencyB, 3000, 60, IHooks(hookAddress));
    }

    function _setupPool(PoolKey memory key) private {
        manager.initialize(key, SQRT_PRICE_1_1);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, 200 ether, 0), bytes(""));
    }
}
