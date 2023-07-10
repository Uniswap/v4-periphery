// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import './IPeripheryImmutableState.sol';

interface INonfungiblePositionManager is IERC721, IPeripheryImmutableState {}
