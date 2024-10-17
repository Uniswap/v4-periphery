// SPADIX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {VanityAddressLib} from "./libraries/VanityAddressLib.sol";
import {IUniswapV4DeployerCompetition} from "./interfaces/IUniswapV4DeployerCompetition.sol";

contract UniswapV4DeployerCompetition is IUniswapV4DeployerCompetition {
    using VanityAddressLib for address;

    bytes32 public bestAddressSalt;
    address public bestAddress;
    address public bestAddressSubmitter;

    address public immutable deployer;
    address public immutable v4Owner;
    uint256 public immutable competitionDeadline;
    uint256 public immutable exclusiveDeployDeadline;
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

        Create2.deploy(0, bestAddressSalt, bytecode);

        // set owner of the pool manager contract
        Owned(bestAddress).transferOwnership(v4Owner);
    }
}
