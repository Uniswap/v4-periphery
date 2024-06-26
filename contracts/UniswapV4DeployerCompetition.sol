// SPADIX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Create2} from "openzeppelin-contracts/contracts/utils/Create2.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {TokenURILib} from "./libraries/UniswapV4DeployerTokenURILib.sol";
import {VanityAddressLib} from "./libraries/VanityAddressLib.sol";

contract UniswapV4DeployerCompetition is ERC721 {
    using VanityAddressLib for address;

    event NewAddressFound(address bestAddress, address minter, uint256 score);

    error InvalidBytecode();
    error CompetitionNotOver();
    error CompetitionOver();
    error NotAllowedToDeploy();
    error BountyTransferFailed();
    error WorseAddress();

    bytes32 public bestAddressSalt;
    address public bestAddress;
    address public bestAddressSender;

    address public immutable v4Owner;
    uint256 public immutable competitionDeadline = block.timestamp + 7 days;
    uint256 public immutable exclusiveDeployDeadline = competitionDeadline + 1 days;
    bytes32 public immutable initCodeHash;

    constructor(bytes32 _initCodeHash, address _v4Owner) payable ERC721("UniswapV4 Deployer", "V4D") {
        initCodeHash = _initCodeHash;
        v4Owner = _v4Owner;
    }

    function updateBestAddress(bytes32 salt) external {
        if (block.timestamp > competitionDeadline) {
            revert CompetitionOver();
        }
        address newAddress = Create2.computeAddress(salt, initCodeHash, address(this));
        if (bestAddress != address(0) && !newAddress.betterThan(bestAddress)) {
            revert WorseAddress();
        }

        bestAddress = newAddress;
        bestAddressSalt = salt;
        bestAddressSender = msg.sender;

        emit NewAddressFound(newAddress, msg.sender, newAddress.score());
    }

    function deploy(bytes memory bytecode) external {
        if (keccak256(bytecode) != initCodeHash) {
            revert InvalidBytecode();
        }
        if (block.timestamp < competitionDeadline) {
            revert CompetitionNotOver();
        }
        if (msg.sender != bestAddressSender && block.timestamp < exclusiveDeployDeadline) {
            revert NotAllowedToDeploy(); // anyone can deploy after the deadline
        }
        Create2.deploy(0, bestAddressSalt, bytecode);

        // mint to winner
        _mint(bestAddressSender, 0);
        // transfer the bounty to winner
        (bool success,) = bestAddressSender.call{value: address(this).balance}("");
        if (!success) {
            revert BountyTransferFailed();
        }
        // set owner
        Owned(bestAddress).transferOwnership(v4Owner);
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return TokenURILib.tokenURI();
    }
}
