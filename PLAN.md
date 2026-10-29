# Event Markets — master plan

Working name: **markets**. A prediction-style system on top of the
[`fakeable`](../fakeable/) wrapped-token base, where fake-token participation is
free (credits) and real-token participation is staked value.

**Status:** DRAFT v1 — for owner review. No implementation until approved. This repo
is independent (separately pushable to GitHub/Radicle; the eth superproject ignores
it). Depends on the `fakeable` repo (abstract base + beacon/factory).

---

## 1. System in one paragraph

An **event** (e.g. "match X on 2026-11-01") is a contract instance — its address is
the canonical handle, shared by word-of-mouth or found by block exploration. Each
event has 2..N outcomes; each {event, outcome, underlying} triple gets its own
**OutcomeToken**, a `FakeableERC20` (real + fake components). Before the event's
required **resolution block**, users deposit underlying into an outcome and receive
real tokens, or convert credits into fake tokens of an outcome. After the resolution
block, the **Resolver** (a real-only staked wrapper) runs a stake-weighted vote —
outcomes or DEFER — with slashing for losing voters and rewards paid from slashed
stakes. When an outcome finalizes: deposits are disabled; winning-outcome holders
redeem **proportionally against the pooled underlying of ALL outcomes** — real legs
pay underlying, fake legs pay **credits**; losing outcomes' redeem is a no-op.
Credits live in a per-underlying **CreditsRegistry** that mints/burns fake tokens,
grants credits for interacting, and recredits on withdrawal.

## 2. Semantics (normative)

### 2.1 Events and outcome tokens

- An event `E` fixes at creation: `underlying` (any ERC20 incl. fee-on-transfer),
  `outcomes` (2..N, immutable), `resolutionBlock` (required block height, future),
  `resolver` (the Resolver contract for that underlying), `credits` (the underlying's
  CreditsRegistry).
- For each outcome `k`, the event factory deploys `OutcomeToken(E, k)` — a
  `FakeableERC20` derivative, beaconed by the fakeable beacon (so the fakeable
  upgrade path upgrades all outcome tokens everywhere).
- **Deposits close at `resolutionBlock`** (hard cutoff — otherwise post-outcome
  sniping is free; see OQ-1). Resolution (finalize) may happen at any later block.
- Outcome token mint paths:
  - **Real**: `E.deposit(k, amount)` — pulls underlying (delta-measured, FoT safe),
    mints real `OutcomeToken(E,k)` 1:1 with the received delta. All outcome deposits
    pool into the event's vault accounting.
  - **Fake**: credits-only. `CreditsRegistry.convertToFake(E, k, amount)` burns
    credits and mints fake outcome tokens (the registry is the sole authorized fake
    minter for outcome tokens of its underlying).

### 2.2 Resolution and redemption math

Let, at finalize with winner `w`:

