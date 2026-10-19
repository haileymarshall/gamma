#!/usr/bin/env bash
# Pay for one IMD launch on Robinhood Chain through the Intake contract (0.5 IMD each).
# Usage: launch/pay.sh approve            once, lets the Intake pull up to 1 IMD
#        launch/pay.sh launch/01-game.json
#        launch/pay.sh launch/02-hook.json
# Signs with the key in ~/.gamma/deployer.env if it exists, else the Foundry keystore account "gamma"
# (cast wallet import gamma --interactive).
set -euo pipefail

if [[ -f ~/.gamma/deployer.env ]]; then
  # shellcheck disable=SC1090
  source ~/.gamma/deployer.env
  SIGNER=(--private-key "$GAMMA_PRIVATE_KEY")
else
  SIGNER=(--account gamma)
fi

IMD_API=https://api.imd.fun
RPC=https://rpc.mainnet.chain.robinhood.com
INTAKE=0xa43e6f75ee006411f79ac1c84120606c2330de82
IMD=0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127
PRICE=500000000000000000

if [[ "${1:-}" == "approve" ]]; then
  cast send $IMD 'approve(address,uint256)' $INTAKE 1000000000000000000 --rpc-url $RPC "${SIGNER[@]}"
  exit 0
fi

file=${1:?usage: launch/pay.sh approve | launch/pay.sh <launch file>}
if grep -q GAME_ADDRESS "$file"; then
  echo "$file still has GAME_ADDRESS placeholders: fill in the GammaGame address first" >&2
  exit 1
fi

blockers=$(curl -s -X POST "$IMD_API/requests/check" -H 'Content-Type: application/json' \
  -d "{\"action\":\"launch.open\",\"input\":$(jq -c . "$file")}" | jq -c '.blockers // .')
if [[ "$blockers" != "[]" ]]; then
  echo "IMD check failed, nothing paid: $blockers" >&2
  exit 1
fi

cast send $INTAKE 'request(bytes32,bytes,(address,bytes4),address,uint256)' \
  "$(cast format-bytes32-string 'launch.open@launch-1')" "$(cast from-utf8 "$(jq -c . "$file")")" \
  '(0x0000000000000000000000000000000000000000,0x00000000)' $IMD $PRICE \
  --rpc-url $RPC "${SIGNER[@]}"
