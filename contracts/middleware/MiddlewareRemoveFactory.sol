// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IMiddlewareFactory} from "../interfaces/IMiddlewareFactory.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MiddlewareRemove} from "./MiddlewareRemove.sol";
import {MiddlewareRemoveNoDeltas} from "./MiddlewareRemoveNoDeltas.sol";

contract MiddlewareRemoveFactory {
    event MiddlewareCreated(address implementation, address middleware, uint256 maxFeeBips);

    mapping(address => address) private _implementations;

    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    /**
     * @notice Get the implementation address for a given middleware.
     * @param middleware The address of the middleware.
     * @return implementation The address of the implementation.
     */
    function getImplementation(address middleware) external view returns (address implementation) {
        return _implementations[middleware];
    }

    /**
     * @notice Create a new middlewareRemove contract.
     * @param implementation The address of the implementation or an existing hook.
     * @param maxFeeBips The maximum fee in basis points the hook is allowed to charge on removeLiquidity.
     * @param salt The salt for deploying to the right flags.
     * @return middleware The address of the newly created middlewareRemove contract.
     */
    function createMiddleware(address implementation, uint256 maxFeeBips, bytes32 salt)
        external
        returns (address middleware)
    {
        if (maxFeeBips == 0) {
            middleware = address(new MiddlewareRemoveNoDeltas{salt: salt}(manager, implementation));
        } else {
            middleware = address(new MiddlewareRemove{salt: salt}(manager, implementation, maxFeeBips));
        }
        _implementations[middleware] = implementation;
        emit MiddlewareCreated(implementation, middleware, maxFeeBips);
    }
}
