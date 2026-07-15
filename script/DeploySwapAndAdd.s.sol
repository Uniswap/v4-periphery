// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UniversalRouter} from "universal-router/contracts/UniversalRouter.sol";
import {RouterParameters} from "universal-router/contracts/types/RouterParameters.sol";

import {SwapAndAdd} from "../src/SwapAndAdd.sol";
import {IPositionManager} from "../src/interfaces/IPositionManager.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";

/// @notice Deploys the patched Universal Router (feat/v4-swap-within-existing-unlock, submodule @ cf27fb66e5)
///         and SwapAndAdd wired to it. The CANONICAL UR cannot be used: routed operations execute V4_SWAP
///         inside SwapAndAdd's already-open PoolManager unlock, which the canonical router rejects
///         (AlreadyUnlocked). Until that UR feature ships canonically, every SwapAndAdd deployment carries
///         its own router instance.
///
///         Run (simulate):  FOUNDRY_PROFILE=integration forge script script/DeploySwapAndAdd.s.sol \
///                            --rpc-url sepolia
///         Run (broadcast): add  --broadcast --private-key $DEPLOYER_KEY   (or --account <keystore>)
///
///         Sepolia parameters mirror the official universal-router DeploySepolia.s.sol; PoolManager, POSM and
///         Permit2 re-verified onchain (cast code) 2026-07-13.
contract DeploySwapAndAdd is Script {
    struct ChainParams {
        address poolManager;
        address posm;
        address permit2;
        address weth9;
        address v2Factory;
        address v3Factory;
        bytes32 pairInitCodeHash;
        bytes32 poolInitCodeHash;
        address v3Posm;
        address spokePool;
    }

    function run() external {
        ChainParams memory c = _params(block.chainid);

        vm.startBroadcast();
        UniversalRouter router = new UniversalRouter(
            RouterParameters({
                permit2: c.permit2,
                weth9: c.weth9,
                v2Factory: c.v2Factory,
                v3Factory: c.v3Factory,
                pairInitCodeHash: c.pairInitCodeHash,
                poolInitCodeHash: c.poolInitCodeHash,
                v4PoolManager: c.poolManager,
                permissionsAdapterFactory: address(0),
                v3NFTPositionManager: c.v3Posm,
                v4PositionManager: c.posm,
                spokePool: c.spokePool
            })
        );
        SwapAndAdd zap = new SwapAndAdd(
            IPoolManager(c.poolManager),
            IAllowanceTransfer(c.permit2),
            IPositionManager(c.posm),
            IUniversalRouter(address(router))
        );
        vm.stopBroadcast();

        console2.log("chainid            ", block.chainid);
        console2.log("UniversalRouter    ", address(router));
        console2.log("SwapAndAdd         ", address(zap));
    }

    function _params(uint256 chainid) internal pure returns (ChainParams memory) {
        // Sepolia — source: universal-router script/deployParameters/DeploySepolia.s.sol (submodule cf27fb66e5)
        if (chainid == 11155111) {
            return ChainParams({
                poolManager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543,
                posm: 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4,
                permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
                weth9: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
                v2Factory: 0xF62c03E08ada871A0bEb309762E260a7a6a880E6,
                v3Factory: 0x0227628f3F023bb0B980b67D528571c95c6DaC1c,
                pairInitCodeHash: 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f,
                poolInitCodeHash: 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54,
                v3Posm: 0x1238536071E1c677A632429e3655c799b22cDA52,
                spokePool: 0x5ef6C01E11889d86803e0B23e3cB3F9E9d97B662
            });
        }
        revert("DeploySwapAndAdd: unsupported chain");
    }
}
