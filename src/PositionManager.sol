// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {ERC721Permit} from "./base/ERC721Permit.sol";
import {ReentrancyLock} from "./base/ReentrancyLock.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {Multicall} from "./base/Multicall.sol";
import {PoolInitializer} from "./base/PoolInitializer.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {PositionConfig, PositionConfigLibrary} from "./libraries/PositionConfig.sol";
import {BaseActionsRouter} from "./base/BaseActionsRouter.sol";
import {Actions} from "./libraries/Actions.sol";
import {CalldataDecoder} from "./libraries/CalldataDecoder.sol";
import {Permit2Forwarder} from "./base/Permit2Forwarder.sol";
import {SlippageCheckLibrary} from "./libraries/SlippageCheck.sol";

contract PositionManager is
    IPositionManager,
    ERC721Permit,
    PoolInitializer,
    Multicall,
    DeltaResolver,
    ReentrancyLock,
    BaseActionsRouter,
    Permit2Forwarder
{
    using SafeTransferLib for *;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using PositionConfigLibrary for PositionConfig;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using CalldataDecoder for bytes;
    using SlippageCheckLibrary for BalanceDelta;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 public nextTokenId = 1;

    /// @inheritdoc IPositionManager
    mapping(uint256 tokenId => bytes32 configId) public positionConfigs;

    constructor(IPoolManager _poolManager, IAllowanceTransfer _permit2)
        BaseActionsRouter(_poolManager)
        Permit2Forwarder(_permit2)
        ERC721Permit("Uniswap V4 Positions NFT", "UNI-V4-POSM", "1")
    {}

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        _;
    }

    /// @param unlockData is an encoding of actions, params, and currencies
    /// @param deadline is the timestamp at which the unlockData will no longer be valid
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
        external
        payable
        isNotLocked
        checkDeadline(deadline)
    {
        _executeActions(unlockData);
    }

    function _handleAction(uint256 action, bytes calldata params) internal virtual override {
        if (action == Actions.INCREASE_LIQUIDITY) {
            (
                uint256 tokenId,
                PositionConfig calldata config,
                uint256 liquidity,
                uint128 amount0Max,
                uint128 amount1Max,
                bytes calldata hookData
            ) = params.decodeModifyLiquidityParams();
            _increase(tokenId, config, liquidity, amount0Max, amount1Max, hookData);
        } else if (action == Actions.DECREASE_LIQUIDITY) {
            (
                uint256 tokenId,
                PositionConfig calldata config,
                uint256 liquidity,
                uint128 amount0Min,
                uint128 amount1Min,
                bytes calldata hookData
            ) = params.decodeModifyLiquidityParams();
            _decrease(tokenId, config, liquidity, amount0Min, amount1Min, hookData);
        } else if (action == Actions.MINT_POSITION) {
            (
                PositionConfig calldata config,
                uint256 liquidity,
                uint128 amount0Max,
                uint128 amount1Max,
                address owner,
                bytes calldata hookData
            ) = params.decodeMintParams();
            _mint(config, liquidity, amount0Max, amount1Max, _mapRecipient(owner), hookData);
        } else if (action == Actions.CLOSE_CURRENCY) {
            Currency currency = params.decodeCurrency();
            _close(currency);
        } else if (action == Actions.CLEAR) {
            (Currency currency, uint256 amountMax) = params.decodeCurrencyAndUint256();
            _clear(currency, amountMax);
        } else if (action == Actions.BURN_POSITION) {
            // Will automatically decrease liquidity to 0 if the position is not already empty.
            (
                uint256 tokenId,
                PositionConfig calldata config,
                uint128 amount0Min,
                uint128 amount1Min,
                bytes calldata hookData
            ) = params.decodeBurnParams();
            _burn(tokenId, config, amount0Min, amount1Min, hookData);
        } else if (action == Actions.SETTLE) {
            (Currency currency, uint256 amount, bool payerIsUser) = params.decodeCurrencyUint256AndBool();
            _settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
        } else if (action == Actions.SETTLE_PAIR) {
            (Currency currency0, Currency currency1) = params.decodeCurrencyPair();
            _settlePair(currency0, currency1);
        } else if (action == Actions.TAKE_PAIR) {
            (Currency currency0, Currency currency1) = params.decodeCurrencyPair();
            _takePair(currency0, currency1);
        } else if (action == Actions.SWEEP) {
            (Currency currency, address to) = params.decodeCurrencyAndAddress();
            _sweep(currency, _mapRecipient(to));
        } else {
            revert UnsupportedAction(action);
        }
    }

    function _msgSender() internal view override returns (address) {
        return _getLocker();
    }

    /// @dev Calling increase with 0 liquidity will credit the caller with any underlying fees of the position
    function _increase(
        uint256 tokenId,
        PositionConfig calldata config,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) internal {
        if (positionConfigs[tokenId] != config.toId()) revert IncorrectPositionConfigForTokenId(tokenId);
        // Note: The tokenId is used as the salt for this position, so every minted position has unique storage in the pool manager.
        BalanceDelta liquidityDelta = _modifyLiquidity(config, liquidity.toInt256(), bytes32(tokenId), hookData);
        liquidityDelta.validateMaxInNegative(amount0Max, amount1Max);
    }

    /// @dev Calling decrease with 0 liquidity will credit the caller with any underlying fees of the position
    function _decrease(
        uint256 tokenId,
        PositionConfig calldata config,
        uint256 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        bytes calldata hookData
    ) internal {
        if (!_isApprovedOrOwner(_msgSender(), tokenId)) revert NotApproved(_msgSender());
        if (positionConfigs[tokenId] != config.toId()) revert IncorrectPositionConfigForTokenId(tokenId);

        // Note: the tokenId is used as the salt.
        BalanceDelta liquidityDelta = _modifyLiquidity(config, -(liquidity.toInt256()), bytes32(tokenId), hookData);
        liquidityDelta.validateMinOut(amount0Min, amount1Min);
    }

    function _mint(
        PositionConfig calldata config,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) internal {
        // mint receipt token
        uint256 tokenId;
        // tokenId is assigned to current nextTokenId before incrementing it
        unchecked {
            tokenId = nextTokenId++;
        }
        _mint(owner, tokenId);

        // _beforeModify is not called here because the tokenId is newly minted
        BalanceDelta liquidityDelta = _modifyLiquidity(config, liquidity.toInt256(), bytes32(tokenId), hookData);
        liquidityDelta.validateMaxIn(amount0Max, amount1Max);
        positionConfigs[tokenId] = config.toId();
    }

    function _close(Currency currency) internal {
        // this address has applied all deltas on behalf of the user/owner
        // it is safe to close this entire delta because of slippage checks throughout the batched calls.
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);

        // the locker is the payer or receiver
        address caller = _msgSender();
        if (currencyDelta < 0) {
            _settle(currency, caller, uint256(-currencyDelta));
        } else if (currencyDelta > 0) {
            _take(currency, caller, uint256(currencyDelta));
        }
    }

    /// @dev integrators may elect to forfeit positive deltas with clear
    /// provides a safety check that amount-to-clear is less than a user-provided maximum
    function _clear(Currency currency, uint256 amountMax) internal {
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);
        if (uint256(currencyDelta) > amountMax) revert ClearExceedsMaxAmount(currency, currencyDelta, amountMax);
        poolManager.clear(currency, uint256(currencyDelta));
    }

    function _settlePair(Currency currency0, Currency currency1) internal {
        // the locker is the payer when settling
        address caller = _msgSender();
        _settle(currency0, caller, _getFullSettleAmount(currency0));
        _settle(currency1, caller, _getFullSettleAmount(currency1));
    }

    function _takePair(Currency currency0, Currency currency1) internal {
        // the locker is the receiver when taking
        address caller = _msgSender();
        _take(currency0, caller, _getFullTakeAmount(currency0));
        _take(currency1, caller, _getFullTakeAmount(currency1));
    }

    /// @dev this is overloaded with ERC721Permit._burn
    function _burn(
        uint256 tokenId,
        PositionConfig calldata config,
        uint128 amount0Min,
        uint128 amount1Min,
        bytes calldata hookData
    ) internal {
        if (!_isApprovedOrOwner(_msgSender(), tokenId)) revert NotApproved(_msgSender());
        if (positionConfigs[tokenId] != config.toId()) revert IncorrectPositionConfigForTokenId(tokenId);
        uint256 liquidity = uint256(_getPositionLiquidity(config, tokenId));

        BalanceDelta liquidityDelta;
        // Can only call modify if there is non zero liquidity.
        if (liquidity > 0) {
            liquidityDelta = _modifyLiquidity(config, -(liquidity.toInt256()), bytes32(tokenId), hookData);
            liquidityDelta.validateMinOut(amount0Min, amount1Min);
        }

        delete positionConfigs[tokenId];
        // Burn the token.
        _burn(tokenId);
    }

    function _modifyLiquidity(
        PositionConfig calldata config,
        int256 liquidityChange,
        bytes32 salt,
        bytes calldata hookData
    ) internal returns (BalanceDelta liquidityDelta) {
        (liquidityDelta,) = poolManager.modifyLiquidity(
            config.poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: config.tickLower,
                tickUpper: config.tickUpper,
                liquidityDelta: liquidityChange,
                salt: salt
            }),
            hookData
        );
    }

    function _getPositionLiquidity(PositionConfig calldata config, uint256 tokenId)
        internal
        view
        returns (uint128 liquidity)
    {
        bytes32 positionId =
            Position.calculatePositionKey(address(this), config.tickLower, config.tickUpper, bytes32(tokenId));
        liquidity = poolManager.getPositionLiquidity(config.poolKey.toId(), positionId);
    }

    /// @notice Sweeps the entire contract balance of specified currency to the recipient
    function _sweep(Currency currency, address to) internal {
        uint256 balance = currency.balanceOfSelf();
        if (balance > 0) currency.transfer(to, balance);
    }

    // implementation of abstract function DeltaResolver._pay
    function _pay(Currency currency, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            // TODO: currency is guaranteed to not be eth so the native check in transfer is not optimal.
            currency.transfer(address(poolManager), amount);
        } else {
            permit2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));
        }
    }
}
