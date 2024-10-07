// SPADIX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {ERC721} from "solmate/src/tokens/ERC721.sol";
import {TokenURILib} from "./libraries/UniswapV4DeployerTokenURILib.sol";
import {VanityAddressLib} from "./libraries/VanityAddressLib.sol";
import {IUniswapV4DeployerCompetition} from "./interfaces/IUniswapV4DeployerCompetition.sol";

contract UniswapV4DeployerCompetition is ERC721, IUniswapV4DeployerCompetition {
    using VanityAddressLib for address;

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
        bestAddressSender = msg.sender;

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
        if (msg.sender != bestAddressSender && block.timestamp < exclusiveDeployDeadline) {
            revert NotAllowedToDeploy(msg.sender, bestAddressSender); // anyone can deploy after the deadline
        }
        Create2.deploy(0, bestAddressSalt, bytecode);

        // mint to winner
        _mint(bestAddressSender, 0);
        // transfer the bounty to winner
        (bool success,) = bestAddressSender.call{value: address(this).balance}("");
        if (!success) {
            revert BountyTransferFailed();
        }
        // set owner of the pool manager contract
        Owned(bestAddress).transferOwnership(v4Owner);
    }

    /// @inheritdoc ERC721
    /// @notice Returns the URI for the token
    /// @param id The token id
    /// @return The URI for the token
    function tokenURI(uint256 id) public pure override returns (string memory) {
        if (id != 0) {
            revert InvalidTokenId(id);
        }
        return TokenURILib.tokenURI();
    }
}
