// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PositionDescriptor} from "../src/PositionDescriptor.sol";
import {CurrencyRatioSortOrder} from "../src/libraries/CurrencyRatioSortOrder.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionConfig} from "./shared/PositionConfig.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";
import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import {Base64} from "./base64.sol";

contract DescriptorTest is Test, Deployers {
    
}