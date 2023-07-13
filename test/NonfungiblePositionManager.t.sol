// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TokenFixture} from "@uniswap/v4-core/test/foundry-tests/utils/TokenFixture.sol";

contract NonfungiblePositionManagerTest is Test, TokenFixture {
    function setUp() public {
        initializeTokens();
    }
}
