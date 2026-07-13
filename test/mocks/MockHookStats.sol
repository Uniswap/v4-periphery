// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookStats} from "../../src/interfaces/external/IHookStats.sol";

contract MockHookStats is IHookStats {
    enum Mode {
        VALID,
        REVERT_STATS,
        INVALID_EFFECTIVE,
        WRONG_HOOK,
        UNIVERSAL_ERC165,
        RETURN_BOMB,
        SHORT_RETURN,
        GAS_BURN,
        VALID_GAS_HEAVY
    }

    address private immutable REPORTED_HOOK;
    Mode private immutable MODE;

    constructor(address reportedHook, Mode mode) {
        REPORTED_HOOK = reportedHook;
        MODE = mode;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        if (MODE == Mode.UNIVERSAL_ERC165) return true;
        return interfaceId == type(IHookStats).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function hook() external view returns (address) {
        if (MODE == Mode.VALID_GAS_HEAVY) _burnMostForwardedGas();
        return MODE == Mode.WRONG_HOOK ? address(0xdead) : REPORTED_HOOK;
    }

    /// @notice Consumes nearly the entire forwarded stipend before answering, to exercise the caller's
    ///         worst-case gas accounting with responses that are still fully valid
    function _burnMostForwardedGas() private view {
        while (gasleft() > 30_000) {}
    }

    function getReserves(PoolKey calldata) external view returns (uint256 amount0, uint256 amount1) {
        if (MODE == Mode.VALID_GAS_HEAVY) _burnMostForwardedGas();
        if (MODE == Mode.REVERT_STATS) revert("STATS_REVERTED");
        if (MODE == Mode.RETURN_BOMB) {
            assembly ("memory-safe") {
                return(0, 0x1000)
            }
        }
        if (MODE == Mode.SHORT_RETURN) {
            assembly ("memory-safe") {
                mstore(0, 123)
                return(0, 0x20)
            }
        }
        if (MODE == Mode.GAS_BURN) {
            assembly ("memory-safe") {
                for {} 1 {} {}
            }
        }
        return (1000, 2000);
    }

    function getEffectiveLiquidity(PoolKey calldata) external view returns (uint256 amount0, uint256 amount1) {
        if (MODE == Mode.VALID_GAS_HEAVY) _burnMostForwardedGas();
        if (MODE == Mode.REVERT_STATS) revert("STATS_REVERTED");
        return MODE == Mode.INVALID_EFFECTIVE ? (1001, 2001) : (500, 1000);
    }
}
