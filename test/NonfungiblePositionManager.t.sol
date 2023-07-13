// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TokenFixture} from "@uniswap/v4-core/test/foundry-tests/utils/TokenFixture.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {NonfungiblePositionManager} from "../contracts/NonfungiblePositionManager.sol";

contract NonfungiblePositionManagerTest is Test, TokenFixture {
    PoolManager manager;
    NonfungiblePositionManager nonfungiblePositionManager;

    function setUp() public {
        initializeTokens();
        manager = new PoolManager(500000);
        nonfungiblePositionManager = new NonfungiblePositionManager(manager, address(1));
    }
}
