// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {VanityAddressLib} from "../src/libraries/VanityAddressLib.sol";
import {MarginRouter} from "../src/MarginRouter.sol";
import {MarginAccount} from "../src/MarginAccount.sol";

/// @title MineMarginRouterSalt
/// @notice One-off helper that searches for a CREATE2 salt producing a vanity MarginRouter address.
///         Pure computation: nothing is broadcast. The score follows VanityAddressLib (the first
///         nonzero nibble must be 4; leading zeros and runs of 4s earn more).
/// @dev The in-script loop is best for modest vanity (finding a few leading 4s). Extreme vanity
///      (many leading zeros, the Uniswap 0x0000...4444 style) is far beyond what a Solidity loop
///      can reach in a reasonable run; for that, feed the printed init code hash and CREATE2 deployer
///      into an off-chain miner (e.g. `cast create2` or create2crunch) instead.
contract MineMarginRouterSalt is Script {
    using VanityAddressLib for address;

    /// @dev The canonical CREATE2 deployer that Foundry's `new X{salt: s}(args)` routes through. The
    ///      mined salt is only valid for deployments made through this same factory.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Salt for the deterministic MarginAccount implementation. Must match DeployMargin so the
    ///      implementation address baked into the router init code is the one the deploy produces.
    bytes32 internal constant ACCOUNT_SALT = keccak256("uniswap.margin.MarginAccount.v1");

    function setUp() public {}

    /// @notice Searches `iterations` salts starting at `startSalt` for the best-scoring router address.
    /// @param poolManager The v4 PoolManager the router will be constructed with.
    /// @param permit2 The Permit2 contract the router will be constructed with.
    /// @param weth9 The canonical WETH9 the router will be constructed with.
    /// @param governance The initial governance baked into the router constructor.
    /// @param startSalt The first salt to try; the loop scans `[startSalt, startSalt + iterations)`.
    /// @param iterations The number of salts to scan.
    /// @return bestSalt The best-scoring salt found.
    /// @return bestAddress The router address that salt produces.
    /// @return bestScore The VanityAddressLib score of that address.
    function run(
        address poolManager,
        address permit2,
        address weth9,
        address governance,
        bytes32 startSalt,
        uint256 iterations
    ) public view returns (bytes32 bestSalt, address bestAddress, uint256 bestScore) {
        // derive the deterministic MarginAccount implementation address the deploy will produce, so
        // the router init code hash here matches the one used when the router is actually deployed
        address accountImpl =
            vm.computeCreate2Address(ACCOUNT_SALT, keccak256(type(MarginAccount).creationCode), CREATE2_DEPLOYER);

        // init code hash of the router for the 5-arg constructor; this plus the deployer fully
        // determines every candidate address, so it is what an off-chain miner needs
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(MarginRouter).creationCode, abi.encode(poolManager, permit2, weth9, accountImpl, governance)
            )
        );

        for (uint256 i = 0; i < iterations; i++) {
            bytes32 salt = bytes32(uint256(startSalt) + i);
            address addr = vm.computeCreate2Address(salt, initCodeHash, CREATE2_DEPLOYER);
            uint256 candidateScore = addr.score();
            if (candidateScore > bestScore) {
                bestScore = candidateScore;
                bestSalt = salt;
                bestAddress = addr;
            }
        }

        console2.log("MarginRouter vanity salt search");
        console2.log("CREATE2_DEPLOYER", CREATE2_DEPLOYER);
        console2.log("accountImpl (deterministic)", accountImpl);
        console2.log("initCodeHash");
        console2.logBytes32(initCodeHash);
        console2.log("iterations scanned", iterations);
        console2.log("best salt");
        console2.logBytes32(bestSalt);
        console2.log("best address", bestAddress);
        console2.log("best score", bestScore);
        console2.log(
            "For higher scores, feed initCodeHash + CREATE2_DEPLOYER to an off-chain miner (cast create2 / create2crunch)."
        );
    }
}