- `P` = pooled underlying = Σ_k realDeposits(k) (the event's vault balance).
- `S_w` = total winning supply = `real_w + fake_w`.

**Redemption rate** `R = P / S_w` (underlying units per winning token unit).
- Real winner burning `r` units receives `r·R` underlying (real backing is
  conserved: `real_w·R ≤ P` since `real_w ≤ S_w`; the slippage against 1:1 is the
  winners' winnings — losers' stakes fund the rate above 1).
- Fake winner burning `f` units receives `f·R` **credits** (never underlying — the
  fakeable invariant "fake never redeems" is preserved; credits are the synthetic
  settlement asset).
- Losing outcomes: `redeem` is a **no-op** (returns 0, no state change — the user's
  spec; losing tokens become display-only, effectively worthless).
- **Zero-winner fallback** (nobody backed `w`, `S_w = 0`): the event unwinds — each
  outcome refunds its own real depositors 1:1 and burns fake to credits 1:1 (per-
  outcome contribution tracking makes this exact).

### 2.3 The Resolver (stake, vote, slash, defer)

- One **Resolver per underlying** (singleton, ERC1967). Its stake token is a
  real-only `FakeableERC20` derivative over the same underlying: fake minting is
  disabled entirely (`_authorizeFakeMint` returns false; the fake surface is inert).
  Stakers wrap underlying → real stake tokens 1:1, and may unwrap anytime they are
  not locked in a live round.
- **Round lifecycle** for event `E` (first openable at/after `E.resolutionBlock`):
  1. **Open**: anyone opens a round (permissionless; no bond in v1 — OQ-2).
  2. **Vote**: stakers escrow stake into the round behind outcome `k` or `DEFER`
     during the voting window `W` blocks. Escrowed stake is locked (no unwrap, no
     transfer of the escrowed portion). One vote per staker per round (re-vote
     moves the whole stake — no splitting — keeps tally and slashing simple; OQ-3).
  3. **Close & tally**: after `W` blocks, anyone closes. The plurality stake-weight
     wins. **Quorum**: if total voted stake < `q%` of the stake token supply, the
     round auto-defers (no slashing).
  4. **Finalize**:
     - Outcome `w` wins → `E.resolve(w)` (push: resolver calls the event; the event
       trusts only its `resolver`). Slashing: losing voters lose `s%` of escrowed
       stake (burned from the wrapper — real burn, backing released to the
       resolver's reward pool); winning voters split the slashed pool pro-rata to
       their escrowed stake (reward = their stake × slashedPool / winningStake,
       paid in stake tokens). DEFER voters are unslashed and unrewarded.
     - DEFER wins (or quorum fails) → `E.resolutionBlock` advances by `D` blocks
       (defer period), all escrow returns unslashed, window `W` doubles (cap `Wmax`)
       to raise the cost of serial griefing.
- Slashing math is integer-floored per position; dust (rounding remainders) stays in
  the reward pool and rolls into future rewards — never minted, never lost.

### 2.4 Credits

- One **CreditsRegistry per underlying** (singleton, ERC1967). Ledger
  `credits[user]`; totalCredits tracked.
- **Sources**: interaction grants (policy — v1: fixed welcome grant on first
  interaction + owner grants; OQ-4) and **recredit on withdrawal** (fake winners).
- **Conversions** (1:1 with fake token units):
  - credits → fake: `convertToFake(E, k, amount)` → `OutcomeToken(E,k).mintFake`.
  - fake → credits: `convertToCredits(E, k, amount)` → `burnFakeFrom` (the user
    approves the registry on the token once; the `*From` variants added to the
    fakeable base are exactly this seam).
- The registry verifies an event's legitimacy before converting: the event must be
  registered in the **EventFactory** for the same underlying (registry ↔ factory
  cross-check; arbitrary contracts can never mint or drain credits).
- Outcome tokens authorize fake minting iff `caller == creditsRegistryOf(underlying)`
  — the `_authorizeFakeMint` hook from the base, wired at init.

### 2.5 Upgradeability & ownership

| Component | Proxy | Upgrade authority |
|---|---|---|
| OutcomeToken impl | fakeable `UpgradeableBeacon` | the system owner (existing beacon-admin structure) |
| Event impl | event `UpgradeableBeacon` (ERC1963 beacon proxies — each event a stable address) | the system owner |
| Resolver (per underlying) | ERC1967 proxy | the system owner |
| CreditsRegistry (per underlying) | ERC1967 proxy | the system owner |
| EventFactory | ERC1967 proxy (or immutable; OQ-5) | the system owner |

All proxies are beacon/ERC1963; the owner (EOA → multisig later) is the single
upgrade authority, exactly the fakeable ownership structure.

## 3. Contract surfaces

```solidity
// OutcomeToken — FakeableERC20 derivative (beaconed by fakeable's beacon)
function initialize(IERC20 underlying, address event_, string name, string symbol) external initializer;
function event_() external view returns (address);
// _authorizeFakeMint(caller) => caller == creditsRegistryOf(underlying)
// real burn seam for redemption: burnRealFrom (NEW in fakeable v1.1, §7)

// Event (beacon proxy; address is the public handle)
function deposit(uint8 outcome, uint256 amount) external;            // before resolutionBlock; delta-measured
function redeem(uint8 outcome, uint256 amount) external;             // after finalize; proportional (§2.2); loser no-op
function resolve(uint8 winner) external;                             // resolver-only
function state() external view returns (Status, uint8 winner, uint256 resolutionBlock);
// Status: Open | VotingOpen (informational) | Resolved | Unwound

// Resolver (ERC1967, per underlying; stake token = real-only FakeableERC20)
function wrap/unwrap(uint256) /* inherited; unwrap blocked while escrowed */;
function openRound(address event_) external;
function vote(bytes32 roundId, uint8 outcomeOrDefer, uint256 stake) external;  // escrows
function closeRound(bytes32 roundId) external;
function finalize(bytes32 roundId) external;     // tally, slash, reward, push resolve/defer
function claim(bytes32 roundId) external;        // pull-based stake+reward return

// CreditsRegistry (ERC1967, per underlying)
function creditsOf(address) external view returns (uint256);
function convertToFake(address event_, uint8 outcome, uint256 amount) external;
function convertToCredits(address event_, uint8 outcome, uint256 amount) external;
function grantFor(address user, uint256 amount) external; // event-only (recredit on withdraw) + owner policy grants

// EventFactory (one per underlying set; deploys beacon-proxied events + outcome tokens)
function createEvent(IERC20 underlying, uint8 outcomes, uint256 resolutionBlock, string metadataURI)
    external returns (address event_, address[] outcomeTokens);
```

## 4. Storage & sizing discipline

Same discipline as fakeable: ERC-7201 namespaced storage + 50-slot gaps on every
upgradeable contract; `underlying`/`resolver`/`credits`/outcome list init-once,
upgrade-locked; implementation size budget ≤ 16 KiB each (Event is the fat one —
outcome-token registry + vault accounting + redemption math; split a `RedeemCore`
via the ApplyCore delegatecall pattern from autolift if it blows the budget).

## 5. The dApp

A static site (pattern: `autolift/site` — vanilla TS + ethers, `/config.json` for
chain/factory/registry addresses). Two hard requirements from the spec:

1. **Credits-first UX**: the default mode never touches real underlying. Connect →
   claim welcome credits → convert to fake tokens of an outcome → participate. Real
   deposit is an opt-in toggle per event. Credits balance is always visible next to
   (and visually distinguished from) real balances.
2. **Trustless event discovery**: events are addresses, so the dApp is
   **address-first**:
   - **Paste-an-address**: probe any address — read its ERC1967 beacon slot, check
     the beacon + implementation against the version-pinned trusted implementation
     list (hardcoded in the dApp per release), probe the `state()`/outcome surface,
     and display the event only if it verifies. Nothing trusted except code hashes.
   - **Block exploration**: scan the EventFactory's `EventCreated` logs straight
     from the user's RPC (no indexer, no backend), filter to verified
     implementations, list events by recency/status. This is fully trustless —
     factory logs + on-chain state are the only inputs.

## 6. Security considerations

- **Fake never redeems** (inherited): redemption pays credits for fake legs; the
  invariant suite from fakeable is extended with event-level fuzzing (§8 M-6).
- **Redemption conservation**: `Σ realPayouts ≤ P` always (rate math §2.2); losing
  stakes fund the rate — no external solvency assumption.
- **Resolver capture**: quorum + defer escalation bound griefing; a >50% stake
  attacker CAN force outcomes — that is the honest trust assumption of stake voting
  (documented, OQ-6 on mitigation via escalating defer quorums).
- **Vote sniping**: deposits close at `resolutionBlock`; voting starts no earlier.
- **Credit inflation is harmless by construction**: credits only ever buy fake
  tokens; fake never redeems underlying; recredit rates mirror the redemption rate
  (losers' fake stakes inflate fake winners' credits — synthetic and contained).
- **Reentrancy**: nonReentrant on deposit/redeem/convert/finalize (base discipline).
- **Registry↔factory cross-check**: only factory-registered events can move credits.
- **Upgrade keys**: single owner today; the doc's deployment runbook includes the
  multisig handoff as a launch gate.

## 7. Changes to `fakeable` (v1.1)

- **Add `burnReal(uint256)` + `burnRealFrom(address, uint256)`** (allowance-based) —
  the redemption path must burn real tokens from holders; today unwrap is the only
  real burn. Small, additive, no storage change. With regression tests.
- Nothing else: the fake surface, vault seam, and `_authorizeFakeMint` already fit.

## 8. Milestones

| ID | Milestone | Done when |
|----|-----------|-----------|
| M-1 | fakeable v1.1: `burnReal(From)` + tests | forge suite + invariant green |
| M-2 | OutcomeToken + Event + EventFactory: create, deposit (delta-measured), close at resolutionBlock | unit tests |
| M-3 | Resolver: wrap/unwrap, rounds, escrow, plurality + quorum, slash/reward, defer escalation | unit tests incl. defer chains |
| M-4 | CreditsRegistry: grants, conversions, recredit, registry↔factory cross-check | unit tests |
| M-5 | Redemption: winner math (real→underlying, fake→credits), loser no-op, zero-winner unwind | unit tests incl. dust |
| M-6 | Invariant fuzzing: conservation (Σ payouts ≤ pool; credits conservation), upgrade regression across all four proxy topologies | 128k-call invariants green |
| M-7 | dApp: credits-first flow, address probing, factory-log exploration | e2e vs local chain |
| M-8 | Sizing sweep, docs, deployment runbook (incl. multisig handoff), interface freeze | budget checks |

## 9. Open questions

1. ~~Deposit cutoff~~ — decided: deposits close at `resolutionBlock` (sniping is
   otherwise free). Reopenable if events want late markets.
2. Round-open bond? v1 none; consider a small bond burned on spam rounds.
3. Re-vote moves the whole stake (no splitting) — simpler tally; acceptable?
4. Credit grant policy beyond welcome grant — faucet rate? per-interaction grants
   (the spec says "users gain credits for interacting")? Proposal: fixed welcome
   grant + owner grants only, keep everything else out of v1.
5. EventFactory proxied or immutable? Proposed: ERC1967 for uniformity.
6. Resolver trust floor: document ">50% stake wins" as the model, or add a
   challenge/appeal layer (UMA-style escalation)? v1: document.
7. Slash rate `s%`, quorum `q%`, window `W`, defer period `D`, `Wmax` — governance
   parameters at init; proposed defaults: s=10%, q=5%, W=~1 day in blocks,
   D=~1 day, Wmax=~1 week.
8. Zero-winner unwind vs. treasury sweep — proposed: unwind (refund per outcome).
9. Metadata (event title/rules) — `metadataURI` string at creation only, or on-chain
   text? Proposed: URI + optional content hash.

## 10. Non-goals (v1)

- Trading between outcomes (no AMM/order book — outcome tokens are transferable
  ERC20s, so secondary markets can exist externally).
- Multi-underlying events; cross-event credits.
- Anonymous/private participation.
