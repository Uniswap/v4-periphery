// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {VanityAddressLib} from "./libraries/VanityAddressLib.sol";
import {IUniswapV4DeployerCompetition} from "./interfaces/IUniswapV4DeployerCompetition.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/// @title UniswapV4DeployerCompetition
/// @notice A contract to crowdsource a salt for the best Uniswap V4 address
contract UniswapV4DeployerCompetition is IUniswapV4DeployerCompetition {
    using VanityAddressLib for address;
    using CustomRevert for bytes4;

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

    /// @dev Rate limiting: track last submission time per address
    mapping(address => uint256) public lastSubmissionTime;
    /// @dev Minimum time between submissions per address (prevents spam)
    uint256 public constant SUBMISSION_COOLDOWN = 60; // 1 minute

    /// @notice Thrown when trying to submit too frequently
    error SubmissionTooFrequent(address sender, uint256 lastTime, uint256 currentTime);
    
    /// @notice Thrown when zero address salt bypass is attempted
    error InvalidZeroAddressSalt();

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
            CompetitionOver.selector.revertWith(block.timestamp, competitionDeadline);
        }

        // Enhanced rate limiting to prevent spam attacks
        uint256 lastTime = lastSubmissionTime[msg.sender];
        if (lastTime != 0 && block.timestamp - lastTime < SUBMISSION_COOLDOWN) {
            SubmissionTooFrequent.selector.revertWith(msg.sender, lastTime, block.timestamp);
        }
        lastSubmissionTime[msg.sender] = block.timestamp;

        // Enhanced salt validation - fix critical access control bypass
        address saltSubAddress = address(bytes20(salt));
        
        // CRITICAL FIX: Prevent zero address bypass vulnerability
        // The original logic allowed anyone to submit if saltSubAddress == address(0)
        // This was a critical access control bypass
        if (saltSubAddress == address(0)) {
            InvalidZeroAddressSalt.selector.revertWith();
        }
        
        // Now properly validate that the sender matches the salt sub-address
        if (saltSubAddress != msg.sender) {
            InvalidSender.selector.revertWith(salt, msg.sender);
        }

        address newAddress = Create2.computeAddress(salt, initCodeHash);
        address _bestAddress = bestAddress();
        if (!newAddress.betterThan(_bestAddress)) {
            WorseAddress.selector.revertWith(newAddress, _bestAddress, newAddress.score(), _bestAddress.score());
        }

        bestAddressSalt = salt;
        bestAddressSubmitter = msg.sender;

        emit NewAddressFound(newAddress, msg.sender, newAddress.score());
    }

    /// @inheritdoc IUniswapV4DeployerCompetition
    function deploy(bytes memory bytecode) external {
        if (keccak256(bytecode) != initCodeHash) {
            InvalidBytecode.selector.revertWith();
        }

        if (block.timestamp <= competitionDeadline) {
            CompetitionNotOver.selector.revertWith(block.timestamp, competitionDeadline);
        }

        if (msg.sender != deployer && block.timestamp <= exclusiveDeployDeadline) {
            // anyone can deploy after the deadline
            NotAllowedToDeploy.selector.revertWith(msg.sender, deployer);
        }

        // the owner of the contract must be encoded in the bytecode
        Create2.deploy(0, bestAddressSalt, bytecode);
    }

    /// @dev returns the best address found so far
    function bestAddress() public view returns (address) {
        return Create2.computeAddress(bestAddressSalt, initCodeHash);
    }
}
