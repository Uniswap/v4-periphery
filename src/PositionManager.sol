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

contract PositionManager is
    IPositionManager,
    ERC721Permit,
    PoolInitializer,
    Multicall,
    DeltaResolver,
    ReentrancyLock,
    BaseActionsRouter
{
    using SafeTransferLib for *;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using PositionConfigLibrary for PositionConfig;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using CalldataDecoder for bytes;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 public nextTokenId = 1;

    /// @inheritdoc IPositionManager
    mapping(uint256 tokenId => bytes32 configId) public positionConfigs;

    IAllowanceTransfer public immutable permit2;

    constructor(IPoolManager _poolManager, IAllowanceTransfer _permit2)
        BaseActionsRouter(_poolManager)
        ERC721Permit("Uniswap V4 Positions NFT", "UNI-V4-POSM", "1")
    {
        permit2 = _permit2;
    }

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

    function _handleAction(uint256 action, bytes calldata params) internal override {
        if (action == Actions.INCREASE_LIQUIDITY) {
            (uint256 tokenId, PositionConfig calldata config, uint256 liquidity, bytes calldata hookData) =
                params.decodeModifyLiquidityParams();
            _increase(tokenId, config, liquidity, hookData);
        } else if (action == Actions.DECREASE_LIQUIDITY) {
            (uint256 tokenId, PositionConfig calldata config, uint256 liquidity, bytes calldata hookData) =
                params.decodeModifyLiquidityParams();
            _decrease(tokenId, config, liquidity, hookData);
        } else if (action == Actions.MINT_POSITION) {
            (PositionConfig calldata config, uint256 liquidity, address owner, bytes calldata hookData) =
                params.decodeMintParams();
            _mint(config, liquidity, owner, hookData);
        } else if (action == Actions.CLOSE_CURRENCY) {
            Currency currency = params.decodeCurrency();
            _close(currency);
        } else if (action == Actions.BURN_POSITION) {
            // Will automatically decrease liquidity to 0 if the position is not already empty.
            (uint256 tokenId, PositionConfig calldata config, bytes calldata hookData) = params.decodeBurnParams();
            _burn(tokenId, config, hookData);
        } else if (action == Actions.SETTLE_WITH_BALANCE) {
            Currency currency = params.decodeCurrency();
            _settleWithBalance(currency);
        } else if (action == Actions.SWEEP) {
            (Currency currency, address to) = params.decodeCurrencyAndAddress();
            _sweep(currency, to);
        } else {
            revert UnsupportedAction(action);
        }
    }

    function _msgSender() internal view override returns (address) {
        return _getLocker();
    }

    /// @dev Calling increase with 0 liquidity will credit the caller with any underlying fees of the position
    function _increase(uint256 tokenId, PositionConfig calldata config, uint256 liquidity, bytes calldata hookData)
        internal
    {
        if (positionConfigs[tokenId] != config.toId()) revert IncorrectPositionConfigForTokenId(tokenId);
        // Note: The tokenId is used as the salt for this position, so every minted position has unique storage in the pool manager.
        BalanceDelta liquidityDelta = _modifyLiquidity(config, liquidity.toInt256(), bytes32(tokenId), hookData);
    }

    /// @dev Calling decrease with 0 liquidity will credit the caller with any underlying fees of the position
    function _decrease(uint256 tokenId, PositionConfig calldata config, uint256 liquidity, bytes calldata hookData)
        internal
    {
        if (!_isApprovedOrOwner(_msgSender(), tokenId)) revert NotApproved(_msgSender());
        if (positionConfigs[tokenId] != config.toId()) revert IncorrectPositionConfigForTokenId(tokenId);

        // Note: the tokenId is used as the salt.
        BalanceDelta liquidityDelta = _modifyLiquidity(config, -(liquidity.toInt256()), bytes32(tokenId), hookData);
    }

    function _mint(PositionConfig calldata config, uint256 liquidity, address owner, bytes calldata hookData)
        internal
    {
        // mint receipt token
        uint256 tokenId;
        // tokenId is assigned to current nextTokenId before incrementing it
        unchecked {
            tokenId = nextTokenId++;
        }
        _mint(owner, tokenId);

        // _beforeModify is not called here because the tokenId is newly minted
        BalanceDelta liquidityDelta = _modifyLiquidity(config, liquidity.toInt256(), bytes32(tokenId), hookData);

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

    /// @dev uses this addresses balance to settle a negative delta
    function _settleWithBalance(Currency currency) internal {
        // set the payer to this address, performs a transfer.
        _settle(currency, address(this), _getFullSettleAmount(currency));
    }

    /// @dev this is overloaded with ERC721Permit._burn
    function _burn(uint256 tokenId, PositionConfig calldata config, bytes calldata hookData) internal {
        if (!_isApprovedOrOwner(_msgSender(), tokenId)) revert NotApproved(_msgSender());
        if (positionConfigs[tokenId] != config.toId()) revert IncorrectPositionConfigForTokenId(tokenId);
        uint256 liquidity = uint256(_getPositionLiquidity(config, tokenId));

        BalanceDelta liquidityDelta;
        // Can only call modify if there is non zero liquidity.
        if (liquidity > 0) {
            liquidityDelta = _modifyLiquidity(config, -(liquidity.toInt256()), bytes32(tokenId), hookData);
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
