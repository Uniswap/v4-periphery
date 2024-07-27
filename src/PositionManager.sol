// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {ERC721Permit} from "./base/ERC721Permit.sol";
import {ReentrancyLock} from "./base/ReentrancyLock.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {SafeCallback} from "./base/SafeCallback.sol";
import {Multicall} from "./base/Multicall.sol";
import {PoolInitializer} from "./base/PoolInitializer.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {PositionConfig, PositionConfigLibrary} from "./libraries/PositionConfig.sol";
import {BaseActionsRouterReturns} from "./base/BaseActionsRouterReturns.sol";
import {Actions} from "./libraries/Actions.sol";

contract PositionManager is
    IPositionManager,
    ERC721Permit,
    PoolInitializer,
    Multicall,
    SafeCallback,
    DeltaResolver,
    ReentrancyLock,
    BaseActionsRouterReturns
{
    using SafeTransferLib for *;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using PositionConfigLibrary for PositionConfig;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 public nextTokenId = 1;

    /// @inheritdoc IPositionManager
    mapping(uint256 tokenId => bytes32 configId) public positionConfigs;

    uint256 public constant FULL_DELTA = type(uint256).max;

    constructor(IPoolManager _poolManager)
        BaseActionsRouterReturns(_poolManager)
        ERC721Permit("Uniswap V4 Positions NFT", "UNI-V4-POSM", "1")
    {}

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        _;
    }

    /// @param unlockData is an encoding of actions, params, and currencies
    /// @return returnData is the endocing of each actions return information
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
        external
        payable
        isNotLocked
        checkDeadline(deadline)
        returns (bytes[] memory)
    {
        // For now POSM will bubble up sub call return values.
        return _executeActions(unlockData);
    }

    function _handleAction(uint256 action, bytes calldata params) internal override returns (bytes memory) {
        if (action == Actions.INCREASE_LIQUIDITY) {
            return _increase(params);
        } else if (action == Actions.DECREASE_LIQUIDITY) {
            return _decrease(params);
        } else if (action == Actions.MINT_POSITION) {
            return _mint(params);
        } else if (action == Actions.CLOSE_CURRENCY) {
            return _close(params);
        } else if (action == Actions.BURN_POSITION) {
            return _burn(params);
        } else if (action == Actions.SETTLE_WITH_BALANCE) {
            return _settleWithBalance(params);
        } else if (action == Actions.SWEEP_ERC20_TO) {
            _sweepERC20To(params);
        } else {
            revert UnsupportedAction(action);
        }
    }

    function _msgSender() internal view override returns (address) {
        return _getLocker();
    }

    /// @param params is an encoding of uint256 tokenId, PositionConfig memory config, uint256 liquidity, bytes hookData
    /// @return returns an encoding of the BalanceDelta applied by this increase call, including credited fees.
    /// @dev Calling increase with 0 liquidity will credit the caller with any underlying fees of the position
    function _increase(bytes memory params) internal returns (bytes memory) {
        (uint256 tokenId, PositionConfig memory config, uint256 liquidity, bytes memory hookData) =
            abi.decode(params, (uint256, PositionConfig, uint256, bytes));

        if (positionConfigs[tokenId] != config.toId()) revert IncorrectPositionConfigForTokenId(tokenId);
        // Note: The tokenId is used as the salt for this position, so every minted position has unique storage in the pool manager.
        BalanceDelta delta = _modifyLiquidity(config, liquidity.toInt256(), bytes32(tokenId), hookData);
        return abi.encode(delta);
    }

    /// @param params is an encoding of uint256 tokenId, PositionConfig memory config, uint256 liquidity, bytes hookData
    /// @return returns an encoding of the BalanceDelta applied by this increase call, including credited fees.
    /// @dev Calling decrease with 0 liquidity will credit the caller with any underlying fees of the position
    function _decrease(bytes memory params) internal returns (bytes memory) {
        (uint256 tokenId, PositionConfig memory config, uint256 liquidity, bytes memory hookData) =
            abi.decode(params, (uint256, PositionConfig, uint256, bytes));

        if (!_isApprovedOrOwner(_msgSender(), tokenId)) revert NotApproved(_msgSender());
        if (positionConfigs[tokenId] != config.toId()) revert IncorrectPositionConfigForTokenId(tokenId);

        // Note: the tokenId is used as the salt.
        BalanceDelta delta = _modifyLiquidity(config, -(liquidity.toInt256()), bytes32(tokenId), hookData);
        return abi.encode(delta);
    }

    /// @param params is an encoding of PositionConfig memory config, uint256 liquidity, address recipient, bytes hookData where recipient is the receiver / owner of the ERC721
    /// @return returns an encoding of the BalanceDelta from the initial increase
    function _mint(bytes memory params) internal returns (bytes memory) {
        (PositionConfig memory config, uint256 liquidity, address owner, bytes memory hookData) =
            abi.decode(params, (PositionConfig, uint256, address, bytes));

        // mint receipt token
        uint256 tokenId;
        // tokenId is assigned to current nextTokenId before incrementing it
        unchecked {
            tokenId = nextTokenId++;
        }
        _mint(owner, tokenId);

        // _beforeModify is not called here because the tokenId is newly minted
        BalanceDelta delta = _modifyLiquidity(config, liquidity.toInt256(), bytes32(tokenId), hookData);

        positionConfigs[tokenId] = config.toId();

        return abi.encode(delta);
    }

    /// @param params is an encoding of the Currency to close
    /// @return bytes an encoding of int256 the balance of the currency being settled by this call
    function _close(bytes memory params) internal returns (bytes memory) {
        (Currency currency) = abi.decode(params, (Currency));
        // this address has applied all deltas on behalf of the user/owner
        // it is safe to close this entire delta because of slippage checks throughout the batched calls.
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);

        // the locker is the payer or receiver
        address caller = _msgSender();
        if (currencyDelta < 0) {
            _settle(currency, caller, uint256(-currencyDelta));

            // if there are native tokens left over after settling, return to locker
            if (currency.isNative()) _sweepNativeToken(caller);
        } else if (currencyDelta > 0) {
            _take(currency, caller, uint256(currencyDelta));
        }

        return abi.encode(currencyDelta);
    }

    /// @param params is an encoding of Currency, uint256 amount
    /// @dev if amount == FULL_DELTA, it settles the full negative delta
    /// @dev uses this addresses balance to settle a negative delta
    /// @dev Should not be called for NATIVE settling bc does not sweep.
    function _settleWithBalance(bytes memory params) internal returns (bytes memory) {
        (Currency currency, uint256 amount) = abi.decode(params, (Currency, uint256));

        amount = amount == FULL_DELTA ? _getFullSettleAmount(currency) : amount;

        // set the payer to this address, performs a transfer.
        _settle(currency, address(this), amount);
        return abi.encode(amount);
    }

    /// @param params is an encoding of uint256 tokenId, PositionConfig memory config, bytes hookData
    /// @dev this is overloaded with ERC721Permit._burn
    function _burn(bytes memory params) internal returns (bytes memory) {
        (uint256 tokenId, PositionConfig memory config, bytes memory hookData) =
            abi.decode(params, (uint256, PositionConfig, bytes));

        if (!_isApprovedOrOwner(_msgSender(), tokenId)) revert NotApproved(_msgSender());
        if (positionConfigs[tokenId] != config.toId()) revert IncorrectPositionConfigForTokenId(tokenId);
        uint256 liquidity = uint256(_getPositionLiquidity(config, tokenId));

        // Can only call modify if there is non zero liquidity.
        BalanceDelta delta;

        if (liquidity > 0) delta = _modifyLiquidity(config, -(liquidity.toInt256()), bytes32(tokenId), hookData);

        delete positionConfigs[tokenId];
        // Burn the token.
        _burn(tokenId);
        return abi.encode(delta);
    }

    function _modifyLiquidity(PositionConfig memory config, int256 liquidityChange, bytes32 salt, bytes memory hookData)
        internal
        returns (BalanceDelta liquidityDelta)
    {
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

    function _getPositionLiquidity(PositionConfig memory config, uint256 tokenId)
        internal
        view
        returns (uint128 liquidity)
    {
        // TODO: Calculate positionId with Position.calculatePositionKey in v4-core.
        bytes32 positionId =
            keccak256(abi.encodePacked(address(this), config.tickLower, config.tickUpper, bytes32(tokenId)));
        liquidity = poolManager.getPositionLiquidity(config.poolKey.toId(), positionId);
    }

    /// @dev Send excess native tokens back to the recipient (locker)
    /// @param recipient the receiver of the excess native tokens. Should be the caller, the one that sent the native tokens
    function _sweepNativeToken(address recipient) internal {
        uint256 nativeBalance = address(this).balance;
        if (nativeBalance > 0) recipient.safeTransferETH(nativeBalance);
    }

    /// @param params an encoding of Currency, address
    function _sweepERC20To(bytes calldata params) internal {
        (Currency currency, address to) = abi.decode(params, (Currency, address));
        uint256 tokenBalance = ERC20(Currency.unwrap(currency)).balanceOf(address(this));
        if (tokenBalance > 0) currency.transfer(to, tokenBalance);
    }

    // implementation of abstract function DeltaResolver._pay
    function _pay(Currency currency, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            // TODO: This transfer no eth check. This is guaranteed to not be eth.
            currency.transfer(address(poolManager), amount);
        } else {
            // TODO this should use Permit2
            ERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), amount);
        }
    }

    function _getFullSettleAmount(Currency currency) private view returns (uint256 amount) {
        int256 _amount = poolManager.currencyDelta(address(this), currency);
        // If the amount is positive, it should be taken not settled for.
        if (_amount > 0) revert IncorrectUseOfSettle();
        amount = uint256(-_amount);
    }

    function _getFullTakeAmount(Currency currency) private view returns (uint256 amount) {
        int256 _amount = poolManager.currencyDelta(address(this), currency);
        // If the amount is negative, it should be settled not taken.
        if (_amount < 0) revert IncorrectUseOfTake();
        amount = uint256(_amount);
    }
}
