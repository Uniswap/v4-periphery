// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

interface IERC20Min {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Test stand-in for a Universal Router route. Pulls a fixed `inputAmount` of the surplus token
///         via Permit2 and returns the deficit token at mid * rateMultBps / 10000. Pre-fund it with both tokens.
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

    function execute(bytes calldata commands, bytes[] calldata inputs) external payable {
        // Universal Router SWEEP (0x04) returns leftover native to the caller.
        if (commands.length == 1 && uint8(commands[0]) == 0x04) {
            (address token,,) = abi.decode(inputs[0], (address, address, uint256));
            require(token == address(0), "mock: only native sweep");
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "mock: sweep failed");
            return;
        }
        // A native surplus consumes from msg.value. The rest stays here for the SWEEP reclaim.
        if (surplus == address(0)) {
            uint256 nativePull = inputAmount > msg.value ? msg.value : inputAmount;
            if (nativePull == 0) return;
            (bool ok,) = address(0xdEaD).call{value: nativePull}("");
            require(ok, "mock: sink failed");
            uint256 nativeOut = surplusIsToken0
                ? FullMath.mulDiv(nativePull, midRateX96, FixedPoint96.Q96)
                : FullMath.mulDiv(nativePull, FixedPoint96.Q96, midRateX96);
            nativeOut = (nativeOut * rateMultBps) / 10000;
            IERC20Min(deficit).transfer(msg.sender, nativeOut);
            return;
        }

        uint256 avail = IERC20Min(surplus).balanceOf(msg.sender);
        uint256 pull = inputAmount;
        if (pull > avail) pull = avail; // safety clamp only
        if (pull == 0) return;
        permit2.transferFrom(msg.sender, address(this), uint160(pull), surplus);

        uint256 out = surplusIsToken0
            ? FullMath.mulDiv(pull, midRateX96, FixedPoint96.Q96)  // token0 -> token1
            : FullMath.mulDiv(pull, FixedPoint96.Q96, midRateX96); // token1 -> token0
        out = (out * rateMultBps) / 10000;
        IERC20Min(deficit).transfer(msg.sender, out);
    }
}
