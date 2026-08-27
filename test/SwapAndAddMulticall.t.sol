// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {ISwapAndAdd} from "../src/interfaces/ISwapAndAdd.sol";
import {IMulticall_v4} from "../src/interfaces/IMulticall_v4.sol";
import {IPermit2Forwarder} from "../src/interfaces/IPermit2Forwarder.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";
import {PositionConfig} from "./shared/PositionConfig.sol";
import {PosmTestSetup} from "./shared/PosmTestSetup.sol";

/// @notice Multicall on the zap. Covers the `[permitBatch, op]` flow, which sets Permit2 allowances
///         from a signature and runs the op in one transaction, and msg.value discipline under batching.
contract SwapAndAddMulticallTest is PosmTestSetup {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    bytes32 constant PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 constant PERMIT_BATCH_TYPEHASH = keccak256(
        "PermitBatch(PermitDetails[] details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    ISwapAndAdd zap;
    // `key` and `nativeKey` are inherited Deployers state, assigned in setUp

    address signer;
    uint256 signerPk;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        (key,) = initPool(currency0, currency1, IHooks(address(0)), 3000, int24(60), SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: int256(1e24), salt: 0}),
            ""
        );
        (nativeKey,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1, 1 ether
        );

        zap = ISwapAndAdd(
            deployCode("SwapAndAdd.sol:SwapAndAdd", abi.encode(manager, permit2, lpm, IUniversalRouter(makeAddr("ur"))))
        );

        // the signer has the token->Permit2 approvals but no Permit2 allowance for the zap
        (signer, signerPk) = makeAddrAndKey("signer");
        vm.deal(signer, 10 ether);
        MockERC20(Currency.unwrap(currency0)).mint(signer, 1e30);
        MockERC20(Currency.unwrap(currency1)).mint(signer, 1e30);
        vm.startPrank(signer);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        vm.stopPrank();

        // the test contract keeps full allowances for POSM-side setup
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
    }

    // helpers

    function _addParams(PoolKey memory k, uint256 a0, uint256 a1) internal view returns (ISwapAndAdd.AddParams memory) {
        return ISwapAndAdd.AddParams({
            poolKey: k,
            tickLower: -600,
            tickUpper: 600,
            amount0In: a0,
            amount1In: a1,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 1,
            recipient: signer,
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    /// @dev PermitBatch naming the zap as spender over the given tokens. Nonces are read live from Permit2.
    function _batch(address[] memory tokens) internal view returns (IAllowanceTransfer.PermitBatch memory b) {
        IAllowanceTransfer.PermitDetails[] memory details = new IAllowanceTransfer.PermitDetails[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            (,, uint48 nonce) = permit2.allowance(signer, tokens[i], address(zap));
            details[i] = IAllowanceTransfer.PermitDetails({
                token: tokens[i], amount: type(uint160).max, expiration: type(uint48).max, nonce: nonce
            });
        }
        b = IAllowanceTransfer.PermitBatch({
            details: details, spender: address(zap), sigDeadline: block.timestamp + 100
        });
    }

    function _bothTokens() internal view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = Currency.unwrap(currency0);
        tokens[1] = Currency.unwrap(currency1);
    }

    function _oneToken(Currency c) internal pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = Currency.unwrap(c);
    }

    function _sign(IAllowanceTransfer.PermitBatch memory b, uint256 pk) internal view returns (bytes memory) {
        bytes32[] memory detailHashes = new bytes32[](b.details.length);
        for (uint256 i = 0; i < b.details.length; i++) {
            detailHashes[i] = keccak256(abi.encode(PERMIT_DETAILS_TYPEHASH, b.details[i]));
        }
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_BATCH_TYPEHASH, keccak256(abi.encodePacked(detailHashes)), b.spender, b.sigDeadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit2.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return bytes.concat(r, s, bytes1(v));
    }

    /// @dev Builds the `[permitBatch(tokens), <opCall>]` batch.
    function _permitThen(address[] memory tokens, bytes memory opCall) internal view returns (bytes[] memory calls) {
        IAllowanceTransfer.PermitBatch memory b = _batch(tokens);
        calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPermit2Forwarder.permitBatch, (signer, b, _sign(b, signerPk)));
        calls[1] = opCall;
    }

    /// @dev Mints a plain POSM position owned by the signer.
    function _mintToSigner(PoolKey memory k, uint256 liquidity) internal returns (uint256 tokenId) {
        tokenId = lpm.nextTokenId();
        mint(PositionConfig({poolKey: k, tickLower: -600, tickUpper: 600}), liquidity, signer, "");
    }

    // happy paths

    function test_multicall_permitThenAdd_withoutPriorAllowance() public {
        ISwapAndAdd.AddParams memory p = _addParams(key, 1e18, 2e18);
        bytes[] memory calls = _permitThen(_bothTokens(), abi.encodeCall(ISwapAndAdd.add, (p)));
        uint256 expectedId = lpm.nextTokenId();

        vm.prank(signer);
        bytes[] memory results = zap.multicall(calls);

        (uint256 tokenId, uint128 liquidity,,) = abi.decode(results[1], (uint256, uint128, uint256, uint256));
        assertEq(tokenId, expectedId, "returns the minted tokenId");
        assertGt(liquidity, 0, "position has liquidity");
        assertEq(IERC721(address(lpm)).ownerOf(tokenId), signer, "NFT to the signer");
        assertEq(currency0.balanceOf(address(zap)), 0, "no token0 at rest");
        assertEq(currency1.balanceOf(address(zap)), 0, "no token1 at rest");
    }

    function test_multicall_permitThenIncrease_withoutPriorAllowance() public {
        uint256 tokenId = _mintToSigner(key, 1e21);
        uint128 before = lpm.getPositionLiquidity(tokenId);

        ISwapAndAdd.IncreaseParams memory p = ISwapAndAdd.IncreaseParams({
            tokenId: tokenId,
            amount0In: 1e18,
            amount1In: 1e18,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidityAdded: 1,
            recipient: signer,
            hookData: "",
            deadline: block.timestamp + 1
        });
        bytes[] memory calls = _permitThen(_bothTokens(), abi.encodeCall(ISwapAndAdd.increase, (p)));

        vm.prank(signer);
        bytes[] memory results = zap.multicall(calls);

        (uint128 added,,) = abi.decode(results[1], (uint128, uint256, uint256));
        assertGt(added, 0, "liquidity added");
        assertEq(lpm.getPositionLiquidity(tokenId), before + added, "position grew in place");
    }

    function test_multicall_permitThenRebalance_withoutPriorAllowance() public {
        uint256 tokenId = _mintToSigner(key, 1e21);

        ISwapAndAdd.RebalanceParams memory p = ISwapAndAdd.RebalanceParams({
            tokenId: tokenId,
            additional0: int128(1e18), // pulled via the batched permit
            additional1: 0,
            newTickLower: -1200,
            newTickUpper: 1200,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidity: 1,
            recipient: signer,
            hookData: "",
            deadline: block.timestamp + 1
        });
        bytes[] memory calls = _permitThen(_oneToken(currency0), abi.encodeCall(ISwapAndAdd.rebalance, (p)));
        uint256 expectedId = lpm.nextTokenId();

        vm.prank(signer);
        bytes[] memory results = zap.multicall(calls);

        (uint256 newTokenId, uint128 liquidity,,) = abi.decode(results[1], (uint256, uint128, uint256, uint256));
        assertEq(newTokenId, expectedId, "new position minted");
        assertGt(liquidity, 0, "new position has liquidity");
        assertEq(IERC721(address(lpm)).ownerOf(newTokenId), signer, "new NFT to the signer");
    }

    function test_multicall_permitThenAddNative_valueBatch() public {
        ISwapAndAdd.AddParams memory p = _addParams(nativeKey, 1e17, 1e17);
        // currency0 is native and arrives as msg.value, so only currency1 needs an allowance
        bytes[] memory calls = _permitThen(_oneToken(currency1), abi.encodeCall(ISwapAndAdd.add, (p)));
        uint256 expectedId = lpm.nextTokenId();

        vm.prank(signer);
        bytes[] memory results = zap.multicall{value: 1e17}(calls);

        (uint256 tokenId, uint128 liquidity,,) = abi.decode(results[1], (uint256, uint128, uint256, uint256));
        assertEq(tokenId, expectedId, "native-pool position minted");
        assertGt(liquidity, 0, "position has liquidity");
        assertEq(address(zap).balance, 0, "no native at rest");
    }

    /// @dev A zero-value batch of ERC20 ops over multiple positions composes freely.
    function test_multicall_zeroValueBatch_composesOps() public {
        uint256 id1 = _mintToSigner(key, 1e21);
        uint256 id2 = _mintToSigner(key, 1e21);
        // accrue fees on id2 so compound has something to reinvest
        vm.prank(signer);
        permit2.approve(Currency.unwrap(currency0), address(swapRouter), type(uint160).max, type(uint48).max);
        swap(key, true, -int256(1e20), "");
        swap(key, false, -int256(1e20), "");

        ISwapAndAdd.IncreaseParams memory inc = ISwapAndAdd.IncreaseParams({
            tokenId: id1,
            amount0In: 1e18,
            amount1In: 1e18,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidityAdded: 1,
            recipient: signer,
            hookData: "",
            deadline: block.timestamp + 1
        });
        ISwapAndAdd.CompoundParams memory comp = ISwapAndAdd.CompoundParams({
            tokenId: id2,
            route: "",
            minLiquidityAdded: 1,
            recipient: signer,
            hookData: "",
            deadline: block.timestamp + 1
        });

        IAllowanceTransfer.PermitBatch memory b = _batch(_bothTokens());
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(IPermit2Forwarder.permitBatch, (signer, b, _sign(b, signerPk)));
        calls[1] = abi.encodeCall(ISwapAndAdd.increase, (inc));
        calls[2] = abi.encodeCall(ISwapAndAdd.compound, (comp));

        uint128 liq1Before = lpm.getPositionLiquidity(id1);
        uint128 liq2Before = lpm.getPositionLiquidity(id2);

        vm.prank(signer);
        zap.multicall(calls);

        assertGt(lpm.getPositionLiquidity(id1), liq1Before, "increase ran");
        assertGt(lpm.getPositionLiquidity(id2), liq2Before, "compound ran");
        assertEq(currency0.balanceOf(address(zap)), 0, "no token0 at rest after the batch");
        assertEq(currency1.balanceOf(address(zap)), 0, "no token1 at rest after the batch");
    }

    // msg.value discipline

    /// @dev An ERC20-only op asserts msg.value == 0, so it cannot run in a value-bearing batch.
    function test_multicall_erc20OpInValueBatch_reverts() public {
        vm.startPrank(signer);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);

        ISwapAndAdd.AddParams memory p = _addParams(key, 1e18, 2e18); // ERC20 pool: expected msg.value == 0
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(ISwapAndAdd.add, (p));

        vm.expectRevert(ISwapAndAdd.InvalidEthValue.selector);
        zap.multicall{value: 1}(calls);
        vm.stopPrank();
    }

    // failure and adversarial paths

    /// @dev A front-run permit burns the nonce but still sets the allowance. The batched permit
    ///      swallows the inner revert and the op completes.
    function test_multicall_frontRunPermit_stillSucceeds() public {
        ISwapAndAdd.AddParams memory p = _addParams(key, 1e18, 2e18);
        IAllowanceTransfer.PermitBatch memory b = _batch(_bothTokens());
        bytes memory sig = _sign(b, signerPk);

        // relayer front-runs the permit submission
        IPermit2Forwarder(address(zap)).permitBatch(signer, b, sig);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPermit2Forwarder.permitBatch, (signer, b, sig));
        calls[1] = abi.encodeCall(ISwapAndAdd.add, (p));

        vm.prank(signer);
        bytes[] memory results = zap.multicall(calls);
        (, uint128 liquidity,,) = abi.decode(results[1], (uint256, uint128, uint256, uint256));
        assertGt(liquidity, 0, "op completes although the permit nonce was already burned");
    }

    /// @dev The forwarder swallows a garbage signature, so the op's own Permit2 pull reverts AllowanceExpired.
    function test_multicall_invalidSignature_revertsOnPull() public {
        ISwapAndAdd.AddParams memory p = _addParams(key, 1e18, 2e18);
        IAllowanceTransfer.PermitBatch memory b = _batch(_bothTokens());
        (, uint256 wrongPk) = makeAddrAndKey("not-the-signer");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPermit2Forwarder.permitBatch, (signer, b, _sign(b, wrongPk)));
        calls[1] = abi.encodeCall(ISwapAndAdd.add, (p));

        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, 0));
        zap.multicall(calls);
    }

    // equivalence

    /// @dev A batched `[permit, add]` must match a direct `add` exactly: same tokenId, liquidity, and amounts.
    function testFuzz_multicall_permitThenAdd_matchesDirectCall(uint256 a0, uint256 a1) public {
        a0 = bound(a0, 0, 1e22);
        a1 = bound(a1, 0, 1e22);
        vm.assume(a0 + a1 > 1e6); // stay clear of the documented wei-scale dust regime

        ISwapAndAdd.AddParams memory p = _addParams(key, a0, a1);
        bytes[] memory calls = _permitThen(_bothTokens(), abi.encodeCall(ISwapAndAdd.add, (p)));

        // direct path
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(signer);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        (uint256 dId, uint128 dLiq, uint256 dA0, uint256 dA1) = zap.add(p);
        vm.stopPrank();
        vm.revertToState(snapshot);

        // batched path with the same params
        vm.prank(signer);
        bytes[] memory results = zap.multicall(calls);
        (uint256 wId, uint128 wLiq, uint256 wA0, uint256 wA1) =
            abi.decode(results[1], (uint256, uint128, uint256, uint256));

        assertEq(wId, dId, "same tokenId");
        assertEq(wLiq, dLiq, "same liquidity");
        assertEq(wA0, dA0, "same amount0");
        assertEq(wA1, dA1, "same amount1");
    }

    // adversarial mixing and matching

    function _incParams(uint256 tokenId, uint256 a0, uint256 a1)
        internal
        view
        returns (ISwapAndAdd.IncreaseParams memory)
    {
        return ISwapAndAdd.IncreaseParams({
            tokenId: tokenId,
            amount0In: a0,
            amount1In: a1,
            route: "",
            routeFunding: new ISwapAndAdd.TokenAmount[](0),
            minLiquidityAdded: 1,
            recipient: signer,
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    function _compParams(uint256 tokenId) internal view returns (ISwapAndAdd.CompoundParams memory) {
        return ISwapAndAdd.CompoundParams({
            tokenId: tokenId,
            route: "",
            minLiquidityAdded: 1,
            recipient: signer,
            hookData: "",
            deadline: block.timestamp + 1
        });
    }

    /// @dev A batch of N calls must match the same N calls as separate transactions: same success or
    ///      revert, byte-identical returndata, and the same final state. Ops and budgets are fuzzed.
    function testFuzz_multicall_batchEquivalentToSequential(
        uint8[3] memory opSeeds,
        uint88[3] memory b0s,
        uint88[3] memory b1s
    ) public {
        // standing allowances isolate batching mechanics from the permit flow
        vm.startPrank(signer);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        vm.stopPrank();
        uint256 posId = _mintToSigner(key, 1e21);
        // accrue fees so a compound has something to deploy. A second compound in the same
        // sequence reverts NoFeesToCompound, which is deliberately in-domain.
        swap(key, true, -int256(1e20), "");
        swap(key, false, -int256(1e20), "");

        bytes[] memory calls = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            uint256 a0 = bound(uint256(b0s[i]), 0, 1e21);
            uint256 a1 = bound(uint256(b1s[i]), 0, 1e21);
            uint8 kind = opSeeds[i] % 3;
            if (kind == 0) calls[i] = abi.encodeCall(ISwapAndAdd.add, (_addParams(key, a0, a1)));
            else if (kind == 1) calls[i] = abi.encodeCall(ISwapAndAdd.increase, (_incParams(posId, a0, a1)));
            else calls[i] = abi.encodeCall(ISwapAndAdd.compound, (_compParams(posId)));
        }

        uint256 snapshot = vm.snapshotState();

        // path A: the same calldata as three separate transactions
        bool seqAllOk = true;
        bytes[] memory seqResults = new bytes[](3);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(signer);
            (bool ok, bytes memory ret) = address(zap).call(calls[i]);
            if (!ok) {
                seqAllOk = false;
                break;
            }
            seqResults[i] = ret;
        }
        uint256 sC0;
        uint256 sC1;
        uint128 sLiq;
        uint256 sNext;
        if (seqAllOk) {
            sC0 = currency0.balanceOf(signer);
            sC1 = currency1.balanceOf(signer);
            sLiq = lpm.getPositionLiquidity(posId);
            sNext = lpm.nextTokenId();
        }
        vm.revertToState(snapshot);

        // path B: the same calldata as one batch
        vm.prank(signer);
        try zap.multicall(calls) returns (bytes[] memory results) {
            assertTrue(seqAllOk, "batch succeeded although a sequential call failed");
            for (uint256 i = 0; i < 3; i++) {
                assertEq(keccak256(results[i]), keccak256(seqResults[i]), "subcall returndata differs");
            }
            assertEq(currency0.balanceOf(signer), sC0, "signer token0 differs");
            assertEq(currency1.balanceOf(signer), sC1, "signer token1 differs");
            assertEq(lpm.getPositionLiquidity(posId), sLiq, "position liquidity differs");
            assertEq(lpm.nextTokenId(), sNext, "minted tokenIds differ");
            assertEq(currency0.balanceOf(address(zap)), 0, "token0 at rest after batch");
            assertEq(currency1.balanceOf(address(zap)), 0, "token1 at rest after batch");
        } catch {
            assertFalse(seqAllOk, "batch reverted although every sequential call succeeded");
        }
    }

    /// @dev A failing later subcall rolls back everything an earlier one did.
    function test_multicall_laterFailureRollsBackEarlierOps() public {
        vm.startPrank(signer);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        vm.stopPrank();
        // a position the signer is not authorized for
        uint256 foreignId = lpm.nextTokenId();
        mint(PositionConfig({poolKey: key, tickLower: -600, tickUpper: 600}), 1e21, makeAddr("someoneElse"), "");

        uint256 c0Before = currency0.balanceOf(signer);
        uint256 nextBefore = lpm.nextTokenId();

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ISwapAndAdd.add, (_addParams(key, 1e18, 2e18)));
        calls[1] = abi.encodeCall(ISwapAndAdd.increase, (_incParams(foreignId, 1e18, 1e18)));

        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(ISwapAndAdd.NotAuthorizedForToken.selector, foreignId));
        zap.multicall(calls);

        assertEq(currency0.balanceOf(signer), c0Before, "add's pull was not rolled back");
        assertEq(lpm.nextTokenId(), nextBefore, "add's mint was not rolled back");
    }

    /// @dev A victim's permit mixed into a batch grants nothing: every pull draws from msg.sender,
    ///      so the funds of the victim stay untouched.
    function test_multicall_victimPermitInBatch_cannotTouchVictimFunds() public {
        IAllowanceTransfer.PermitBatch memory victimPermit = _batch(_bothTokens());
        bytes memory victimSig = _sign(victimPermit, signerPk); // signer plays the victim

        address attacker = makeAddr("attacker");
        MockERC20(Currency.unwrap(currency0)).mint(attacker, 1e24);
        MockERC20(Currency.unwrap(currency1)).mint(attacker, 1e24);
        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        uint256 victimC0 = currency0.balanceOf(signer);
        uint256 victimC1 = currency1.balanceOf(signer);

        ISwapAndAdd.AddParams memory p = _addParams(key, 1e18, 2e18);
        p.recipient = attacker;
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPermit2Forwarder.permitBatch, (signer, victimPermit, victimSig));
        calls[1] = abi.encodeCall(ISwapAndAdd.add, (p));

        // the attacker has no allowance of their own
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, 0));
        zap.multicall(calls);

        // with their own allowance the batch runs, funded from the attacker's own wallet
        vm.startPrank(attacker);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        uint256 attC0 = currency0.balanceOf(attacker);
        zap.multicall(calls);
        vm.stopPrank();

        assertEq(currency0.balanceOf(signer), victimC0, "victim token0 touched");
        assertEq(currency1.balanceOf(signer), victimC1, "victim token1 touched");
        assertLt(currency0.balanceOf(attacker), attC0, "the add was funded by the attacker");
    }

    /// @dev An operator gains nothing from batching over the owner's position: grow output resolves
    ///      to the owner, and the operator's own op is funded from the operator's wallet.
    function test_multicall_operatorBatch_cannotRedirectOwnerValue() public {
        uint256 ownerPos = _mintToSigner(key, 1e21);
        // accrue owner fees
        swap(key, true, -int256(1e20), "");
        swap(key, false, -int256(1e20), "");

        address operator = makeAddr("operator");
        MockERC20(Currency.unwrap(currency0)).mint(operator, 1e24);
        MockERC20(Currency.unwrap(currency1)).mint(operator, 1e24);
        vm.startPrank(operator);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        vm.stopPrank();
        vm.prank(signer);
        IERC721(address(lpm)).setApprovalForAll(operator, true);

        // the operator asks for itself as recipient
        ISwapAndAdd.CompoundParams memory comp = _compParams(ownerPos);
        comp.recipient = operator; // ignored: resolved to the owner for an operator caller
        ISwapAndAdd.AddParams memory ownAdd = _addParams(key, 1e18, 1e18);
        ownAdd.recipient = operator;

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ISwapAndAdd.compound, (comp));
        calls[1] = abi.encodeCall(ISwapAndAdd.add, (ownAdd));

        uint128 liqBefore = lpm.getPositionLiquidity(ownerPos);
        uint256 opC0 = currency0.balanceOf(operator);
        uint256 opC1 = currency1.balanceOf(operator);

        vm.prank(operator);
        zap.multicall(calls);

        assertGt(lpm.getPositionLiquidity(ownerPos), liqBefore, "owner's fees were compounded into OWNER's position");
        assertLe(currency0.balanceOf(operator), opC0, "operator gained token0 through the batch");
        assertLe(currency1.balanceOf(operator), opC1, "operator gained token1 through the batch");
        assertEq(currency0.balanceOf(address(zap)), 0, "token0 at rest");
        assertEq(currency1.balanceOf(address(zap)), 0, "token1 at rest");
    }

    /// @dev An operator batch of ERC-20 ops for two owners matches sequential execution exactly.
    function test_multicall_operatorBatch_twoOwners_attributionMatchesSequential() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 posA = lpm.nextTokenId();
        mint(PositionConfig({poolKey: key, tickLower: -600, tickUpper: 600}), 1e21, alice, "");
        uint256 posB = lpm.nextTokenId();
        mint(PositionConfig({poolKey: key, tickLower: -600, tickUpper: 600}), 1e21, bob, "");
        // accrue fees to both positions
        swap(key, true, -int256(1e20), "");
        swap(key, false, -int256(1e20), "");

        address operator = makeAddr("operator");
        _fundAndApproveOperator(operator);
        _approveZapAndOperator(alice, operator);
        _approveZapAndOperator(bob, operator);

        ISwapAndAdd.IncreaseParams memory inc = _incParams(posA, 1e18, 1e18);
        inc.recipient = operator; // ignored: resolved to alice for an operator caller
        ISwapAndAdd.CompoundParams memory comp = _compParams(posB);
        comp.recipient = operator; // ignored: resolved to bob

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ISwapAndAdd.increase, (inc));
        calls[1] = abi.encodeCall(ISwapAndAdd.compound, (comp));

        uint256 snapshot = vm.snapshotState();
        vm.prank(operator);
        zap.multicall(calls);
        uint256[6] memory batched = _ownerState(alice, bob, posA, posB);
        assertEq(currency0.balanceOf(address(zap)), 0, "token0 at rest after batch");
        assertEq(currency1.balanceOf(address(zap)), 0, "token1 at rest after batch");

        vm.revertToState(snapshot);
        vm.prank(operator);
        zap.increase(inc);
        vm.prank(operator);
        zap.compound(comp);
        uint256[6] memory sequential = _ownerState(alice, bob, posA, posB);

        for (uint256 i = 0; i < 6; i++) {
            assertEq(batched[i], sequential[i], "owner outcome differs batched vs sequential");
        }
    }

    /// @dev Snapshot of the token balances and position liquidities of both owners.
    function _ownerState(address alice, address bob, uint256 posA, uint256 posB)
        internal
        view
        returns (uint256[6] memory s)
    {
        s[0] = currency0.balanceOf(alice);
        s[1] = currency1.balanceOf(alice);
        s[2] = currency0.balanceOf(bob);
        s[3] = currency1.balanceOf(bob);
        s[4] = lpm.getPositionLiquidity(posA);
        s[5] = lpm.getPositionLiquidity(posB);
    }

    function _fundAndApproveOperator(address operator) internal {
        MockERC20(Currency.unwrap(currency0)).mint(operator, 1e24);
        MockERC20(Currency.unwrap(currency1)).mint(operator, 1e24);
        vm.startPrank(operator);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(zap), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(zap), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _approveZapAndOperator(address owner, address operator) internal {
        vm.startPrank(owner);
        IERC721(address(lpm)).setApprovalForAll(address(zap), true);
        IERC721(address(lpm)).setApprovalForAll(operator, true);
        vm.stopPrank();
    }

    /// @dev Nested multicall composes with the same semantics.
    function test_multicall_nestedBatch_behavesLikeFlat() public {
        ISwapAndAdd.AddParams memory p = _addParams(key, 1e18, 2e18);
        bytes[] memory inner = _permitThen(_bothTokens(), abi.encodeCall(ISwapAndAdd.add, (p)));
        bytes[] memory outer = new bytes[](1);
        outer[0] = abi.encodeCall(IMulticall_v4.multicall, (inner));

        uint256 expectedId = lpm.nextTokenId();
        vm.prank(signer);
        zap.multicall(outer);
        assertEq(IERC721(address(lpm)).ownerOf(expectedId), signer, "nested batch minted to the signer");
    }

    /// @dev compound is non-payable, so it cannot run in a value-bearing batch.
    function test_multicall_compoundInValueBatch_reverts() public {
        uint256 tokenId = _mintToSigner(key, 1e21);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(ISwapAndAdd.compound, (_compParams(tokenId)));

        vm.prank(signer);
        vm.expectRevert();
        zap.multicall{value: 1}(calls);
    }

    /// @dev Batch value that no op consumes strands in the contract as a donation. The sweep of the
    ///      next native op hands it to the recipient of that op.
    function test_multicall_permitsOnlyValueBatch_strandsAsDonation() public {
        IAllowanceTransfer.PermitBatch memory b = _batch(_oneToken(currency1));
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(IPermit2Forwarder.permitBatch, (signer, b, _sign(b, signerPk)));

        uint256 donation = 0.05 ether;
        vm.prank(signer);
        zap.multicall{value: donation}(calls);
        assertEq(address(zap).balance, donation, "unconsumed batch value rests in the contract");

        uint256 balBefore = signer.balance;
        ISwapAndAdd.AddParams memory p = _addParams(nativeKey, 1e17, 1e17);
        vm.prank(signer);
        zap.add{value: 1e17}(p);
        assertEq(address(zap).balance, 0, "no native at rest after the op");
        assertGe(signer.balance, balBefore - 1e17 + donation, "donation swept to the op's recipient");
    }
}
