# Markets — event-outcome tokens on the fakeable base

Prediction-style events where participation is free (credits → fake tokens) or staked
(real underlying). See `PLAN.md` (implemented) for the normative semantics.

## Components

- `src/OutcomeToken.sol` — one per {event, outcome, underlying}; a FakeableERC20
  derivative; the event is the vault and the only real mint/burn path; the
  underlying's credits registry is the only fake minter.
- `src/Event.sol` — holds the pooled underlying; deposits close at the resolution
  block; resolver-only resolution; proportional redemption at the snapshotted rate
  (real → underlying, fake → credits), loser no-op, zero-winner unwind at par.
- `src/Resolver.sol` — the stake-weighted resolution engine: escrowed votes,
  plurality + quorum, slashing/rewards, DEFER escalation, the appeal layer (bond +
  escalating window/quorum, bounded finality at Lmax).
  `ResolverStake` (same file) is the real-only stake token (split for EIP-170
  headroom: engine 15.2 KB, token 12.3 KB).
- `src/CreditsRegistry.sol` — per-underlying credits ledger: welcome grant, owner
  grants, credits ↔ fake conversions, event-only recredit on withdrawal.
- `src/EventFactory.sol` — beacon-proxied events + outcome tokens; the trustless
  verification anchor (isEvent + beacons + pinned implementations).
- `script/Deploy.s.sol` — full-stack deploy for one underlying; writes
  `site/public/config.deployed.json`.
- `site/` — the dApp (credits-first, address-first; explore via factory logs).

## Gates

- `forge test` — 27 tests + 3 system invariants (stake backing, event accounting,
  credits conservation) over 128k+ fuzzed calls.
- `cd site && node e2e/integration.mjs` — full flow on fresh anvil: welcome credits
  → convert → deposit → stake/vote/conclude/finalize → redeem (fake recredited at
  the redemption rate, loser no-op).
- `forge build --sizes` — all implementations ≤ 16 KiB.

## dApp

```
cd site && npm i && npm run dev
```

Copy `site/public/config.deployed.json` over `site/public/config.json` after a
deploy. The dApp verifies pasted event addresses by reading the ERC1967 beacon slot
and checking the implementation against the pinned `trustedEventImpl`, and explores
trustlessly via the factory's `EventCreated` logs — no backend.
