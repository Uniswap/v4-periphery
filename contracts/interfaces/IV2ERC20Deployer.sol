pragma solidity ^0.8.19;

interface IV2ERC20Deployer {
    /// @notice Get the parameters to be used in constructing the pool, set transiently during pool creation.
    /// @dev Called by the pool constructor to fetch the parameters of the pool
    function parameters() external view returns (string memory name, string memory symbol, uint8 decimals);
}
