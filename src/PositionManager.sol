// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IPositionDescriptor} from "./interfaces/IPositionDescriptor.sol";
import {ERC721Permit_v4} from "./base/ERC721Permit_v4.sol";
import {ReentrancyLock} from "./base/ReentrancyLock.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {Multicall_v4} from "./base/Multicall_v4.sol";
import {PoolInitializer_v4} from "./base/PoolInitializer_v4.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {BaseActionsRouter} from "./base/BaseActionsRouter.sol";
import {Actions} from "./libraries/Actions.sol";
import {Notifier} from "./base/Notifier.sol";
import {CalldataDecoder} from "./libraries/CalldataDecoder.sol";
import {Permit2Forwarder} from "./base/Permit2Forwarder.sol";
import {SlippageCheck} from "./libraries/SlippageCheck.sol";
import {PositionInfo, PositionInfoLibrary} from "./libraries/PositionInfoLibrary.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {NativeWrapper} from "./base/NativeWrapper.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";

//                                           444444444
//                                444444444444      444444
//                              444              44     4444
//                             44         4      44        444
//                            44         44       44         44
//                           44          44        44         44
//                          44       444444          44        44
//                         444          4444           4444    44
//                         44             4444                 444444444444444444
//                         44             44  4                44444           444444
//        444444444444    44              4                444                      44
//        44        44444444              4             444                         44
//       444              44                          44                           444
//        44               4  4444444444444444444444444           4444444444     4444
//         44              44444444444444444444444444      444               44444
//          444                                  44 44444444444444444444444444
//           4444                             444444444444444444444444
//              4444                      444444    444444444444444
//                 44444              444444        44444444444444444444444
//                     444444444444444    4           44444 44444444444444444444
//                           444                          444444444444444444444444444
//                           444                           44444  44444444444     44444444
//                          444                               4   44444444444444   444444444
//                         4444 444                               44 4444444444444     44444444
//                         44  44444         44444444             44444444444444444444     44444
//                        444 444444        4444  4444             444444444444444444     44  4444
//                 4444   44  44444        44444444444             444444444444444444444    44444444
//                     44444   4444        4444444444             444444444444444444444444     44444
//                 44444 44444 444         444444                4444444444444444444444444       44444
//                       4444 44         44                     4 44444444444444444444444444   444 44444
//                   44444444 444  44   4    4         444444  4 44444444444444444444444444444   4444444
//                        444444    44       44444444444       44444444444444 444444444444444      444444
//                     444444 44   4444      44444       44     44444444444444444444444 4444444      44444
//                   44    444444   44   444444444 444        4444444444444444444444444444444444   4444444
//                       44  4444444444444    44  44  44       4444444444444444444444444444444       444444
//                      44  44444444444444444444444444  4   44 4444444444444444444444444444444    4   444444
//                     4    4444                     4    4 4444444444444444444444444              44 4444444
//                          4444                          4444444444444444444444444    4   4444     44444444
//                          4444                         444444444444444444444444  44444     44444 4444444444
//                          44444  44                  444444444444444444444444444444444444444444444444444444
//                          44444444444               4444444444444444444444444444444444444444444444444444444
//                           4444444444444           44444444444444444444444444444444444444444444444444444444
//                           444444444444444         444444444444444444444444444444444444444444444444444444444
//                            44444444444444444     4444444444444444444444444444444444444444444444444444444444
//                            44444444444444444     44444444444444444444444444444444444444444444444444444444
//                            44444444444444444444  444444444444444444444444444444444444444444444444444444444
//                            444444444444444444444 444444444444444444444444444444444444444444444444444444444
//                              444444444444444444444 4444444444444444444444444444444444444444444444444444444
//                              44444444444444444444444444444444444444444444444444444444444444444444444444444
//                               444444444444444444444444444444444444444444444444444444444444444444444444444
//                                44444444444444444444444444444444444444444444444444444444444444444444444444
//                               44444444444444444444444444444444444444444444444444      444444444444444444
//                             444444444444444444444444444444444444444444444444       44444444444444444444
//                           444   444   444   44  444444444444444444444 4444      444444444444444444444
//                           444  444    44    44  44444444 4444444444444       44444444444444444444444
//                            444 444   4444   4444 4444444444444444         44444444444444444444444444
//                      4444444444444444444444444444444444444444        44444444444444444444444444444
//                       444        4444444444444444444444444       44444444444444444444444444444444
//                          4444444       444444444444         4444444444444444444444444444444444
//                             4444444444                 44444444444444444444444444444444444
//                                444444444444444444444444444444444444444444444444444444
//                                     44444444444444444444444444444444444444444
//                                              4444444444444444444

