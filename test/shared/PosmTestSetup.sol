// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {LiquidityOperations} from "./LiquidityOperations.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {HookSavesDelta} from "./HookSavesDelta.sol";
import {HookModifyLiquidities} from "./HookModifyLiquidities.sol";
import {Deploy, IPositionDescriptor} from "./Deploy.sol";
import {ERC721PermitHash} from "../../src/libraries/ERC721PermitHash.sol";
import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionConfig} from "../shared/PositionConfig.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice A shared test contract that wraps the v4-core deployers contract and exposes basic liquidity operations on posm.
contract PosmTestSetup is Test, Deployers, DeployPermit2, LiquidityOperations {
    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    IAllowanceTransfer permit2;
    IPositionDescriptor public positionDescriptor;
    TransparentUpgradeableProxy proxy;
    IPositionDescriptor proxyAsImplementation;
    HookSavesDelta hook;
    address hookAddr = address(uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG));

    WETH wethImpl = new WETH();
    IWETH9 public _WETH9;

    address governance = address(0xABCD);

    HookModifyLiquidities hookModifyLiquidities;
    address hookModifyLiquiditiesAddr = address(
        uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        )
    );

    PoolKey wethKey;

    function deployPosmHookSavesDelta() public {
        HookSavesDelta impl = new HookSavesDelta();
        vm.etch(hookAddr, address(impl).code);
        hook = HookSavesDelta(hookAddr);
    }

    /// @dev deploys a special test hook where beforeSwap hookData is used to modify liquidity
    function deployPosmHookModifyLiquidities() public {
        HookModifyLiquidities impl = new HookModifyLiquidities();
        vm.etch(hookModifyLiquiditiesAddr, address(impl).code);
        hookModifyLiquidities = HookModifyLiquidities(hookModifyLiquiditiesAddr);

        // set posm address since constructor args are not easily copied by vm.etch
        hookModifyLiquidities.setAddresses(lpm, permit2);
    }

    function deployAndApprovePosm(IPoolManager poolManager) public {
        deployPosm(poolManager);
        approvePosm();
    }

    function deployPosm(IPoolManager poolManager) internal {
        // We use deployPermit2() to prevent having to use via-ir in this repository.
        permit2 = IAllowanceTransfer(deployPermit2());
        _WETH9 = deployWETH();
        proxyAsImplementation = deployDescriptor(poolManager, "ETH");
        lpm = Deploy.positionManager(
            address(poolManager), address(permit2), 100_000, address(proxyAsImplementation), address(_WETH9), hex"03"
        );
    }

    function deployWETH() internal returns (IWETH9) {
        address wethAddr = makeAddr("WETH");
        vm.etch(wethAddr, address(wethImpl).code);
        return IWETH9(wethAddr);
    }

    function deployDescriptor(IPoolManager poolManager, bytes32 label) internal returns (IPositionDescriptor) {
        positionDescriptor = Deploy.positionDescriptor(address(poolManager), address(_WETH9), label, hex"00");
        proxy = Deploy.transparentUpgradeableProxy(address(positionDescriptor), governance, "", hex"03");
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
        // 2. Then, the caller must approve POSM as a spender of permit2. TODO: This could also be a signature.
        permit2.approve(Currency.unwrap(currency), address(lpm), type(uint160).max, type(uint48).max);
    }

    // Does the same approvals as approvePosm, but for a specific address.
    function approvePosmFor(address addr) internal {
        vm.startPrank(addr);
        approvePosm();
        vm.stopPrank();
    }

    function seedWeth(address to) internal {
        vm.deal(address(this), STARTING_USER_BALANCE);
        _WETH9.deposit{value: STARTING_USER_BALANCE}();
        _WETH9.transfer(to, STARTING_USER_BALANCE);
    }

    function seedToken(MockERC20 token, address to) internal {
        token.mint(to, STARTING_USER_BALANCE);
    }

    function initPoolUnsorted(Currency currencyA, Currency currencyB, IHooks hooks, uint24 fee, uint160 sqrtPriceX96)
        internal
        returns (PoolKey memory poolKey)
    {
        (Currency _currency0, Currency _currency1) =
            SortTokens.sort(MockERC20(Currency.unwrap(currencyA)), MockERC20(Currency.unwrap(currencyB)));

        (poolKey,) = initPool(_currency0, _currency1, hooks, fee, sqrtPriceX96);
    }

    function permit(uint256 privateKey, uint256 tokenId, address operator, uint256 nonce) internal {
        bytes32 digest = getDigest(operator, tokenId, 1, block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(operator);
        lpm.permit(operator, tokenId, block.timestamp + 1, nonce, signature);
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

    function getLastDelta() internal view returns (BalanceDelta delta) {
        delta = hook.deltas(hook.numberDeltasReturned() - 1); // just want the most recently written delta
    }

    function getNetDelta() internal view returns (BalanceDelta delta) {
        uint256 numDeltas = hook.numberDeltasReturned();
        for (uint256 i = 0; i < numDeltas; i++) {
            delta = delta + hook.deltas(i);
        }
    }
}
