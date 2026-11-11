# ReactiveVaultGuard

A cross-chain security watchdog on **Reactive Network (Lasna testnet, chain 5318007)** that
watches **Base Sepolia (chain 84532)** for exploit-shaped events and trips a circuit breaker
on the monitored contract — fully on-chain, no bots, no servers.

Entry for the Reactive Omni Buildathon (time-sensitive DeFi track). Everything below is
**deployed and verifiable on public testnets** — zero mainnet, zero capital, throwaway keys.

## How it works

```
Base Sepolia (84532)                      Reactive Lasna (5318007)
─────────────────────                     ─────────────────────────
DemoVault.withdraw()  ──Withdrawal log──▶ ReactiveVaultGuard.react()
  (CEI-violating,                              │ classify log:
   reentrancy-                                 │  RULE_DRAIN   amount ≥ 50% of pre-withdrawal TVL
   vulnerable on                               │  RULE_REENTRY frozen creditBefore across
   purpose)                                    │               same-tx Withdrawal logs
                                               ▼
                                        emit ExploitDetected(...)
                                        SYSTEM.requestCallbackV_1_0(...)
                                               │
                          ◀── callback delivery ┘
VaultGuardCallback.onExploitDetected()
  (auth: onlyServiceProvider + onlyCallbackSender)
  └─▶ DemoVault.pause("ReactiveVaultGuard: exploit-shaped pattern detected")
        └─▶ attacker's follow-up withdraw reverts EnforcedPause
```

The detection rules are runtime-observable distillations of the highest-signal patterns from
our 28-rule Solidity exploit-pattern library (`x402-endpoint/src/rules.ts`): value-flow
anomalies (drain-shaped withdrawals) and CEI/reentrancy violations (state not updated
between same-tx interactions). Detection is non-reverting; one pause request per source tx.

## Deployed contracts (2026-11-10, all live and verified)

