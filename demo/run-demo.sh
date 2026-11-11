#!/usr/bin/env bash
# ReactiveVaultGuard live demo driver (testnet only, throwaway keys only).
# Drives the attack with cast so every step's tx hash and timestamp is captured.
#
# Required env (see .env.example):
#   RW_DEMO_PRIVATE_KEY  throwaway testnet key (never funded with real funds)
#   VAULT_ADDRESS        DemoVault on Base Sepolia
#   ATTACKER_ADDRESS     Attacker on Base Sepolia
#   GUARD_ADDRESS        ReactiveVaultGuard on Reactive Lasna
#   CALLBACK_ADDRESS     VaultGuardCallback on Base Sepolia (optional, for pause evidence)
set -euo pipefail

BASE_RPC="${BASE_RPC:-https://sepolia.base.org}"
REACTIVE_RPC="${REACTIVE_RPC:-https://lasna-rpc.rnk.dev}"
KEY="${RW_DEMO_PRIVATE_KEY:?set RW_DEMO_PRIVATE_KEY}"
VAULT="${VAULT_ADDRESS:?set VAULT_ADDRESS}"
ATTACKER="${ATTACKER_ADDRESS:?set ATTACKER_ADDRESS}"
GUARD="${GUARD_ADDRESS:?set GUARD_ADDRESS}"
DEPOSIT="${DEPOSIT:-0.01ether}"
CHUNK="${CHUNK:-0.001ether}"
WAIT="${WAIT:-90}"

echo "== pre-attack state =="
cast balance "$VAULT" --ether --rpc-url "$BASE_RPC"
cast call "$VAULT" "paused()(bool)" --rpc-url "$BASE_RPC"

echo "== 1. attacker deposits $DEPOSIT (builds legitimate credit) =="
DEPOSIT_TX=$(cast send "$ATTACKER" "deposit()" --value "$DEPOSIT" --private-key "$KEY" --rpc-url "$BASE_RPC" --json | grep -oE '"transactionHash": *"[^"]+"' | cut -d'"' -f4)
echo "deposit tx: $DEPOSIT_TX"

echo "== 2. reentrancy storm: attacker.attack($CHUNK) =="
ATTACK_TX=$(cast send "$ATTACKER" "attack(uint256)" "$CHUNK" --private-key "$KEY" --rpc-url "$BASE_RPC" --json | grep -oE '"transactionHash": *"[^"]+"' | cut -d'"' -f4)
ATTACK_BLOCK=$(cast tx "$ATTACK_TX" blockNumber --rpc-url "$BASE_RPC")
ATTACK_TS=$(cast block "$ATTACK_BLOCK" timestamp --rpc-url "$BASE_RPC")
echo "storm tx:    $ATTACK_TX"
echo "storm block: $ATTACK_BLOCK  timestamp: $ATTACK_TS"
echo "vault TVL after storm: $(cast balance "$VAULT" --ether --rpc-url "$BASE_RPC") ETH"

echo "== 3. polling for the cross-chain pause (1s interval, max ${WAIT}s) =="
START=$(date +%s)
PAUSED=0
while [ $(( $(date +%s) - START )) -lt "$WAIT" ]; do
  if [ "$(cast call "$VAULT" "paused()(bool)" --rpc-url "$BASE_RPC")" = "true" ]; then
    PAUSED=1
    break
  fi
  sleep 1
done
END=$(date +%s)
if [ "$PAUSED" = "1" ]; then
  echo "VAULT PAUSED ${WAIT:+}$((END - START))s after the storm (wall clock)"
else
  echo "vault NOT paused within ${WAIT}s"
fi

echo "== 4. attacker follow-up drain attempt =="
if cast send "$ATTACKER" "followUpWithdraw(uint256)" "$CHUNK" --private-key "$KEY" --rpc-url "$BASE_RPC" 2>&1 | grep -iE "revert|pause|error" ; then
  echo "follow-up REVERTED (guard held the line)"
else
  echo "follow-up SUCCEEDED - guard failed"
fi

echo "== 5. evidence: ExploitDetected on Reactive Lasna =="
cast logs --from-block 1 --to-block latest --address "$GUARD" \
  "ExploitDetected(uint256,uint8,address,uint256,uint256,uint256,uint256,uint256,uint64)" \
  --rpc-url "$REACTIVE_RPC" || true

echo "== 6. evidence: pause events on Base Sepolia =="
cast logs --from-block 1 --to-block latest --address "$VAULT" \
  "Paused(address,string)" --rpc-url "$BASE_RPC" || true

echo "done. record all tx hashes above in DEPLOYMENT.md"
