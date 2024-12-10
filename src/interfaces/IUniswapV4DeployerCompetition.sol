// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IUniswapV4DeployerCompetition
/// @notice Interface for the UniswapV4DeployerCompetition contract
interface IUniswapV4DeployerCompetition {
    event NewAddressFound(address indexed bestAddress, address indexed submitter, uint256 score);

    error InvalidBytecode();
    error CompetitionNotOver(uint256 currentTime, uint256 deadline);
    error CompetitionOver(uint256 currentTime, uint256 deadline);
    error NotAllowedToDeploy(address sender, address deployer);
    error WorseAddress(address newAddress, address bestAddress, uint256 newScore, uint256 bestScore);
    error InvalidSender(bytes32 salt, address sender);

    /// @notice Updates the best address if the new address has a better vanity score
    /// @param salt The salt to use to compute the new address with CREATE2
    /// @dev The first 20 bytes of the salt must be either address(0) or msg.sender
    function updateBestAddress(bytes32 salt) external;

    /// @notice deploys the Uniswap v4 PoolManager contract
    /// @param bytecode The bytecode of the Uniswap v4 PoolManager contract
    /// @dev The bytecode must match the initCodeHash
    function deploy(bytes memory bytecode) external;
}