| Contract | Chain | Address | Deploy tx |
|---|---|---|---|
| **ReactiveVaultGuard** | Reactive Lasna 5318007 | [`0xD1d3395a8Adc34E20b945610a07a6159A207E15e`](https://lasna.reactscan.net/address/0xD1d3395a8Adc34E20b945610a07a6159A207E15e) | [`0xd742e5415b04b8e5c61c6b9d394a0e0a5261ef2fad5907a4c450e03e337eda6d`](https://lasna.reactscan.net/tx/0xd742e5415b04b8e5c61c6b9d394a0e0a5261ef2fad5907a4c450e03e337eda6d) |
| ↳ setCallbackRecipient | Lasna | — | [`0xbf8697b82c4405da3b0a1321635c980026fb4e7c3c0efecf1511e33c973fa777`](https://lasna.reactscan.net/tx/0xbf8697b82c4405da3b0a1321635c980026fb4e7c3c0efecf1511e33c973fa777) |
| **VaultGuardCallback** | Base Sepolia 84532 | [`0xc14C0849a1710796b8A37f275a3287e91F78605a`](https://sepolia.basescan.org/address/0xc14C0849a1710796b8A37f275a3287e91F78605a) | [`0xca780d893b9f635de3469e060d52f302950a3e88bfb7e15797f4b4415dab7080`](https://sepolia.basescan.org/tx/0xca780d893b9f635de3469e060d52f302950a3e88bfb7e15797f4b4415dab7080) |
| ↳ vault.setPauser | Base Sepolia | — | [`0x58cbd9f6b49a559ea7d50c53cb40538346c5526d84fac8b3cb11f3cf044847d1`](https://sepolia.basescan.org/tx/0x58cbd9f6b49a559ea7d50c53cb40538346c5526d84fac8b3cb11f3cf044847d1) |
| **DemoVault** (deliberately vulnerable) | Base Sepolia | [`0x220bb8b5432e25f2ce14a087fb9521018300cb54`](https://sepolia.basescan.org/address/0x220bb8b5432e25f2ce14a087fb9521018300cb54) | [`0x7c21ac88635079d696a8284e7b30f36cdff85c1820ecaad55b240a7f0499e9f1`](https://sepolia.basescan.org/tx/0x7c21ac88635079d696a8284e7b30f36cdff85c1820ecaad55b240a7f0499e9f1) |
| **Attacker** (demo exploit contract) | Base Sepolia | [`0x0eea119a5f4690163c58b9894cec73dc5aec1ca7`](https://sepolia.basescan.org/address/0x0eea119a5f4690163c58b9894cec73dc5aec1ca7) | [`0x7b0f2f5940a5498d0aae101e62ecfccd792c44284a298e565a2bf333e367810b`](https://sepolia.basescan.org/tx/0x7b0f2f5940a5498d0aae101e62ecfccd792c44284a298e565a2bf333e367810b) |

Deployer (throwaway testnet key): `0x2367fe7863Df01901543b696b82ada177ec106E7`.

## Live end-to-end proof (2026-11-10, storm → pause in seconds)

| Step | Evidence | Link |
|---|---|---|
| Faucet funding | 0.02 Base-Sepolia ETH → official Reactive faucet bridge `0x2afaFD298b23b62760711756088F75B7409f5967` → **+2.0 REACT** on Lasna (100:1) | [tx](https://sepolia.basescan.org/tx/0xed339b241b94eac56f7f18312dbff2edfd4be1363adb0e60c97b46456854c9fa) |
| 1. Attacker deposits (builds credit) | +0.005 ETH credit | [tx 0xaa90c07f](https://sepolia.basescan.org/tx/0xaa90c07fcdc7f87f73f65b13c5daa2e526d3968cfe517e27d4cd447c8dbe11ce) |
| 2. Reentrancy storm | `attack(0.004ether)` — **8 Withdrawal logs in one tx**, frozen `callerCreditBefore` (CEI violation); vault 0.035 → 0.003 ETH | [tx 0x135bce1e](https://sepolia.basescan.org/tx/0x135bce1e9d658f220ee462bd55159c67b8ad4389c639d35f0f23f26c1615a705) |
| 3. Guard classifies (RULE_REENTRY=2) | `ExploitDetected` on Lasna, alert 0: attacker `0x0eea…`, amount 0.004, evidence 0.005, srcBlock 57231016, srcTx `0x135bce1e…` | [tx 0xfda54e1e](https://lasna.reactscan.net/tx/0xfda54e1eb21936b7ca2d5db704870427e313c44c27bdab187680cfbd1b5da48e) |
| 4. Reactive callback pauses vault | `VaultPausedByGuard` + `Paused("ReactiveVaultGuard: exploit-shaped pattern detected")` — delivered by the Reactive callback machinery (`from 0xF7E866D7…`), not by us | [tx 0x677e2a58](https://sepolia.basescan.org/tx/0x677e2a585a36681509c93f05f5170fb4502983b4dcce0ffaa0c76c9089658fe9) |
| 5. Follow-up drain blocked | `followUpWithdraw(0.003ether)` reverts `EnforcedPause` (selector `0xd93c0665`) — remaining TVL protected | see "Verify" step 6 |

Observed latency: **storm block 57231016 → pause block 57231023**; in wall-clock polling the
vault read `paused=true` within ~15–30 s of storm inclusion (guard alert timestamp
1794368071 vs storm block timestamp 1794368072 — cross-chain clocks skew ±1–2 s).

## Verify it yourself (exact commands)

```bash
# 0. Foundry on PATH; repo at tools/reactive-watchdog (Windows: absolute remappings already set)
cd tools/reactive-watchdog
forge build && forge test          # 16 tests pass (detection rules, auth, full loop in local sim)

# 1. Guard on Reactive Lasna is live, subscribed, and holding a detection
cast call 0xD1d3395a8Adc34E20b945610a07a6159A207E15e "alertsLength()(uint256)" --rpc-url https://lasna-rpc.rnk.dev
cast call 0xD1d3395a8Adc34E20b945610a07a6159A207E15e "getAlert(uint256)(uint8,address,uint256,uint256,uint256,uint256,uint256,uint64)" 0 --rpc-url https://lasna-rpc.rnk.dev
# → 2, 0x0eea…, 4000000000000000, 5000000000000000, 84532, 57231016,
#   875614979109854…389957 (= 0x135bce1e… printed as uint256 decimal), 1794368071

# 2. ExploitDetected event on Reactive Lasna (Reactscan)
#    https://lasna.reactscan.net/tx/0xfda54e1eb21936b7ca2d5db704870427e313c44c27bdab187680cfbd1b5da48e

# 3. Vault on Base Sepolia is paused by the Reactive callback
cast call 0x220bb8b5432e25f2ce14a087fb9521018300cb54 "paused()(bool)" --rpc-url https://sepolia.base.org   # → true
cast balance 0x220bb8b5432e25f2ce14a087fb9521018300cb54 --rpc-url https://sepolia.base.org                    # → 0.003 ETH protected
#    Pause tx (from the Reactive deliverer, not our key):
#    https://sepolia.basescan.org/tx/0x677e2a585a36681509c93f05f5170fb4502983b4dcce0ffaa0c76c9089658fe9

# 4. The storm tx really emitted 8 same-tx Withdrawal logs with frozen creditBefore
cast receipt 0x135bce1e9d658f220ee462bd55159c67b8ad4389c639d35f0f23f26c1615a705 --rpc-url https://sepolia.base.org

# 5. Guard funding trail (faucet bridge, 0.02 ETH → 2 REACT)
#    https://sepolia.basescan.org/tx/0xed339b241b94eac56f7f18312dbff2edfd4be1363adb0e60c97b46456854c9fa

# 6. A new withdrawal attempt now reverts EnforcedPause (0xd93c0665) — the guard held
cast call 0x220bb8b5432e25f2ce14a087fb9521018300cb54 "credits(address)(uint256)" 0x0eea119a5f4690163c58b9894cec73dc5aec1ca7 --rpc-url https://sepolia.base.org
# (follow-up withdraw must be sent by the attacker operator key; the live attempt reverted
#  "execution reverted, data: 0xd93c0665: EnforcedPause" at gas estimation)
```

## Detection rules (ported from the 28-pattern library)

| Rule | Signal | Source pattern |
|---|---|---|
| `RULE_DRAIN` (1) | withdrawal ≥ `drainBps` (default 50%) of pre-withdrawal vault balance | value-flow anomaly lane |
| `RULE_REENTRY` (2) | ≥2 `Withdrawal` logs in one tx with non-decreasing `callerCreditBefore` | reentrancy-state-after-external-call / CEI lanes |

Both thresholds are owner-tunable (`setThresholds`); detection can be disarmed (`setArmed`).

## Repo layout

```
src/ReactiveVaultGuard.sol   reactive watchdog (Lasna)
src/VaultGuardCallback.sol   authenticated pause receiver (Base Sepolia)
src/DemoVault.sol            deliberately CEI-violating vault (demo target)
src/Attacker.sol             reentrancy storm driver (demo)
script/DeployBaseSepolia.s.sol, DeployReactive.s.sol, WireBase.s.sol, AttackDemo.s.sol
test/                        16 forge tests: rules, auth, kill switch, full loop
demo/run-demo.sh             cast-driven live demo driver (recommended over AttackDemo — see HANDOFF)
```

`.env` (gitignored) holds the throwaway testnet key: `RW_DEMO_PRIVATE_KEY`, `RW_DEMO_ADDRESS`.
No real funds have ever touched these keys or contracts. See `HANDOFF.md` for the full
operational log and `DEMO.md` for the demo-video script.
