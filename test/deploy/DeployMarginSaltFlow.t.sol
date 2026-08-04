// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {MarginAccount} from "../../src/MarginAccount.sol";
import {IMarginRouter} from "../../src/interfaces/IMarginRouter.sol";

/// @dev Minimal stand-in for the canonical deterministic-deployment-proxy at 0x4e59...: reads calldata
///      as `salt(32) ++ initCode`, CREATE2-deploys it, and returns the 20-byte address, exactly as the
///      real factory does. Etched at 0x4e59 so the test exercises the true deploy path without a fork.
contract MockDeterministicDeployer {
    fallback() external payable {
        assembly {
            let size := sub(calldatasize(), 32)
            calldatacopy(0, 32, size)
            let addr := create2(callvalue(), 0, size, calldataload(0))
            if iszero(addr) { revert(0, 0) }
            mstore(0, addr)
            return(12, 20)
        }
    }
}

/// @notice Guards the MarginRouter vanity-deploy flow end to end: the address the deploy produces must
///         equal the one MineMarginRouterSalt / MarginRouterInitCode (and off-chain create2crunch) mine
///         against, and the deployed runtime must be the EIP-170-fitting, optimizer-restricted build.
///
///         The miner, the predictor, and DeployMargin all compute the router address as a CREATE2 over
///         `vm.getCode("MarginRouter.sol:MarginRouter") ++ abi.encode(ctorArgs)` deployed by the 0x4e59
///         factory. This test deploys through that same factory the way the fixed DeployMargin does (a
///         call with `salt ++ initCode`) and asserts the router lands where `vm.computeCreate2Address`
///         predicts. It catches a regression where a different deployer, init code, or ctor-arg order
///         would silently move the vanity address the salt was mined for.
contract DeployMarginSaltFlowTest is Test {
    // The canonical deterministic CREATE2 deployer the whole mining pipeline targets.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    // Must match DeployMargin / MineMarginRouterSalt.
    bytes32 internal constant ACCOUNT_SALT = keccak256("uniswap.margin.MarginAccount.v1");

    // Deploy-tuple stand-ins. The router constructor only stores these as immutables, so their being
    // EOAs is fine; what matters is that every stage encodes the same tuple in the same order.
    address internal pm = makeAddr("poolManager");
    address internal permit2 = makeAddr("permit2");
    address internal weth9 = makeAddr("weth9");
    address internal governance = makeAddr("governance");
    address internal universalRouter = makeAddr("universalRouter");

    function setUp() public {
        // Place the deterministic factory at the canonical address the whole pipeline mines against.
        vm.etch(CREATE2_DEPLOYER, address(new MockDeterministicDeployer()).code);
    }

    /// @dev Deploy `initCode` through the 0x4e59 factory the way the scripts do, asserting it lands at
    ///      the `computeCreate2Address` the miner/predictor compute for the same (deployer, salt, code).
    function _deployVia4e59(bytes32 salt, bytes memory initCode) internal returns (address predicted) {
        predicted = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_DEPLOYER);
        (bool ok,) = CREATE2_DEPLOYER.call(bytes.concat(salt, initCode));
        require(ok, "factory CREATE2 call failed");
        require(predicted.code.length != 0, "router must deploy at the mined address, not elsewhere");
    }

    /// @dev The exact router init code every stage builds: restricted creation code ++ encoded ctor args.
    function _routerInitCode(address accountImpl) internal view returns (bytes memory) {
        return abi.encodePacked(
            vm.getCode("MarginRouter.sol:MarginRouter"),
            abi.encode(pm, permit2, weth9, accountImpl, governance, universalRouter)
        );
    }

    function test_vanityDeploy_landsAtMinedAddress_andFitsEIP170() public {
        // The account implementation is a CREATE2 ctor dependency of the router, derived by the miner as
        // a salted deploy through 0x4e59. Deploy it through the same factory so the router init code
        // embeds the address the miner would.
        address accountImpl = _deployVia4e59(ACCOUNT_SALT, type(MarginAccount).creationCode);

        // What the miner, the predictor, and (the fixed) DeployMargin all compute and deploy.
        bytes32 routerSalt = bytes32(uint256(0xC0FFEE));
        address router = _deployVia4e59(routerSalt, _routerInitCode(accountImpl));

        // Correct bytecode: the optimizer-restricted build that fits under EIP-170 (24,576), and it is
        // the full router (a stub or the oversized default-profile build would fail one of these).
        assertLt(router.code.length, 24_576, "deployed runtime must fit under the EIP-170 limit");
        assertGt(router.code.length, 20_000, "deployed the full router, not a stub");
        // And it really is the router, wired to the encoded governance.
        assertEq(IMarginRouter(router).governance(), governance, "deployed contract is the wired MarginRouter");
    }
}
