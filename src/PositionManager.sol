// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {ERC721Permit_v4} from "./base/ERC721Permit_v4.sol";
import {ReentrancyLock} from "./base/ReentrancyLock.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {Multicall_v4} from "./base/Multicall_v4.sol";
import {PoolInitializer} from "./base/PoolInitializer.sol";
import {PositionConfig, PositionConfigLibrary} from "./libraries/PositionConfig.sol";
import {Notifier} from "./base/Notifier.sol";
import {INotifier} from "./interfaces/INotifier.sol";
import {Permit2Forwarder} from "./base/Permit2Forwarder.sol";
import {PositionActionsRouter} from "./base/PositionActionsRouter.sol";

contract PositionManager is
    IPositionManager,
    ERC721Permit_v4,
    PoolInitializer,
    Multicall_v4,
    ReentrancyLock,
    PositionActionsRouter,
    Permit2Forwarder
{
    using SafeTransferLib for *;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 public nextTokenId = 1;

    mapping(uint256 tokenId => bytes32 config) internal positionConfigs;

    constructor(IPoolManager _poolManager, IAllowanceTransfer _permit2)
        PositionActionsRouter(_poolManager)
        Permit2Forwarder(_permit2)
        ERC721Permit_v4("Uniswap V4 Positions NFT", "UNI-V4-POSM")
    {}

    /// @notice Reverts if the deadline has passed
    /// @param deadline The timestamp at which the call is no longer valid, passed in by the caller
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        _;
    }

    // TODO: to be implemented after audits
    function tokenURI(uint256) public pure override returns (string memory) {
        return "https://example.com";
    }

    /// @notice Reverts if the caller is not the owner or approved for the ERC721 token
    /// @param caller The address of the caller
    /// @param tokenId the unique identifier of the ERC721 token
    /// @dev either msg.sender or _msgSender() is passed in as the caller
    /// _msgSender() should ONLY be used if this is being called from within the unlockCallback
    modifier onlyIfApproved(address caller, uint256 tokenId) override {
        if (!_isApprovedOrOwner(caller, tokenId)) revert NotApproved(caller);
        _;
    }

    /// @notice Reverts if the hash of the config does not equal the saved hash
    /// @param tokenId the unique identifier of the ERC721 token
    /// @param config the PositionConfig to check against
    modifier onlyValidConfig(uint256 tokenId, PositionConfig calldata config) override {
        if (positionConfigs.getConfigId(tokenId) != config.toId()) revert IncorrectPositionConfigForTokenId(tokenId);
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

    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    /// @dev overrides solmate transferFrom in case a notification to subscribers is needed
    function transferFrom(address from, address to, uint256 id) public override {
        super.transferFrom(from, to, id);
        if (positionConfigs.hasSubscriber(id)) _notifyTransfer(id, from, to);
    }

    function getPositionLiquidity(uint256 tokenId, PositionConfig calldata config)
        public
        view
        override
        returns (uint128 liquidity)
    {
        bytes32 positionId =
            Position.calculatePositionKey(address(this), config.tickLower, config.tickUpper, bytes32(tokenId));
        liquidity = poolManager.getPositionLiquidity(config.poolKey.toId(), positionId);
    }

    /// @inheritdoc IPositionManager
    function getPositionConfigId(uint256 tokenId) external view returns (bytes32) {
        return positionConfigs.getConfigId(tokenId);
    }

    /// @inheritdoc INotifier
    function hasSubscriber(uint256 tokenId) external view returns (bool) {
        return positionConfigs.hasSubscriber(tokenId);
    }

    function _useTokenId() internal override returns (uint256 tokenId) {
        // tokenId is assigned to current nextTokenId before incrementing it
        unchecked {
            tokenId = nextTokenId++;
        }
    }
}