/// @notice The PositionManager (PosM) contract is responsible for creating liquidity positions on v4.
/// PosM mints and manages ERC721 tokens associated with each position.
contract PositionManager is
    IPositionManager,
    ERC721Permit_v4,
    PoolInitializer_v4,
    Multicall_v4,
    DeltaResolver,
    ReentrancyLock,
    BaseActionsRouter,
    Notifier,
    Permit2Forwarder,
    NativeWrapper
{
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;
    using CalldataDecoder for bytes;
    using SlippageCheck for BalanceDelta;

    /// @inheritdoc IPositionManager
    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 public nextTokenId = 1;

    IPositionDescriptor public immutable tokenDescriptor;

    mapping(uint256 tokenId => PositionInfo info) public positionInfo;
    mapping(bytes25 poolId => PoolKey poolKey) public poolKeys;

    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9
    )
        BaseActionsRouter(_poolManager)
        Permit2Forwarder(_permit2)
        ERC721Permit_v4("Uniswap v4 Positions NFT", "UNI-V4-POSM")
        Notifier(_unsubscribeGasLimit)
        NativeWrapper(_weth9)
    {
        tokenDescriptor = _tokenDescriptor;
    }

    /// @notice Reverts if the deadline has passed
    /// @param deadline The timestamp at which the call is no longer valid, passed in by the caller
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        _;
    }

    /// @notice Reverts if the caller is not the owner or approved for the ERC721 token
    /// @param caller The address of the caller
    /// @param tokenId the unique identifier of the ERC721 token
    /// @dev either msg.sender or msgSender() is passed in as the caller
    /// msgSender() should ONLY be used if this is called from within the unlockCallback, unless the codepath has reentrancy protection
    modifier onlyIfApproved(address caller, uint256 tokenId) override {
        if (!_isApprovedOrOwner(caller, tokenId)) revert NotApproved(caller);
        _;
    }

    /// @notice Enforces that the PoolManager is locked.
    modifier onlyIfPoolManagerLocked() override {
        if (poolManager.isUnlocked()) revert PoolManagerMustBeLocked();
        _;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return IPositionDescriptor(tokenDescriptor).tokenURI(this, tokenId);
    }

    /// @inheritdoc IPositionManager
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
        external
        payable
        isNotLocked
        checkDeadline(deadline)
    {
        _executeActions(unlockData);
    }

    /// @inheritdoc IPositionManager
    function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params)
        external
        payable
        isNotLocked
    {
        _executeActionsWithoutUnlock(actions, params);
    }

    /// @inheritdoc BaseActionsRouter
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    function _handleAction(uint256 action, bytes calldata params) internal virtual override {
        if (action < Actions.SETTLE) {
            if (action == Actions.INCREASE_LIQUIDITY) {
                (uint256 tokenId, uint256 liquidity, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData) =
                    params.decodeModifyLiquidityParams();
                _increase(tokenId, liquidity, amount0Max, amount1Max, hookData);
                return;
            } else if (action == Actions.INCREASE_LIQUIDITY_FROM_DELTAS) {
                (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData) =
                    params.decodeIncreaseLiquidityFromDeltasParams();
                _increaseFromDeltas(tokenId, amount0Max, amount1Max, hookData);
                return;
            } else if (action == Actions.DECREASE_LIQUIDITY) {
                (uint256 tokenId, uint256 liquidity, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) =
                    params.decodeModifyLiquidityParams();
                _decrease(tokenId, liquidity, amount0Min, amount1Min, hookData);
                return;
            } else if (action == Actions.MINT_POSITION) {
                (
                    PoolKey calldata poolKey,
                    int24 tickLower,
                    int24 tickUpper,
                    uint256 liquidity,
                    uint128 amount0Max,
                    uint128 amount1Max,
                    address owner,
                    bytes calldata hookData
                ) = params.decodeMintParams();
                _mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, _mapRecipient(owner), hookData);
                return;
            } else if (action == Actions.MINT_POSITION_FROM_DELTAS) {
                (
                    PoolKey calldata poolKey,
                    int24 tickLower,
                    int24 tickUpper,
                    uint128 amount0Max,
                    uint128 amount1Max,
                    address owner,
                    bytes calldata hookData
                ) = params.decodeMintFromDeltasParams();
                _mintFromDeltas(poolKey, tickLower, tickUpper, amount0Max, amount1Max, _mapRecipient(owner), hookData);
                return;
            } else if (action == Actions.BURN_POSITION) {
                // Will automatically decrease liquidity to 0 if the position is not already empty.
                (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) =
                    params.decodeBurnParams();
                _burn(tokenId, amount0Min, amount1Min, hookData);
                return;
            }
        } else {
            if (action == Actions.SETTLE_PAIR) {
                (Currency currency0, Currency currency1) = params.decodeCurrencyPair();
                _settlePair(currency0, currency1);
                return;
            } else if (action == Actions.TAKE_PAIR) {
                (Currency currency0, Currency currency1, address recipient) = params.decodeCurrencyPairAndAddress();
                _takePair(currency0, currency1, _mapRecipient(recipient));
                return;
            } else if (action == Actions.SETTLE) {
                (Currency currency, uint256 amount, bool payerIsUser) = params.decodeCurrencyUint256AndBool();
                _settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
                return;
            } else if (action == Actions.TAKE) {
                (Currency currency, address recipient, uint256 amount) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _mapTakeAmount(amount, currency));
                return;
            } else if (action == Actions.CLOSE_CURRENCY) {
                Currency currency = params.decodeCurrency();
                _close(currency);
                return;
            } else if (action == Actions.CLEAR_OR_TAKE) {
                (Currency currency, uint256 amountMax) = params.decodeCurrencyAndUint256();
                _clearOrTake(currency, amountMax);
                return;
            } else if (action == Actions.SWEEP) {
                (Currency currency, address to) = params.decodeCurrencyAndAddress();
                _sweep(currency, _mapRecipient(to));
                return;
            } else if (action == Actions.WRAP) {
                uint256 amount = params.decodeUint256();
                _wrap(_mapWrapUnwrapAmount(CurrencyLibrary.ADDRESS_ZERO, amount, Currency.wrap(address(WETH9))));
                return;
            } else if (action == Actions.UNWRAP) {
                uint256 amount = params.decodeUint256();
                _unwrap(_mapWrapUnwrapAmount(Currency.wrap(address(WETH9)), amount, CurrencyLibrary.ADDRESS_ZERO));
                return;
            }
        }
        revert UnsupportedAction(action);
    }

    /// @dev Calling increase with 0 liquidity will credit the caller with any underlying fees of the position
    function _increase(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) internal onlyIfApproved(msgSender(), tokenId) {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);

        // Note: The tokenId is used as the salt for this position, so every minted position has unique storage in the pool manager.
        (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
            _modifyLiquidity(info, poolKey, liquidity.toInt256(), bytes32(tokenId), hookData);
        // Slippage checks should be done on the principal liquidityDelta which is the liquidityDelta - feesAccrued
        (liquidityDelta - feesAccrued).validateMaxIn(amount0Max, amount1Max);
    }

    /// @dev The liquidity delta is derived from open deltas in the pool manager.
    function _increaseFromDeltas(uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData)
        internal
        onlyIfApproved(msgSender(), tokenId)
    {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);

        uint256 liquidity;
        {
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

            // Use the credit on the pool manager as the amounts for the mint.
            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(info.tickLower()),
                TickMath.getSqrtPriceAtTick(info.tickUpper()),
                _getFullCredit(poolKey.currency0),
                _getFullCredit(poolKey.currency1)
            );
        }

        // Note: The tokenId is used as the salt for this position, so every minted position has unique storage in the pool manager.
        (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
            _modifyLiquidity(info, poolKey, liquidity.toInt256(), bytes32(tokenId), hookData);
        // Slippage checks should be done on the principal liquidityDelta which is the liquidityDelta - feesAccrued
        (liquidityDelta - feesAccrued).validateMaxIn(amount0Max, amount1Max);
    }

    /// @dev Calling decrease with 0 liquidity will credit the caller with any underlying fees of the position
    function _decrease(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        bytes calldata hookData
    ) internal onlyIfApproved(msgSender(), tokenId) {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);

        // Note: the tokenId is used as the salt.
        (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
            _modifyLiquidity(info, poolKey, -(liquidity.toInt256()), bytes32(tokenId), hookData);
        // Slippage checks should be done on the principal liquidityDelta which is the liquidityDelta - feesAccrued
        (liquidityDelta - feesAccrued).validateMinOut(amount0Min, amount1Min);
    }

    function _mint(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
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

        // Initialize the position info
        PositionInfo info = PositionInfoLibrary.initialize(poolKey, tickLower, tickUpper);
        positionInfo[tokenId] = info;

        // Store the poolKey if it is not already stored.
        // On UniswapV4, the minimum tick spacing is 1, which means that if the tick spacing is 0, the pool key has not been set.
        bytes25 poolId = info.poolId();
        if (poolKeys[poolId].tickSpacing == 0) {
            poolKeys[poolId] = poolKey;
        }

        // fee delta can be ignored as this is a new position
        (BalanceDelta liquidityDelta,) =
            _modifyLiquidity(info, poolKey, liquidity.toInt256(), bytes32(tokenId), hookData);
        liquidityDelta.validateMaxIn(amount0Max, amount1Max);
    }

    function _mintFromDeltas(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) internal {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        // Use the credit on the pool manager as the amounts for the mint.
        uint256 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            _getFullCredit(poolKey.currency0),
            _getFullCredit(poolKey.currency1)
        );

        _mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData);
    }

    /// @dev this is overloaded with ERC721Permit_v4._burn
    function _burn(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
        internal
        onlyIfApproved(msgSender(), tokenId)
    {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);

        uint256 liquidity = uint256(_getLiquidity(tokenId, poolKey, info.tickLower(), info.tickUpper()));

        address owner = ownerOf(tokenId);

        // Clear the position info.
        positionInfo[tokenId] = PositionInfoLibrary.EMPTY_POSITION_INFO;
        // Burn the token.
        _burn(tokenId);

        // Can only call modify if there is non zero liquidity.
        BalanceDelta feesAccrued;
        if (liquidity > 0) {
            BalanceDelta liquidityDelta;
            // do not use _modifyLiquidity as we do not need to notify on modification for burns.
            ModifyLiquidityParams memory params = ModifyLiquidityParams({
                tickLower: info.tickLower(),
                tickUpper: info.tickUpper(),
                liquidityDelta: -(liquidity.toInt256()),
                salt: bytes32(tokenId)
            });
            (liquidityDelta, feesAccrued) = poolManager.modifyLiquidity(poolKey, params, hookData);
            // Slippage checks should be done on the principal liquidityDelta which is the liquidityDelta - feesAccrued
            (liquidityDelta - feesAccrued).validateMinOut(amount0Min, amount1Min);
        }

        // deletes then notifies the subscriber
        if (info.hasSubscriber()) _removeSubscriberAndNotifyBurn(tokenId, owner, info, liquidity, feesAccrued);
    }

    function _settlePair(Currency currency0, Currency currency1) internal {
        // the locker is the payer when settling
        address caller = msgSender();
        _settle(currency0, caller, _getFullDebt(currency0));
        _settle(currency1, caller, _getFullDebt(currency1));
    }

    function _takePair(Currency currency0, Currency currency1, address recipient) internal {
        _take(currency0, recipient, _getFullCredit(currency0));
        _take(currency1, recipient, _getFullCredit(currency1));
    }

    function _close(Currency currency) internal {
        // this address has applied all deltas on behalf of the user/owner
        // it is safe to close this entire delta because of slippage checks throughout the batched calls.
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);

        // the locker is the payer or receiver
        address caller = msgSender();
        if (currencyDelta < 0) {
            // Casting is safe due to limits on the total supply of a pool
            _settle(currency, caller, uint256(-currencyDelta));
        } else {
            _take(currency, caller, uint256(currencyDelta));
        }
    }

    /// @dev integrators may elect to forfeit positive deltas with clear
    /// if the forfeit amount exceeds the user-specified max, the amount is taken instead
    /// if there is no credit, no call is made.
    function _clearOrTake(Currency currency, uint256 amountMax) internal {
        uint256 delta = _getFullCredit(currency);
        if (delta == 0) return;

        // forfeit the delta if its less than or equal to the user-specified limit
        if (delta <= amountMax) {
            poolManager.clear(currency, delta);
        } else {
            _take(currency, msgSender(), delta);
        }
    }

    /// @notice Sweeps the entire contract balance of specified currency to the recipient
    function _sweep(Currency currency, address to) internal {
        uint256 balance = currency.balanceOfSelf();
        if (balance > 0) currency.transfer(to, balance);
    }

    /// @dev if there is a subscriber attached to the position, this function will notify the subscriber
    function _modifyLiquidity(
        PositionInfo info,
        PoolKey memory poolKey,
        int256 liquidityChange,
        bytes32 salt,
        bytes calldata hookData
    ) internal returns (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) {
        (liquidityDelta, feesAccrued) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: info.tickLower(),
                tickUpper: info.tickUpper(),
                liquidityDelta: liquidityChange,
                salt: salt
            }),
            hookData
        );

        if (info.hasSubscriber()) {
            _notifyModifyLiquidity(uint256(salt), liquidityChange, feesAccrued);
        }
    }

    // implementation of abstract function DeltaResolver._pay
    function _pay(Currency currency, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            currency.transfer(address(poolManager), amount);
        } else {
            // Casting from uint256 to uint160 is safe due to limits on the total supply of a pool
            permit2.transferFrom(payer, address(poolManager), uint160(amount), Currency.unwrap(currency));
        }
    }

    /// @notice an internal helper used by Notifier
    function _setSubscribed(uint256 tokenId) internal override {
        positionInfo[tokenId] = positionInfo[tokenId].setSubscribe();
    }

    /// @notice an internal helper used by Notifier
    function _setUnsubscribed(uint256 tokenId) internal override {
        positionInfo[tokenId] = positionInfo[tokenId].setUnsubscribe();
    }

    /// @dev overrides solmate transferFrom in case a notification to subscribers is needed
    /// @dev will revert if pool manager is locked
    function transferFrom(address from, address to, uint256 id) public virtual override onlyIfPoolManagerLocked {
        super.transferFrom(from, to, id);
        if (positionInfo[id].hasSubscriber()) _unsubscribe(id);
    }

    /// @inheritdoc IPositionManager
    function getPoolAndPositionInfo(uint256 tokenId) public view returns (PoolKey memory poolKey, PositionInfo info) {
        info = positionInfo[tokenId];
        poolKey = poolKeys[info.poolId()];
    }

    /// @inheritdoc IPositionManager
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity) {
        (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);
        liquidity = _getLiquidity(tokenId, poolKey, info.tickLower(), info.tickUpper());
    }

    function _getLiquidity(uint256 tokenId, PoolKey memory poolKey, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 liquidity)
    {
        bytes32 positionId = Position.calculatePositionKey(address(this), tickLower, tickUpper, bytes32(tokenId));
        liquidity = poolManager.getPositionLiquidity(poolKey.toId(), positionId);
    }
}
