// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SignatureVerification} from "permit2/src/libraries/SignatureVerification.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721Permit_v4} from "../../src/interfaces/IERC721Permit_v4.sol";
import {ERC721Permit_v4} from "../../src/base/ERC721Permit_v4.sol";
import {IUnorderedNonce} from "../../src/interfaces/IUnorderedNonce.sol";

import {PositionConfig} from "../shared/PositionConfig.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";

import {PosmTestSetup} from "../shared/PosmTestSetup.sol";

contract PermitTest is Test, PosmTestSetup {
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    PoolId poolId;
    address alice;
    uint256 alicePK;
    address bob;
    uint256 bobPK;

    PositionConfig config;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(manager);

        seedBalance(alice);
        seedBalance(bob);

        approvePosmFor(alice);
        approvePosmFor(bob);

        // define a reusable range
        config = PositionConfig({poolKey: key, tickLower: -300, tickUpper: 300});
    }

    function test_domainSeparator() public view {
        assertEq(
            ERC721Permit_v4(address(lpm)).DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                    keccak256("Uniswap v4 Positions NFT"), // storage is private on EIP712.sol so we need to hardcode these
                    block.chainid,
                    address(lpm)
                )
            )
        );
    }

    function test_permit_increaseLiquidity() public {
        uint256 liquidityAlice = 1e18;
        uint256 tokenIdAlice = lpm.nextTokenId();
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);

        // alice gives bob permissions
        permit(alicePK, tokenIdAlice, bob, 1);

        // bob can increase liquidity on alice's token
        uint256 liquidityToAdd = 0.4444e18;
        vm.startPrank(bob);
        increaseLiquidity(tokenIdAlice, config, liquidityToAdd, ZERO_BYTES);
        vm.stopPrank();

        // alice's position increased liquidity
        uint256 liquidity = lpm.getPositionLiquidity(tokenIdAlice);

        assertEq(liquidity, liquidityAlice + liquidityToAdd);
    }

    function test_permit_decreaseLiquidity() public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // alice gives bob operator permissions
        permit(alicePK, tokenIdAlice, bob, 1);

        // bob can decrease liquidity on alice's token
        uint256 liquidityToRemove = 0.4444e18;
        vm.startPrank(bob);
        decreaseLiquidity(tokenIdAlice, config, liquidityToRemove, ZERO_BYTES);
        vm.stopPrank();

        // alice's position decreased liquidity
        uint256 liquidity = lpm.getPositionLiquidity(tokenIdAlice);

        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }

    function test_permit_collect() public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // donate to create fee revenue
        uint256 currency0Revenue = 0.4444e18;
        uint256 currency1Revenue = 0.2222e18;
        donateRouter.donate(key, currency0Revenue, currency1Revenue, ZERO_BYTES);

        // alice gives bob operator permissions
        permit(alicePK, tokenIdAlice, bob, 1);

        // TODO: test collection to recipient with a permissioned operator

        // bob collects fees to himself
        address recipient = bob;
        uint256 balance0BobBefore = currency0.balanceOf(bob);
        uint256 balance1BobBefore = currency1.balanceOf(bob);
        vm.startPrank(bob);
        collect(tokenIdAlice, config, ZERO_BYTES);
        vm.stopPrank();

        assertApproxEqAbs(currency0.balanceOf(recipient), balance0BobBefore + currency0Revenue, 1 wei);
        assertApproxEqAbs(currency1.balanceOf(recipient), balance1BobBefore + currency1Revenue, 1 wei);
    }

    // --- Fail Scenarios --- //
    function test_permit_notOwnerRevert() public {
        // calling permit on a token that is not owned will fail

        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob cannot permit himself on alice's token
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.startPrank(bob);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, signature);
        vm.stopPrank();
    }

    /// @dev unapproved callers CANNOT increase others' positions
    function test_noPermit_increaseLiquidityRevert() public {
        // increase fails if the owner did not permit
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob cannot increase liquidity on alice's token
        uint256 liquidityToAdd = 0.4444e18;
        bytes memory decrease = getIncreaseEncoded(tokenIdAlice, config, liquidityToAdd, ZERO_BYTES);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(bob)));
        lpm.modifyLiquidities(decrease, _deadline);
        vm.stopPrank();
    }

    function test_noPermit_decreaseLiquidityRevert() public {
        // decreaseLiquidity fails if the owner did not permit
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // bob cannot decrease liquidity on alice's token
        uint256 liquidityToRemove = 0.4444e18;
        bytes memory decrease = getDecreaseEncoded(tokenIdAlice, config, liquidityToRemove, ZERO_BYTES);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(bob)));
        lpm.modifyLiquidities(decrease, _deadline);
        vm.stopPrank();
    }

    function test_noPermit_collectRevert() public {
        // collect fails if the owner did not permit
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // donate to create fee revenue
        uint256 currency0Revenue = 0.4444e18;
        uint256 currency1Revenue = 0.2222e18;
        donateRouter.donate(key, currency0Revenue, currency1Revenue, ZERO_BYTES);

        // bob cannot collect fees
        bytes memory collect = getCollectEncoded(tokenIdAlice, config, ZERO_BYTES);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(bob)));
        lpm.modifyLiquidities(collect, block.timestamp + 1);
        vm.stopPrank();
    }

    /// @notice revoking a nonce prevents it from being used in permit()
    function test_fuzz_noPermit_revokeRevert(uint256 nonce) public {
        uint256 liquidityAlice = 1e18;
        vm.prank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        uint256 tokenIdAlice = lpm.nextTokenId() - 1;

        // alice revokes the nonce
        vm.prank(alice);
        lpm.revokeNonce(nonce);

        // alice gives bob spender permissions
        bytes32 digest = getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IUnorderedNonce.NonceAlreadyUsed.selector);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, signature);
    }

    // Bob can use alice's signature to permit & decrease liquidity
    function test_permit_operatorSelfPermit() public {
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();
        uint256 tokenId = lpm.nextTokenId() - 1;

        // Alice gives Bob permission to operate on her liquidity
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenId, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // bob gives himself permission
        vm.prank(bob);
        lpm.permit(bob, tokenId, block.timestamp + 1, nonce, signature);

        // bob can decrease liquidity on alice's token
        uint256 liquidityToRemove = 0.4444e18;
        vm.startPrank(bob);
        decreaseLiquidity(tokenId, config, liquidityToRemove, ZERO_BYTES);
        vm.stopPrank();

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }

    // Charlie uses Alice's signature to give permission to Bob
    function test_permit_thirdParty() public {
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        mint(config, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();
        uint256 tokenId = lpm.nextTokenId() - 1;

        // Alice gives Bob permission to operate on her liquidity
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenId, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // charlie gives Bob permission to operate on alice's token
        address charlie = makeAddr("CHARLIE");
        vm.prank(charlie);
        lpm.permit(bob, tokenId, block.timestamp + 1, nonce, signature);

        // bob can decrease liquidity on alice's token
        uint256 liquidityToRemove = 0.4444e18;
        vm.startPrank(bob);
        decreaseLiquidity(tokenId, config, liquidityToRemove, ZERO_BYTES);
        vm.stopPrank();

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }
}
