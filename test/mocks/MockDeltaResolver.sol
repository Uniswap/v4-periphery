// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {DeltaResolver} from "../../src/base/DeltaResolver.sol";
import {ImmutableState} from "../../src/base/ImmutableState.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockDeltaResolver is Test, DeltaResolver, IUnlockCallback {
    // `exttload` is overloaded in some v4-core versions, so we select the bytes32 variant explicitly.
    bytes4 private constant EXTTLOAD_BYTES32_SELECTOR = bytes4(keccak256("exttload(bytes32)"));

    // Modes executed inside `unlockCallback` where transient deltas are visible.
    uint8 internal constant MODE_ORIGINAL = 0;
    uint8 internal constant MODE_DEBT_AFTER_TAKE = 1;
    uint8 internal constant MODE_FORCE_CREDIT = 2;
    uint8 internal constant MODE_DEBT_REVERT_ON_CREDIT = 3;
    uint8 internal constant MODE_CREDIT_REVERT_ON_DEBT = 4;
    uint8 internal constant MODE_MAP_SETTLE_OPEN_DELTA = 5;
    uint8 internal constant MODE_MAP_TAKE_OPEN_DELTA = 6;
    uint8 internal constant MODE_MAP_WRAP_UNWRAP_OPEN_DELTA = 7;

    uint256 public payCallCount;

    constructor(IPoolManager _poolManager) ImmutableState(_poolManager) {}

    function executeTest(Currency _currency, uint256 _amount) external returns (bytes memory) {
        return poolManager.unlock(
            abi.encode(
                MODE_ORIGINAL, _currency, msg.sender, _amount, Currency.wrap(address(0)), Currency.wrap(address(0))
            )
        );
    }

    function executeMode(
        uint8 _mode,
        Currency _currency,
        uint256 _amount,
        Currency _inputCurrency,
        Currency _outputCurrency
    ) external returns (bytes memory) {
        // `unlock` provides the transient accounting context that `currencyDelta` reads from.
        return poolManager.unlock(abi.encode(_mode, _currency, msg.sender, _amount, _inputCurrency, _outputCurrency));
    }

    function unlockCallback(bytes calldata _data) external returns (bytes memory) {
        (
            uint8 mode,
            Currency currency,
            address caller,
            uint256 amount,
            Currency inputCurrency,
            Currency outputCurrency
        ) = abi.decode(_data, (uint8, Currency, address, uint256, Currency, Currency));

        if (mode == MODE_ORIGINAL) {
            // Matches the original test flow, take then settle the same amount.
            address recipient = currency.isAddressZero() ? address(this) : caller;

            uint256 balanceBefore = currency.balanceOf(recipient);
            _take(currency, recipient, amount);
            uint256 balanceAfter = currency.balanceOf(recipient);
            assertEq(balanceAfter, balanceBefore + amount);

            balanceBefore = balanceAfter;
            _settle(currency, recipient, amount);
            balanceAfter = currency.balanceOf(recipient);
            assertEq(balanceAfter, balanceBefore - amount);

            return "";
        }

        if (mode == MODE_DEBT_AFTER_TAKE) {
            // Create a negative delta via take, then query it.
            _take(currency, address(this), amount);
            uint256 debt = _getFullDebt(currency);

            // PoolManager requires all deltas to be cleared by the end of `unlockCallback`.
            _settle(currency, address(this), amount);

            return abi.encode(debt);
        }

        if (mode == MODE_FORCE_CREDIT) {
            // Simulate a positive delta without violating v4 settle invariants.
            _mockDelta(address(this), currency, int256(amount));
            return abi.encode(_getFullCredit(currency));
        }

        if (mode == MODE_DEBT_REVERT_ON_CREDIT) {
            // Debt query on a positive delta should revert.
            _mockDelta(address(this), currency, int256(amount));
            _getFullDebt(currency);
            return "";
        }

        if (mode == MODE_CREDIT_REVERT_ON_DEBT) {
            // Credit query on a negative delta should revert (this path is expected to revert).
            _take(currency, address(this), amount);
            _getFullCredit(currency);
            return "";
        }

        if (mode == MODE_MAP_SETTLE_OPEN_DELTA) {
            // OPEN_DELTA maps to full debt for settle.
            _take(currency, address(this), amount);

            uint256 mapped = _mapSettleAmount(ActionConstants.OPEN_DELTA, currency);

            // Clear the delta before returning.
            _settle(currency, address(this), amount);

            return abi.encode(mapped);
        }

        if (mode == MODE_MAP_TAKE_OPEN_DELTA) {
            // OPEN_DELTA maps to full credit for take.
            _mockDelta(address(this), currency, int256(amount));
            return abi.encode(_mapTakeAmount(ActionConstants.OPEN_DELTA, currency));
        }

        if (mode == MODE_MAP_WRAP_UNWRAP_OPEN_DELTA) {
            // OPEN_DELTA for wrap/unwrap resolves debt in output currency and checks balance in input currency.
            _take(outputCurrency, address(this), amount);

            uint256 mapped = _mapWrapUnwrapAmount(inputCurrency, ActionConstants.OPEN_DELTA, outputCurrency);

            _settle(outputCurrency, address(this), amount);

            return abi.encode(mapped);
        }

        revert("Unknown mode");
    }

    function _mockDelta(address _target, Currency _currency, int256 _delta) internal {
        // TransientStateLibrary uses `keccak256(abi.encode(target, currency))` as the key for currency deltas.
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, and(_target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(32, and(_currency, 0xffffffffffffffffffffffffffffffffffffffff))
            key := keccak256(0, 64)
        }

        // currencyDelta reads: int256(uint256(poolManager.exttload(key)))
        vm.mockCall(
            address(poolManager),
            abi.encodeWithSelector(EXTTLOAD_BYTES32_SELECTOR, key),
            abi.encode(bytes32(uint256(int256(_delta))))
        );
    }

    function _pay(Currency _token, address _payer, uint256 _amount) internal override {
        ERC20 token = ERC20(Currency.unwrap(_token));

        if (_payer == address(this)) {
            // Solmate `transferFrom` would underflow on allowance[this][this].
            token.transfer(address(poolManager), _amount);
        } else {
            token.transferFrom(_payer, address(poolManager), _amount);
        }

        payCallCount++;
    }

    function exposed_take(Currency _currency, address _to, uint256 _amount) external {
        _take(_currency, _to, _amount);
    }

    function exposed_settle(Currency _currency, address _payer, uint256 _amount) external payable {
        _settle(_currency, _payer, _amount);
    }

    function exposed_mapSettleAmount(uint256 _amount, Currency _currency) external view returns (uint256) {
        return _mapSettleAmount(_amount, _currency);
    }

    function exposed_mapTakeAmount(uint256 _amount, Currency _currency) external view returns (uint256) {
        return _mapTakeAmount(_amount, _currency);
    }

    function exposed_mapWrapUnwrapAmount(Currency _inputCurrency, uint256 _amount, Currency _outputCurrency)
        external
        view
        returns (uint256)
    {
        return _mapWrapUnwrapAmount(_inputCurrency, _amount, _outputCurrency);
    }

    receive() external payable {}
}
