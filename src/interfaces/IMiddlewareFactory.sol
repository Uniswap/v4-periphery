// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

interface IMiddlewareFactory {
    event MiddlewareCreated(address implementation, address middleware);

    /// @notice Returns the implementation address for a given middleware
    /// @param middleware The middleware address
    /// @return implementation The implementation address
    function getImplementation(address middleware) external view returns (address implementation);

    /// @notice Creates a middleware for the given implementation
    /// @param implementation The implementation address
    /// @param salt The salt to use to deploy the middleware
    /// @return middleware The address of the newly created middleware
    function createMiddleware(address implementation, bytes32 salt) external returns (address middleware);
}
