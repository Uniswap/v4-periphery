#!/usr/bin/env bash
# Fetch a real Trading API route and print it as SwapAndAdd `route` bytes: abi.encode(commands, inputs).
#
# Usage:  TAPI_API_KEY=... ./script/fetch-tapi-route.sh <tokenIn> <tokenOut> <amountIn> [chainId]
#   - tokenIn/tokenOut: addresses (use 0x0000000000000000000000000000000000000000 for native ETH)
#   - amountIn: raw units
#   - chainId: default 11155111 (Sepolia)
#
# IMPORTANT: request the quote with swapper = the SwapAndAdd deployment — the UR executes with the zap as
# msg.sender, so pulls/recipients must map to it. No permit data: the zap holds standing Permit2 allowances.
set -euo pipefail

TOKEN_IN=${1:?tokenIn}
TOKEN_OUT=${2:?tokenOut}
AMOUNT=${3:?amountIn raw units}
CHAIN_ID=${4:-11155111}
SWAPPER=${SWAPPER:-0xc6b69cbB1f9EB78D15C3876105B9EDA458CB404F} # live Sepolia SwapAndAdd
API=${TAPI_URL:-https://trading-api-labs.interface.gateway.uniswap.org/v1}
KEY=${TAPI_API_KEY:?set TAPI_API_KEY (see .env)}
# Router ABI generation to encode for (public x-universal-router-version header). Must match the ABI of the
# router that will execute the route; the API default targets an older generation than this repo's deployment.
UR_VERSION=${UR_VERSION:-2.2.0}

quote=$(curl -sf "$API/quote" -H "x-api-key: $KEY" -H "x-universal-router-version: $UR_VERSION" -H "content-type: application/json" -d @- <<JSON
{
  "type": "EXACT_INPUT",
  "tokenIn": "$TOKEN_IN",
  "tokenOut": "$TOKEN_OUT",
  "amount": "$AMOUNT",
  "tokenInChainId": $CHAIN_ID,
  "tokenOutChainId": $CHAIN_ID,
  "swapper": "$SWAPPER",
  "routingPreference": "BEST_PRICE"
}
JSON
)

swap=$(curl -sf "$API/swap" -H "x-api-key: $KEY" -H "x-universal-router-version: $UR_VERSION" -H "content-type: application/json" \
  -d "{\"quote\": $(echo "$quote" | jq .quote), \"simulateTransaction\": false}")

data=$(echo "$swap" | jq -r .swap.data)
echo "── UR calldata (execute) ──"
echo "$data"
echo
echo "── decoded (commands, inputs, deadline) ──"
cast decode-calldata "execute(bytes,bytes[],uint256)" "$data"
echo
echo "Re-encode as the zap's route with:  abi.encode(commands, inputs)   (drop the deadline)"
echo
echo "NOTE: keep UR_VERSION in sync with the executing router's ABI generation — v4 action structs differ"
echo "      between generations and calldata encoded for the wrong one will not decode."
