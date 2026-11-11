# DEMO.md — demo-video outline (DoraHacks submission, 2–4 min)

Recording style: terminal screencast (asciinema/obs), two panes — left Base Sepolia,
right Reactive Lasna. Every step links to txs already on chain (see README evidence table),
so the video is a guided tour of verifiable artifacts, then a fresh live run if desired.

## Pre-roll (10 s)
- Title card: "ReactiveVaultGuard — on-chain exploit detection and circuit-breaking with
  Reactive Network. Base Sepolia → Reactive Lasna → Base Sepolia, fully on-chain."
- Show repo: `forge build && forge test` → 16 passing.

## Act 1 — The setup (30 s)
- Diagram (README): vulnerable vault on Base Sepolia, guard on Reactive Lasna.
- Reactscan: guard `0xD1d3395a…` — point at the constructor `Subscription(chainId=84532,
  contract=vault, topic0=Withdrawal)` event in deploy tx `0xd742e541…`.
- One-liner why it matters: "no bots, no off-chain listeners — the network itself reacts."

## Act 2 — The attack (45 s)
- Basescan storm tx `0x135bce1e…`: zoom on the 8 `Withdrawal` logs — same tx hash,
  `callerCreditBefore` frozen at 0.005 while `vaultBalanceBefore` drops every frame.
  Narrate: "CEI violation in flight — this is what reentrancy looks like as data."
- Vault balance during storm: 0.035 → 0.003 ETH.

## Act 3 — The reaction (45 s)
- Reactscan tx `0xfda54e1e…`: `ExploitDetected(alertId=0, ruleId=2, attacker=0x0eea…,
  amount=0.004, srcTx=0x135bce1e…)`. "Rule 2: frozen credit across same-tx withdrawals."
- Basescan tx `0x677e2a58…`: `VaultPausedByGuard` + vault `Paused(...)`; point at `from
  0xF7E866D7…` — "delivered by Reactive's callback machinery, not our key."
- Latency callout: storm block 57231016 → pause block 57231023; wall clock ~15–30 s.

## Act 4 — The proof it mattered (30 s)
- Terminal: `cast call vault paused()` → `true`.
- Terminal: attempt `followUpWithdraw(0.003ether)` → revert `EnforcedPause (0xd93c0665)`.
- "Remaining TVL (0.003 ETH) is protected. The attack was mid-flight; the breaker won."

## Act 5 — Breadth + close (20 s)
- `forge test` output scroll: drain rule, reentry rule, auth checks, kill switch,
  full-loop sim, legit-user-does-not-trigger (no false positives).
- Close: rules ported from our 28-pattern exploit library; thresholds owner-tunable;
  all testnet, verifiable links in the README. "Reactive Network: the watchdog that
  lives on-chain."

## Recording checklist
- [ ] Fresh demo (optional stronger ending): deploy new vault via `script/DeployBaseSepolia.s.sol`,
      point guard's `SYSTEM.subscribe` at it (needs new guard deploy), run `demo/run-demo.sh`
      end-to-end on camera — see HANDOFF "Running the live demo again".
- [ ] Keep both explorer panes pre-loaded; zoom on event rows.
- [ ] End card: repo link + deployed addresses table.
