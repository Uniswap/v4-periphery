// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {VanityAddressLib} from "./libraries/VanityAddressLib.sol";
import {IUniswapV4DeployerCompetition} from "./interfaces/IUniswapV4DeployerCompetition.sol";

/// @title UniswapV4DeployerCompetition
/// @notice A contract to crowdsource a salt for the best Uniswap V4 address
contract UniswapV4DeployerCompetition is IUniswapV4DeployerCompetition {
    using VanityAddressLib for address;

    /// @dev The salt for the best address found so far
    bytes32 public bestAddressSalt;
    /// @dev The submitter of the best address found so far
    address public bestAddressSubmitter;

    /// @dev The deadline for the competition
    uint256 public immutable competitionDeadline;
    /// @dev The init code hash of the V4 contract
    bytes32 public immutable initCodeHash;

    /// @dev The deployer who can initiate the deployment of the v4 PoolManager, until the exclusive deploy deadline.
    /// @dev After this deadline anyone can deploy.
    address public immutable deployer;
    /// @dev The deadline for exclusive deployment by deployer after deadline
    uint256 public immutable exclusiveDeployDeadline;

    constructor(
        bytes32 _initCodeHash,
        uint256 _competitionDeadline,
        address _exclusiveDeployer,
        uint256 _exclusiveDeployLength
    ) {
        initCodeHash = _initCodeHash;
        competitionDeadline = _competitionDeadline;
        exclusiveDeployDeadline = _competitionDeadline + _exclusiveDeployLength;
        deployer = _exclusiveDeployer;
    }

    /// @inheritdoc IUniswapV4DeployerCompetition
    function updateBestAddress(bytes32 salt) external {
        if (block.timestamp > competitionDeadline) {
            revert CompetitionOver(block.timestamp, competitionDeadline);
        }

        address saltSubAddress = address(bytes20(salt));
        if (saltSubAddress != msg.sender && saltSubAddress != address(0)) revert InvalidSender(salt, msg.sender);

        address newAddress = Create2.computeAddress(salt, initCodeHash);
        address _bestAddress = bestAddress();
        if (!newAddress.betterThan(_bestAddress)) {
            revert WorseAddress(newAddress, _bestAddress, newAddress.score(), _bestAddress.score());
        }

        bestAddressSalt = salt;
        bestAddressSubmitter = msg.sender;

        emit NewAddressFound(newAddress, msg.sender, newAddress.score());
    }

    /// @inheritdoc IUniswapV4DeployerCompetition
    function deploy(bytes memory bytecode) external {
        if (keccak256(bytecode) != initCodeHash) {
            revert InvalidBytecode();
        }

        if (block.timestamp <= competitionDeadline) {
            revert CompetitionNotOver(block.timestamp, competitionDeadline);
        }

        if (msg.sender != deployer && block.timestamp <= exclusiveDeployDeadline) {
            // anyone can deploy after the deadline
            revert NotAllowedToDeploy(msg.sender, deployer);
        }

        // the owner of the contract must be encoded in the bytecode
        Create2.deploy(0, bestAddressSalt, bytecode);
    }

    /// @dev returns the best address found so far
    function bestAddress() public view returns (address) {
        return Create2.computeAddress(bestAddressSalt, initCodeHash);
    }
}
