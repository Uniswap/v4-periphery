// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {MockCalldataDecoder} from "../mocks/MockCalldataDecoder.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";

/// @notice Tests that the four V4 swap parameter decoders only ever read bytes inside `params`.
/// @dev A struct pointer assigned in assembly skips solc's validation, and solc bounds such a
///      struct's dynamic members against `calldatasize()` rather than the enclosing slice -- so a
///      member could start inside `params` and run past `params.length`, over bytes a caller that
///      authenticates `params` at its declared length never covered. `abi.decode` works from a copy
///      of exactly `params.length` bytes, closing that transitively, down to each PathKey's own
///      `hookData`. These tests assert that property rather than the implementation, so they still
///      fail if the decoders are ever rewritten in assembly to reclaim bytecode size. Each submits
///      raw calldata directly: a normal Solidity call re-encodes it and drops the trailing bytes.
contract CalldataDecoderSwapEncodingTest is Test {
    MockCalldataDecoder decoder;

    address constant ATTACKER_HOOK = 0xBaD00000000000000000000000000000000000aD;
    bytes32 constant SMUGGLED_HOOK_DATA = bytes32("ATTACKER-CONTROLLED-HOOKDATA");
    uint256 constant SMUGGLED_MIN_HOP_PRICE = 0xDEADBEEF;

    function setUp() public {
        decoder = new MockCalldataDecoder();
    }

    /*//////////////////////////////////////////////////////////////
             THE STRUCT OFFSET POINTS OUTSIDE params
    //////////////////////////////////////////////////////////////*/

    function test_decodeSwapExactInSingleParams_revertsWhenStructOffsetPointsPastParams() public {
        bytes memory declared = abi.encode(_blankExactInSingle());
        // the struct offset is the only word that has to be tampered with: it is unvalidated, so it
        // can name any location in calldata, including the unauthenticated tail
        _setWord(declared, 0x00, declared.length);

        bytes memory tail = _exactInSingleBody();

        _expectDecodeReverts(MockCalldataDecoder.decodeSwapExactInSingleParams.selector, declared, tail);
    }

    function test_decodeSwapExactOutSingleParams_revertsWhenStructOffsetPointsPastParams() public {
        bytes memory declared = abi.encode(_blankExactOutSingle());
        _setWord(declared, 0x00, declared.length);

        _expectDecodeReverts(
            MockCalldataDecoder.decodeSwapExactOutSingleParams.selector, declared, _exactInSingleBody()
        );
    }

    function test_decodeSwapExactInParams_revertsWhenStructOffsetPointsPastParams() public {
        bytes memory declared = abi.encode(_emptyExactIn());
        _setWord(declared, 0x00, declared.length);

        _expectDecodeReverts(MockCalldataDecoder.decodeSwapExactInParams.selector, declared, _exactInBody());
    }

    function test_decodeSwapExactOutParams_revertsWhenStructOffsetPointsPastParams() public {
        bytes memory declared = abi.encode(_emptyExactOut());
        _setWord(declared, 0x00, declared.length);

        _expectDecodeReverts(MockCalldataDecoder.decodeSwapExactOutParams.selector, declared, _exactInBody());
    }

    /*//////////////////////////////////////////////////////////////
            A MEMBER OFFSET POINTS OUTSIDE params, WHILE
                THE STRUCT OFFSET STAYS CANONICAL
    //////////////////////////////////////////////////////////////*/

    function test_decodeSwapExactInParams_revertsWhenPathOffsetPointsPastParams() public {
        bytes memory declared = abi.encode(_emptyExactIn());
        // the struct offset stays canonical: bounding it alone does not close this
        assertEq(_readWord(declared, 0x00), 0x20);
        // `path` offset is relative to the start of the struct, which sits at 0x20
        _setWord(declared, 0x40, declared.length - 0x20);

        _expectDecodeReverts(MockCalldataDecoder.decodeSwapExactInParams.selector, declared, _pathRegion());
    }

    function test_decodeSwapExactOutParams_revertsWhenPathOffsetPointsPastParams() public {
        bytes memory declared = abi.encode(_emptyExactOut());
        assertEq(_readWord(declared, 0x00), 0x20);
        _setWord(declared, 0x40, declared.length - 0x20);

        _expectDecodeReverts(MockCalldataDecoder.decodeSwapExactOutParams.selector, declared, _pathRegion());
    }

    function test_decodeSwapExactInParams_revertsWhenMinHopPriceOffsetPointsPastParams() public {
        bytes memory declared = abi.encode(_emptyExactIn());
        assertEq(_readWord(declared, 0x00), 0x20);
        // `minHopPriceX36` offset, also relative to the start of the struct
        _setWord(declared, 0x60, declared.length - 0x20);

        bytes memory tail = abi.encodePacked(uint256(1), SMUGGLED_MIN_HOP_PRICE);

        _expectDecodeReverts(MockCalldataDecoder.decodeSwapExactInParams.selector, declared, tail);
    }

    function test_decodeSwapExactInSingleParams_revertsWhenHookDataOffsetPointsPastParams() public {
        bytes memory declared = abi.encode(_blankExactInSingle());
        assertEq(_readWord(declared, 0x00), 0x20);
        // `hookData` offset is the tenth head word of the struct, at 0x20 + 0x120
        _setWord(declared, 0x140, declared.length - 0x20);

        bytes memory tail = abi.encodePacked(uint256(32), SMUGGLED_HOOK_DATA);

        _expectDecodeReverts(MockCalldataDecoder.decodeSwapExactInSingleParams.selector, declared, tail);
    }

    /*//////////////////////////////////////////////////////////////
           ONE PathKey's hookData POINTS OUTSIDE params,
              WHILE THE PathKey ITSELF STAYS HONEST
    //////////////////////////////////////////////////////////////*/

    function test_decodeSwapExactInParams_revertsWhenPathKeyHookDataOffsetPointsPastParams() public {
        bytes memory declared = abi.encode(_oneHopExactIn());
        // everything that selects the pool is untouched and in bounds -- the array header, the
        // element offset, and every static field of the PathKey including `hooks`
        assertEq(_readWord(declared, 0x00), 0x20);
        assertEq(_readWord(declared, 0xc0), 1);
        assertEq(_readWord(declared, 0xe0), 0x20);
        assertEq(_readWord(declared, 0x160), uint256(uint160(ATTACKER_HOOK)));
        assertEq(_readWord(declared, 0x1a0), 0);

        // one word: the element's own hookData offset, relative to the element start at 0x100
        _setWord(declared, 0x180, declared.length - 0x100);

        bytes memory tail = abi.encodePacked(uint256(32), SMUGGLED_HOOK_DATA);

        _expectDecodeReverts(MockCalldataDecoder.decodeSwapExactInParams.selector, declared, tail);
    }

    function test_decodeSwapExactOutParams_revertsWhenPathKeyHookDataOffsetPointsPastParams() public {
        bytes memory declared = abi.encode(_oneHopExactOut());
        _setWord(declared, 0x180, declared.length - 0x100);

        bytes memory tail = abi.encodePacked(uint256(32), SMUGGLED_HOOK_DATA);

        _expectDecodeReverts(MockCalldataDecoder.decodeSwapExactOutParams.selector, declared, tail);
    }

    /*//////////////////////////////////////////////////////////////
                    NON-CANONICAL ENCODINGS IN BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Documents a deliberate relaxation: `abi.decode` bounds every offset by the length of
    ///         the data it is given, but does not require offsets to be the minimal ones
    ///         `abi.encode` emits. A redundant gap word inside `params` is therefore accepted.
    /// @dev Safe -- no byte outside `params` is reachable, which is the property the signature
    ///      binding depends on -- but weaker than rejecting every non-canonical encoding. A caller
    ///      needing the declared bytes to round-trip to exactly one struct does not get that here.
    function test_decodeSwapExactInParams_acceptsNonCanonicalOffsetWithinParams() public {
        bytes memory declared = abi.encode(_emptyExactIn());
        bytes memory shifted = new bytes(declared.length + 0x20);
        for (uint256 i = 0; i < 0xc0; i++) {
            shifted[i] = declared[i];
        }
        for (uint256 i = 0xc0; i < declared.length; i++) {
            shifted[i + 0x20] = declared[i];
        }
        _setWord(shifted, 0x40, 0xc0); // path offset, was 0xa0
        _setWord(shifted, 0x60, 0xe0); // minHopPriceX36 offset, was 0xc0

        (bool ok, bytes memory ret) = _rawCall(MockCalldataDecoder.decodeSwapExactInParams.selector, shifted, "");
        assertTrue(ok);

        // the decode stayed within `params`: both arrays are empty, as the declared encoding says
        IV4Router.ExactInputParams memory swapParams = abi.decode(ret, (IV4Router.ExactInputParams));
        assertEq(swapParams.path.length, 0);
        assertEq(swapParams.minHopPriceX36.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       CANONICAL ENCODINGS STILL WORK
    //////////////////////////////////////////////////////////////*/

    function test_decodeSwapExactInParams_acceptsCanonicalEncodingWithTrailingBytes() public {
        bytes memory declared = abi.encode(_oneHopExactIn());
        bytes memory tail = abi.encodePacked(SMUGGLED_HOOK_DATA);

        (bool ok, bytes memory ret) = _rawCall(MockCalldataDecoder.decodeSwapExactInParams.selector, declared, tail);
        assertTrue(ok);

        IV4Router.ExactInputParams memory swapParams = abi.decode(ret, (IV4Router.ExactInputParams));
        assertEq(swapParams.path.length, 1);
        assertEq(uint256(uint160(address(swapParams.path[0].hooks))), uint256(uint160(ATTACKER_HOOK)));
        assertEq(swapParams.path[0].hookData.length, 0);
        assertEq(swapParams.amountIn, 1 ether);
    }

    function test_decodeSwapExactInSingleParams_acceptsCanonicalEncodingWithTrailingBytes() public {
        IV4Router.ExactInputSingleParams memory expected = _blankExactInSingle();
        expected.amountIn = 1 ether;
        expected.hookData = hex"c0ffee";

        (bool ok, bytes memory ret) = _rawCall(
            MockCalldataDecoder.decodeSwapExactInSingleParams.selector,
            abi.encode(expected),
            abi.encodePacked(SMUGGLED_HOOK_DATA)
        );
        assertTrue(ok);

        IV4Router.ExactInputSingleParams memory swapParams = abi.decode(ret, (IV4Router.ExactInputSingleParams));
        assertEq(swapParams.amountIn, 1 ether);
        assertEq(swapParams.hookData, hex"c0ffee");
    }

    function testFuzz_decodeSwapExactInParams_acceptsAnyCanonicalEncoding(
        IV4Router.ExactInputParams calldata _swapParams
    ) public {
        (bool ok,) = _rawCall(MockCalldataDecoder.decodeSwapExactInParams.selector, abi.encode(_swapParams), "");
        assertTrue(ok);
    }

    function testFuzz_decodeSwapExactOutParams_acceptsAnyCanonicalEncoding(
        IV4Router.ExactOutputParams calldata _swapParams
    ) public {
        (bool ok,) = _rawCall(MockCalldataDecoder.decodeSwapExactOutParams.selector, abi.encode(_swapParams), "");
        assertTrue(ok);
    }

    function testFuzz_decodeSwapExactInSingleParams_acceptsAnyCanonicalEncoding(
        IV4Router.ExactInputSingleParams calldata _swapParams
    ) public {
        (bool ok,) = _rawCall(MockCalldataDecoder.decodeSwapExactInSingleParams.selector, abi.encode(_swapParams), "");
        assertTrue(ok);
    }

    function testFuzz_decodeSwapExactOutSingleParams_acceptsAnyCanonicalEncoding(
        IV4Router.ExactOutputSingleParams calldata _swapParams
    ) public {
        (bool ok,) = _rawCall(MockCalldataDecoder.decodeSwapExactOutSingleParams.selector, abi.encode(_swapParams), "");
        assertTrue(ok);
    }

    /*//////////////////////////////////////////////////////////////
                               FIXTURES
    //////////////////////////////////////////////////////////////*/

    function _blankExactInSingle() internal pure returns (IV4Router.ExactInputSingleParams memory) {
        return IV4Router.ExactInputSingleParams({
            poolKey: PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
            zeroForOne: false,
            amountIn: 0,
            amountOutMinimum: 0,
            minHopPriceX36: 0,
            hookData: ""
        });
    }

    function _blankExactOutSingle() internal pure returns (IV4Router.ExactOutputSingleParams memory) {
        return IV4Router.ExactOutputSingleParams({
            poolKey: PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
            zeroForOne: false,
            amountOut: 0,
            amountInMaximum: 0,
            minHopPriceX36: 0,
            hookData: ""
        });
    }

    function _emptyExactIn() internal pure returns (IV4Router.ExactInputParams memory) {
        return IV4Router.ExactInputParams({
            currencyIn: Currency.wrap(address(0)),
            path: new PathKey[](0),
            minHopPriceX36: new uint256[](0),
            amountIn: 0,
            amountOutMinimum: 0
        });
    }

    function _emptyExactOut() internal pure returns (IV4Router.ExactOutputParams memory) {
        return IV4Router.ExactOutputParams({
            currencyOut: Currency.wrap(address(0)),
            path: new PathKey[](0),
            minHopPriceX36: new uint256[](0),
            amountOut: 0,
            amountInMaximum: 0
        });
    }

    function _oneHopExactIn() internal pure returns (IV4Router.ExactInputParams memory params) {
        params = _emptyExactIn();
        params.path = _onePath();
        params.amountIn = 1 ether;
    }

    function _oneHopExactOut() internal pure returns (IV4Router.ExactOutputParams memory params) {
        params = _emptyExactOut();
        params.path = _onePath();
        params.amountOut = 1 ether;
    }

    function _onePath() internal pure returns (PathKey[] memory path) {
        path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(0xBEEF)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(ATTACKER_HOOK),
            hookData: ""
        });
    }

    /// @notice The struct body a redirected struct offset would land on: a real single-hop swap
    function _exactInSingleBody() internal pure returns (bytes memory) {
        bytes memory encoded = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: PoolKey(
                    Currency.wrap(address(0xA11CE)), Currency.wrap(address(0xB0B)), 3000, 60, IHooks(ATTACKER_HOOK)
                ),
                zeroForOne: true,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                minHopPriceX36: SMUGGLED_MIN_HOP_PRICE,
                hookData: abi.encodePacked(SMUGGLED_HOOK_DATA)
            })
        );
        // drop the leading struct offset word: the redirected offset points straight at the body
        return _slice(encoded, 0x20);
    }

    function _exactInBody() internal pure returns (bytes memory) {
        return _slice(abi.encode(_oneHopExactIn()), 0x20);
    }

    /// @notice A `PathKey[]` region -- length word, element offset, then one element
    function _pathRegion() internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint256(1), // path.length
            uint256(0x20), // offset of element 0, relative to the word after the length
            uint256(uint160(address(0xBEEF))), // intermediateCurrency
            uint256(3000), // fee
            uint256(60), // tickSpacing
            uint256(uint160(ATTACKER_HOOK)), // hooks
            uint256(0xa0), // hookData offset
            uint256(0) // hookData length
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Submits `declared ++ tail` as one `bytes` argument whose declared length covers only
    ///         `declared`, mirroring a caller that authenticated `params` at its declared length
    function _rawCall(bytes4 selector, bytes memory declared, bytes memory tail)
        internal
        returns (bool ok, bytes memory ret)
    {
        uint256 remainder = declared.length % 32;
        bytes memory padded = remainder == 0 ? declared : bytes.concat(declared, new bytes(32 - remainder));
        (ok, ret) = address(decoder)
            .call(bytes.concat(selector, bytes32(uint256(0x20)), bytes32(declared.length), padded, tail));
    }

    /// @notice Asserts the decoder rejected `declared ++ tail`
    /// @dev `abi.decode` signals a malformed encoding with a bare `revert(0, 0)` rather than a
    ///      custom error, so the assertion is on empty returndata. The guarantee under test is that
    ///      the decode fails at all -- no member may reach a byte past `declared.length`.
    function _expectDecodeReverts(bytes4 selector, bytes memory declared, bytes memory tail) internal {
        (bool ok, bytes memory ret) = _rawCall(selector, declared, tail);
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    function _setWord(bytes memory data, uint256 offset, uint256 value) internal pure {
        assembly ("memory-safe") {
            mstore(add(add(data, 0x20), offset), value)
        }
    }

    function _readWord(bytes memory data, uint256 offset) internal pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory out) {
        out = new bytes(data.length - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[start + i];
        }
    }

    function _truncate(bytes memory data, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = data[i];
        }
    }
}
