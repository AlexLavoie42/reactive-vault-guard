# HANDOFF.md — keep this current at all times

Status: **CORE DEPLOY COMPLETE AND LIVE-PROVEN (2026-11-10/11 night).** Everything in
README.md's evidence table is on-chain. A fresh agent can resume from here without
re-deploying anything.

## Current deployed state (ground truth, verified 2026-11-11 ~03:30 UTC)

| Thing | Chain | Address / value |
|---|---|---|
| ReactiveVaultGuard (guard v2, THE deliverable) | Lasna 5318007 | `0xD1d3395a8Adc34E20b945610a07a6159A207E15e` |
| guard float / alerts | Lasna | 0.2708 REACT / 1 alert (ruleId 2, srcTx 0x135bce1e…) |
| VaultGuardCallback v2 (guard v2's recipient) | Base 84532 | `0xc14C0849a1710796b8A37f275a3287e91F78605a` |
| DemoVault v2 (PAUSED by guard; 0.003 ETH protected) | Base 84532 | `0x220bb8b5432e25f2ce14a087fb9521018300cb54` |
| Attacker v2 (storm contract, operator = deployer key) | Base 84532 | `0x0eea119a5f4690163c58b9894cec73dc5aec1ca7` |
| Guard v1 (previous agent; subscribed to vault v1, fired but callback undelivered) | Lasna | `0xb7336850b04FfEc251d5a6C00cFD37bc50e99fc0` |
| Deployer key (testnet-only, in .env, gitignored) | both | `0x2367fe7863Df01901543b696b82ada177ec106E7` |
| Deployer balance | Base / Lasna | ~0.00098 ETH / ~2.07 REACT |

Key tx hashes: guard deploy `0xd742e5415b04b8e5c61c6b9d394a0e0a5261ef2fad5907a4c450e03e337eda6d`,
storm `0x135bce1e9d658f220ee462bd55159c67b8ad4389c639d35f0f23f26c1615a705`,
ExploitDetected `0xfda54e1eb21936b7ca2d5db704870427e313c44c27bdab187680cfbd1b5da48e`,
pause callback `0x677e2a585a36681509c93f05f5170fb4502983b4dcce0ffaa0c76c9089658fe9`,
faucet bridge `0xed339b241b94eac56f7f18312dbff2edfd4be1363adb0e60c97b46456854c9fa`.

## Networks / mechanics (learned, verified)

- Reactive Lasna testnet: chain **5318007**, RPC `https://lasna-rpc.rnk.dev`, explorer
  `https://lasna.reactscan.net`, system contract `0x8888888888888888888888888888888888888888`.
- Base Sepolia: chain **84532**, RPC `https://sepolia.base.org` (getLogs capped at 200-block
  ranges — use `https://base-sepolia-rpc.publicnode.com` for wide log scans), explorer
  `https://sepolia.basescan.org`. Reactive callback proxy on Base Sepolia:
  `0x476F44b11F5C942c58f4c8E3d0300E5710743585` (from dev.reactive.network/origins-and-destinations).
- Reactive faucet (FREE, no captcha): send Base-Sepolia ETH to bridge
  `0x2afaFD298b23b62760711756088F75B7409f5967` → 100 REACT per 1 ETH on Lasna, delivered
  in <60 s. (Sepolia bridge: `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`.)
- Billing model (the critical gotcha): **every matched log = one billed react() call on
  Lasna** (~0.016 REACT/log measured; guard v1's 60-log storm drained its 0.3 float, which
  killed callback delivery — "a contract in debt receives nothing"). Guard v2 deployed
  with 0.4 REACT and used ~0.13 for an 8-log storm. Keep float ≥ 10× expected storm cost.
- Lasna gas: base fee 100 gwei, nodes validate against maxFeePerGas — a deploy needs
  balance ≥ value + gas×200gwei (~0.36 REACT for the guard's ~1.8M gas).

## Every command that produced tonight's state

Run from `C:\Users\lavoi\Money\tools\reactive-watchdog`, PATH includes
`/c/Users/lavoi/.foundry/bin`, `.env` sourced (`set -a; source .env; set +a`).

```bash
forge build && forge test                                    # 16/16 pass
# callback v2 on Base (deploy + setPauser on vault v2):
PRIVATE_KEY=$RW_DEMO_PRIVATE_KEY VAULT_ADDRESS=0x220bb8b5432e25f2ce14a087fb9521018300cb54 \
GUARD_ADDRESS=0xD1d3395a8Adc34E20b945610a07a6159A207E15e \
forge script script/WireBase.s.sol:WireBase --rpc-url base_sepolia --broadcast --slow
# faucet top-up (0.02 Base ETH → 2 REACT):
cast send 0x2afaFD298b23b62760711756088F75B7409f5967 --value 0.02ether \
  --private-key $RW_DEMO_PRIVATE_KEY --rpc-url https://sepolia.base.org
# guard v2 on Lasna (nonce 2 → deterministic 0xD1d3…; value bumped to 0.4 in script):
PRIVATE_KEY=$RW_DEMO_PRIVATE_KEY VAULT_ADDRESS=0x220bb8b5432e25f2ce14a087fb9521018300cb54 \
CALLBACK_ADDRESS=0xc14C0849a1710796b8A37f275a3287e91F78605a \
forge script script/DeployReactive.s.sol:DeployReactive --rpc-url reactive_testnet --broadcast --slow --start-fresh
# attack (cast-driven; do NOT use AttackDemo with --broadcast, see gotchas):
cast send 0x0eea119a5f4690163c58b9894cec73dc5aec1ca7 "deposit()" --value 0.005ether \
  --private-key $RW_DEMO_PRIVATE_KEY --rpc-url https://sepolia.base.org
cast send 0x0eea119a5f4690163c58b9894cec73dc5aec1ca7 "attack(uint256)" 0.004ether \
  --private-key $RW_DEMO_PRIVATE_KEY --rpc-url https://sepolia.base.org
# poll: vault paused() on Base; guard alertsLength() on Lasna  → paused ≈15–30 s later
# follow-up proof (reverts EnforcedPause at estimate — that IS the evidence):
cast send 0x0eea119a5f4690163c58b9894cec73dc5aec1ca7 "followUpWithdraw(uint256)" 0.003ether \
  --private-key $RW_DEMO_PRIVATE_KEY --rpc-url https://sepolia.base.org
```

## Gotchas (each one cost time tonight)

1. **forge script + vm.sleep is a trap**: `AttackDemo.s.sol` polls with `vm.sleep(1000)`;
   with `--broadcast` the sleep loop runs in simulation AND again in the broadcast replay
   (>10 min, stalled past a 600 s timeout; killed). Use the cast-driven flow above or
   `demo/run-demo.sh`. AttackDemo remains useful as an offline narrative driver.
2. **Stale broadcast JSONs block re-runs**: previous agent died mid-broadcast →
   `--start-fresh` required (archives old run automatically).
3. **Node "insufficient funds" checks max fee, not base fee**: even with 200 gwei base/100,
   the send is rejected unless balance covers value + gas×maxFee.
4. **sepolia.base.org getLogs ≤ 200-block range** (HTTP 413); publicnode allows wide ranges.
   Lasna getLogs ≤ 30000-block range (use recent from-block).
5. **Deterministic CREATE addresses**: same deployer + nonce → same address on ANY chain
   (guard v2 on Lasna coincidentally equals attacker v1 on Base: both deployer-nonce-2).
   `cast compute-address <addr> --nonce <n>` predicts it — used to wire the callback
   BEFORE the guard existed (circular-dependency break).
6. **Block timestamps skew across chains** (±1–2 s): quote block-distance + wall-clock
   polling for latency claims, not raw timestamps.
7. Windows: remappings are absolute-path style in `remappings.txt` (`@reactive/=lib/reactive-lib-omni/src/`); no via_ir anywhere. solc 0.8.30.

## Why guard v1 (previous agent) never paused vault v1

Full reactive loop DID fire (ExploitDetected tx `0xc3b18dd1…`, alert 0, ruleId 2, srcTx
`0x6970bbf8…`) and the CallbackPlaced event was correctly formed (chain 84532, recipient,
400k gas, payload). The 60-log storm billed ~0.3 REACT of react() calls, draining the
guard's float → contract in debt → callback never dispatched → vault v1 drained unpaused.
Fix in v2: 0.4 REACT float + 8-log storm → callback delivered in seconds. Guard v1 is kept
as historical evidence; do not reuse (it watches vault v1 `0x6fd716e0…` only).

## Remaining work for DoraHacks submission (deadline 2026-12-05 12:00 UTC-8)

1. **Demo video** per DEMO.md (all evidence links already live).
2. **Submission on dorahacks.io/hackathon/reactive-omni-buildathon**: fresh tab → /detail
   URL → "Submit Build" (registers entry); repo link + video. Account AlexLavoie42 @u_6d87021a51dde4.
3. Optional polish (nice-to-have, NOT required for submission):
   - Port 1–2 more event-shaped rules from `x402-endpoint/src/rules.ts` (e.g. unlimited
     ERC20 Approval `amount == type(uint256).max` — event-local, cheap; needs second
     subscribe() + an ERC20 demo target). Redeploy guard v3 with `DeployReactive.s.sol`
     (~0.4 REACT float; wallet has ~2.07). Pattern: bump value in script, re-run WireBase
     with new GUARD_ADDRESS first (use cast compute-address to precompute), then attack.
   - Git: repo has NO commits yet (submodules staged). Init commit + push to a public
     GitHub repo for the submission link.
   - `.github/workflows/test.yml` exists (forge test CI) — wire to the pushed repo.
4. If re-proving the loop on camera: fresh vault+attacker via DeployBaseSepolia (needs
   GUARD_ADDRESS for the callback; or reuse the deterministic-address trick), then the
   cast attack flow above. Keep storm ≤ 10 logs; keep guard float ≥ 0.3 REACT.

## Wallet/keys policy

`.env` (gitignored) holds only the throwaway testnet key (`RW_DEMO_PRIVATE_KEY`). It has
never held mainnet value. Never copy secrets from `C:\Users\lavoi\Money\secrets.env` into
this repo — reference by env var only. Zero capital: all funds are testnet faucet grants
(Base Sepolia faucet + Reactive's 100:1 ETH→REACT bridge).
