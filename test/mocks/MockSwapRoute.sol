// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

interface IERC20Min {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Test stand-in for an off-venue Universal Router route (ERC20 only). Implements the
///         `IUniversalRouter.execute(bytes,bytes[])` shape SwapAndAdd calls. Consumes a FIXED `inputAmount`
///         of the surplus token (pulled via Permit2, exactly as a real route does) and returns the deficit at
///         an effective rate = mid * rateMultBps / 10000 (10000 = mid, <10000 worse, >10000 beats mid). It does
///         NOT touch the target pool, mimicking off-venue execution. Pre-fund it with inventory of both tokens.
contract MockSwapRoute {
    IAllowanceTransfer public immutable permit2;

    address public surplus;
    address public deficit;
    uint256 public midRateX96; // token1 per token0, Q96
    uint256 public rateMultBps; // effective rate vs mid
    uint256 public inputAmount; // fixed surplus consumed
    bool public surplusIsToken0;

    constructor(IAllowanceTransfer _permit2) {
        permit2 = _permit2;
    }

    function config(
        address _surplus,
        address _deficit,
        uint256 _midRateX96,
        uint256 _rateMultBps,
        uint256 _inputAmount,
        bool _surplusIsToken0
    ) external {
        surplus = _surplus;
        deficit = _deficit;
        midRateX96 = _midRateX96;
        rateMultBps = _rateMultBps;
        inputAmount = _inputAmount;
        surplusIsToken0 = _surplusIsToken0;
    }

    function execute(bytes calldata, bytes[] calldata) external payable {
        uint256 avail = IERC20Min(surplus).balanceOf(msg.sender);
        uint256 pull = inputAmount;
        if (pull > avail) pull = avail; // safety clamp only
        if (pull == 0) return;
        permit2.transferFrom(msg.sender, address(this), uint160(pull), surplus);

        uint256 out = surplusIsToken0
            ? FullMath.mulDiv(pull, midRateX96, FixedPoint96.Q96) // token0 -> token1
            : FullMath.mulDiv(pull, FixedPoint96.Q96, midRateX96); // token1 -> token0
        out = (out * rateMultBps) / 10000;
        IERC20Min(deficit).transfer(msg.sender, out);
    }
}
