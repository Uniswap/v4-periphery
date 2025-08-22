// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import "./V2OnV4Pair.sol";

contract V2OnV4PairDeployer {
    struct Parameters {
        address token0;
        address token1;
        address poolManager;
    }

    Parameters public parameters;

    function deploy(address token0, address token1, address poolManager) internal returns (address pair) {
        parameters = Parameters({token0: token0, token1: token1, poolManager: poolManager});
        pair = address(new V2OnV4Pair{salt: keccak256(abi.encode(token0, token1))}());
        delete parameters;
    }
}
