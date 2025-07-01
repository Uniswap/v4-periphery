// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {LiquidityOperations} from "../../../shared/LiquidityOperations.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {HookSavesDelta} from "../../../shared/HookSavesDelta.sol";
import {HookModifyLiquidities} from "../../../shared/HookModifyLiquidities.sol";
import {Deploy, IPositionDescriptor} from "../../../shared/Deploy.sol";
import {ERC721PermitHash} from "../../../../src/libraries/ERC721PermitHash.sol";
import {IWETH9} from "../../../../src/interfaces/external/IWETH9.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionConfig} from "../../../shared/PositionConfig.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {CREATE3} from "solmate/src/utils/CREATE3.sol";
import {PermissionedDeployers} from "./PermissionedDeployers.sol";
import {IPositionManager} from "../../../../src/interfaces/IPositionManager.sol";

/// @notice A shared test contract that wraps the v4-core deployers contract and exposes basic liquidity operations on posm.
contract PermissionedPosmTestSetup is Test, PermissionedDeployers, DeployPermit2, LiquidityOperations {
    uint256 private constant STARTING_USER_BALANCE = 10_000_000 ether;
    address public constant GOVERNANCE = address(0xABCD);

    IAllowanceTransfer public permit2;
    IPositionDescriptor public positionDescriptor;
    TransparentUpgradeableProxy public proxy;
    IPositionDescriptor public proxyAsImplementation;
    HookModifyLiquidities public hookModifyLiquidities;
    WETH public wethImpl = new WETH();
    IWETH9 public _WETH9;

    PoolKey public wethKey;

    function deployAndApprovePosm(
        IPoolManager poolManager,
        address wrappedTokenFactory,
        address permissionedHooks_,
        bytes32 salt
    ) public {
        deployPermissionedPosm(poolManager, wrappedTokenFactory, permissionedHooks_, salt);
        approvePosm();
    }

    function deployAndApprovePosmOnly(
        IPoolManager poolManager,
        address wrappedTokenFactory,
        address permissionedHooks_,
        bytes32 salt
    ) public returns (IPositionManager secondaryPosm) {
        secondaryPosm = Deploy.permissionedPositionManagerCreate3(
            address(poolManager),
            address(permit2),
            100_000,
            address(proxyAsImplementation),
            address(_WETH9),
            wrappedTokenFactory,
            permissionedHooks_,
            salt
        );
        approvePosm();
    }

    function deployPermissionedPosm(
        IPoolManager poolManager,
        address wrappedTokenFactory,
        address permissionedHooks_,
        bytes32 salt
    ) internal {
        permit2 = IAllowanceTransfer(deployPermit2());
        _WETH9 = deployWETH();
        proxyAsImplementation = deployDescriptor(poolManager, "ETH");
        lpm = Deploy.permissionedPositionManagerCreate3(
            address(poolManager),
            address(permit2),
            100_000,
            address(proxyAsImplementation),
            address(_WETH9),
            wrappedTokenFactory,
            permissionedHooks_,
            salt
        );
    }

    function deployWETH() internal returns (IWETH9) {
        address wethAddr = makeAddr("WETH");
        vm.etch(wethAddr, address(wethImpl).code);
        return IWETH9(wethAddr);
    }

    function deployDescriptor(IPoolManager poolManager_, bytes32 label) internal returns (IPositionDescriptor) {
        positionDescriptor = Deploy.positionDescriptor(address(poolManager_), address(_WETH9), label, hex"00");
        proxy = Deploy.transparentUpgradeableProxy(address(positionDescriptor), GOVERNANCE, "", hex"03");
        return IPositionDescriptor(address(proxy));
    }

    function seedBalance(address to) internal {
        IERC20(Currency.unwrap(currency0)).transfer(to, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(to, STARTING_USER_BALANCE);
    }

    function approvePosm() internal {
        approvePosmCurrency(currency0);
        approvePosmCurrency(currency1);
    }

    function approvePosmCurrency(Currency currency) internal {
        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        // 2. Then, the caller must approve POSM as a spender of permit2.
        permit2.approve(Currency.unwrap(currency), address(lpm), type(uint160).max, type(uint48).max);
    }

    // Does the same approvals as approvePosm, but for a specific address.
    /// @dev Should not be in a prank when calling this function
    function approvePosmFor(address addr) internal {
        vm.startPrank(addr);
        approvePosm();
        vm.stopPrank();
    }

    function getDigest(address spender, uint256 tokenId, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32 digest)
    {
        digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                lpm.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(ERC721PermitHash.PERMIT_TYPEHASH, spender, tokenId, nonce, deadline))
            )
        );
    }
}
