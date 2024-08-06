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

import {ERC721Permit_v4} from "./base/ERC721Permit_v4.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {Multicall_v4} from "./base/Multicall_v4.sol";
import {PoolInitializer} from "./base/PoolInitializer.sol";
import {DeltaResolver} from "./base/DeltaResolver.sol";
import {PositionConfig, PositionConfigLibrary} from "./libraries/PositionConfig.sol";
import {BaseActionsRouter} from "./base/BaseActionsRouter.sol";
import {Actions} from "./libraries/Actions.sol";
import {Notifier} from "./base/Notifier.sol";
import {CalldataDecoder} from "./libraries/CalldataDecoder.sol";
import {INotifier} from "./interfaces/INotifier.sol";
import {Permit2Forwarder} from "./base/Permit2Forwarder.sol";
import {SlippageCheckLibrary} from "./libraries/SlippageCheck.sol";
import {PosmActionsRouter} from "./base/PosmActionsRouter.sol";

contract PositionManager is IPositionManager, PosmActionsRouter, ERC721Permit_v4, PoolInitializer, Multicall_v4 {
    using SafeTransferLib for *;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using PositionConfigLibrary for *;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;
    using CalldataDecoder for bytes;
    using SlippageCheckLibrary for BalanceDelta;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 public nextTokenId = 1;

    constructor(IPoolManager _poolManager, IAllowanceTransfer _permit2)
        PosmActionsRouter(_poolManager, _permit2)
        ERC721Permit_v4("Uniswap V4 Positions NFT", "UNI-V4-POSM")
    {}

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

    /// @dev overrides solmate transferFrom in case a notification to subscribers is needed
    function transferFrom(address from, address to, uint256 id) public virtual override {
        super.transferFrom(from, to, id);
        if (positionConfigs.hasSubscriber(id)) _notifyTransfer(id, from, to);
    }

    function _mintERC721(address to) internal override(PosmActionsRouter) returns (uint256 tokenId) {
        // tokenId is assigned to current nextTokenId before incrementing it
        unchecked {
            tokenId = nextTokenId++;
        }
        _mint(to, tokenId);
    }

    function _burnERC721(uint256 tokenId) internal override(PosmActionsRouter) {
        _burn(tokenId);
    }

    modifier onlyIfApproved(address caller, uint256 tokenId) override {
        if (!_isApprovedOrOwner(caller, tokenId)) revert(); // TODO: NotApproved(caller);
        _;
    }

    /// @notice Reverts if the deadline has passed
    /// @param deadline The timestamp at which the call is no longer valid, passed in by the caller
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert(); // TODO: error DeadlinePassed();
        _;
    }
}
