// SPADIX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {VanityAddressLib} from "./libraries/VanityAddressLib.sol";
import {IUniswapV4DeployerCompetition} from "./interfaces/IUniswapV4DeployerCompetition.sol";

/// @title UniswapV4DeployerCompetition
/// @notice A contract to crowdsource a salt for the best Uniswap V4 address
contract UniswapV4DeployerCompetition is IUniswapV4DeployerCompetition {
    using VanityAddressLib for address;

    /// @dev The salt for the best address found so far
    bytes32 public bestAddressSalt;
    /// @dev The best address found so far
    address public bestAddress;
    /// @dev The submitter of the best address found so far
    address public bestAddressSubmitter;

    /// @dev The deployer who can initiate the deployment of V4
    address public immutable deployer;
    /// @dev The owner of the V4 contract
    address public immutable v4Owner;
    /// @dev The deadline for the competition
    uint256 public immutable competitionDeadline;
    /// @dev The deadline for exclusive deployment by deployer after deadline
    uint256 public immutable exclusiveDeployDeadline;
    /// @dev The init code hash of the V4 contract
    bytes32 public immutable initCodeHash;

    constructor(bytes32 _initCodeHash, address _v4Owner, uint256 _competitionDeadline) {
        initCodeHash = _initCodeHash;
        v4Owner = _v4Owner;
        competitionDeadline = _competitionDeadline;
        exclusiveDeployDeadline = _competitionDeadline + 1 days;
        deployer = msg.sender;
    }

    /// @inheritdoc IUniswapV4DeployerCompetition
    function updateBestAddress(bytes32 salt) external override {
        if (block.timestamp > competitionDeadline) {
            revert CompetitionOver(block.timestamp, competitionDeadline);
        }

        address saltSubAddress = address(bytes20(salt));
        if (saltSubAddress != msg.sender && saltSubAddress != address(0)) revert InvalidSender(salt, msg.sender);

        address newAddress = Create2.computeAddress(salt, initCodeHash, address(this));
        if (bestAddress != address(0) && !newAddress.betterThan(bestAddress)) {
            revert WorseAddress(newAddress, bestAddress, newAddress.score(), bestAddress.score());
        }

        bestAddress = newAddress;
        bestAddressSalt = salt;
        bestAddressSubmitter = msg.sender;

        emit NewAddressFound(newAddress, msg.sender, newAddress.score());
    }

    /// @inheritdoc IUniswapV4DeployerCompetition
    function deploy(bytes memory bytecode) external override {
        if (keccak256(bytecode) != initCodeHash) {
            revert InvalidBytecode();
        }

        if (block.timestamp < competitionDeadline) {
            revert CompetitionNotOver(block.timestamp, competitionDeadline);
        }

        if (msg.sender != deployer && block.timestamp < exclusiveDeployDeadline) {
            // anyone can deploy after the deadline
            revert NotAllowedToDeploy(msg.sender, deployer);
        }

        // the owner of the contract must be encoded in the bytecode
        Create2.deploy(0, bestAddressSalt, bytecode);
    }
}
