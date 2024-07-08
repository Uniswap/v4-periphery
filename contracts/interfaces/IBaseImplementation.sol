// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IBaseHook} from "./IBaseHook.sol";

interface IBaseImplementation is IBaseHook {
    function initializeMiddleware(address _middleware) external;
}
