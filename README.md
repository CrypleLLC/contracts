# Cryple Contracts

The on-chain layer of Cryple's digital inheritance protocol: an impartial clock and an integrity
notary. Implements [`.docs/onchain-architecture.md`](../api-general/.docs/onchain-architecture.md)
in the API repository, which is the specification and wins over this code where they disagree.

> **The chain is the impartial clock and the integrity notary. It authorizes release and proves the
> data was not altered. It never holds, moves, or decrypts any user data — and it cannot.**

**Target chain:** Arbitrum Sepolia for the MVP, Arbitrum One for production. Arbitrum is required
rather than incidental: the RIP-7212 P-256 precompile is what lets a user's existing seed-derived
key sign transactions without a wallet, a browser extension, or a second curve.

## Contracts

| Contract | Purpose |
| --- | --- |
| `DeadManSwitch` | One record per account: timers, status, guardian commitment. Singleton keyed by account address. |
| `ProofRegistry` | One Merkle root per (account, epoch), anchoring vault-item hashes. Singleton. |

The account layer — the ERC-4337 smart account and its P-256 validator — lives in
[`p256-account`](../p256-account), a separate MIT-licensed repository with no dependency on
Cryple. That separation is deliberate: the account and its social-recovery module are generic
infrastructure, and nothing in them is inheritance-specific.

## What this code does not do

Repeated here because the inverse is the most common misreading, and an auditor will check:

- It stores no user data. No plaintext, no ciphertext. Only hashes and commitments.
- It holds no keys and cannot decrypt anything. Release is a state flag, not a key handover.
- **It does not enforce the confidentiality window.** A contract cannot stop an off-chain party
  that already holds ciphertext and key material from using it early. This is limitation **L1** in
  the architecture document and it is the most important honest caveat about the whole design.
- It does not verify identity or death. It measures silence, not mortality.

## DeadManSwitch

```
Unconfigured ──configure()──▶ Active ──trigger()──▶ Contest ──finalize()──▶ Released
                               ▲   │                   │
                               └───┴───checkIn()───────┘
```

| Function | Caller | Effect |
| --- | --- | --- |
| `configure(...)` | **owner account only** | Sets periods and the guardian commitment; refreshes the clock. During `Contest` this also **revokes** |
| `checkIn()` | **owner account only** | Refreshes the clock. During `Contest` this is the **revocation** |
| `trigger(owner)` | **anyone** | Only after `lastCheckIn + inactivityPeriod` |
| `finalize(owner)` | **anyone** | Only after `triggeredAt + contestPeriod` |

Two access decisions carry the trust model, and both are tested:

**Check-in is owner-only.** It must be a userOp signed by the user's P-256 key on the user's own
device. Nothing server-side may ever check in on a user's behalf — if Cryple's backend could, it
could keep a dead user's switch alive forever and the "impartial judge" claim would be false.
`test_OnlyTheOwnerCanCheckIn` pins it.

**Trigger and finalize are permissionless.** Anyone may advance a record whose deadline has
genuinely passed: an heir, a guardian, a keeper bot, or Cryple's relayer. If only Cryple could
advance the state, Cryple's disappearance would freeze every switch, which is precisely the failure
mode the on-chain layer exists to remove. A premature call reverts and the caller pays the gas.

`Released` is terminal. There is no undo, because an undo function would be an attack surface aimed
at the exact moment the owner can no longer defend themselves. The contest period is the protection
instead.

### There are two revocation paths, and both emit `Revoked`

`checkIn()` is the documented revocation, but `configure()` resets a record from any status except
`Released`, so an owner who reconfigures during `Contest` also cancels the pending release. Both
paths emit `Revoked`, so **an indexer can key off that one event and be complete** — it does not
need to treat `Configured` as a possible revocation or reconcile against `statusOf()`.

When `configure()` revokes, `Revoked` is emitted **before** `Configured` and `CheckedIn`, so a
consumer replaying the log in order can never write a countdown state after the cancellation that
ended it. `test_RevokedPrecedesConfiguredAndCheckedIn` pins the order; two further tests pin that
no `Revoked` is emitted when there was no pending release to cancel.

### Minimum periods are a deployment constant

`minInactivityPeriod` and `minContestPeriod` are constructor arguments, so a testnet deployment can
exercise the whole lifecycle in minutes while mainnet enforces production floors (for example 30
days and 7 days). **The values in force must be recorded in the deployment record** — they are the
difference between a switch that protects a user on holiday and one that fires on them.

## ProofRegistry

```
anchor(uint64 epoch, bytes32 root)          // owner account only
mapping(account => mapping(epoch => root))  // epoch = unixSeconds / 86400
```

- **Leaf** = `SHA-256(encrypted blob bytes)` — the ciphertext as stored, exactly what an heir
  downloads.
- **Tree** = SHA-256 throughout, including internal nodes. Proofs are verified **only in the heir's
  browser**, never on-chain, so there is no gas argument for keccak256, and one hash function
  everywhere removes a class of client bugs.

**Anchoring is signed by the user, not the backend.** A relayer authorised to anchor could anchor
the root of *tampered* data, and the heir's verification would then pass against the tampered blob —
silently destroying the exact guarantee the registry exists to provide. The relayer may only relay.

### A closed epoch is frozen

Once an epoch ends, the root recorded for it can never be restated — `anchor` reverts with
`EpochAlreadyAnchored` on any write to a past epoch that already holds a root, including a write of
the identical root. This is what makes an inclusion proof durable: an heir holding a valid proof
against the epoch-N root cannot have it invalidated afterwards. `test_RewritingAnOccupiedPastEpochIsRejected`
and `testFuzz_AClosedEpochNeverChanges` pin it.

Two writes stay legal, and neither rewrites history:

- **Re-anchoring within the current epoch**, which is expected — the vault changes during the day.
  Today's root is mutable and freezes at midnight (`test_TodaysRootFreezesWhenItsEpochCloses`).
- **Backfilling a past epoch that was never used**, which is not an overwrite. The client depends on
  it: an anchor submitted at 23:59 may be mined after midnight, and rejecting it would burn a
  sponsored userOp for a clock race.

Only the owner's own account can anchor, so this was never reachable by a compromised backend. It
was reachable by anyone holding the owner's key, and the guarantee as documented is unconditional —
so the code now enforces it rather than the document describing an intention.

**Client consequence.** If an anchor for epoch N is mined after epoch N closed *and* N already holds
a root, the transaction reverts. The client must treat `EpochAlreadyAnchored` as "re-anchor at the
current epoch", not as an error to surface.

## Privacy rules

Normative for every contract and every event here:

- **Never on-chain:** guardian addresses, heir addresses, identities, item names or counts, email
  addresses, `user_address`, `username`, or any relationship between two accounts.
- **Allowed:** the account address, timers and status, the guardian Merkle root, vault roots, epochs.
- Events are as public as storage. `test_EventsCarryNoGuardianOrHeirAddress` asserts that no
  guardian or heir address appears in any topic or data word across a full lifecycle.

The residual leak is accepted honestly: an observer learns that an address uses an inheritance
protocol, its configured periods, and its check-in cadence.

## Development

```bash
forge build
forge test
```

Tests cover the full state machine, both permission boundaries, the revocation path, minimum-period
enforcement, the privacy rule above, and a fuzz over period configuration asserting the switch never
releases early.

## Deployment

Configuration lives in two places: the network aliases and verification keys in
[`foundry.toml`](foundry.toml), and the secrets they expand, which are listed in
[`.env.example`](.env.example). Copy it to `.env` and fill it in; `forge` loads `.env` from the
repository root automatically.

| Variable | Used by | Notes |
| --- | --- | --- |
| `ARBITRUM_SEPOLIA_RPC_URL` | `--rpc-url arbitrum_sepolia` | Public endpoint works; a keyed provider is steadier for `--verify` |
| `ARBITRUM_ONE_RPC_URL` | `--rpc-url arbitrum_one` | Production only |
| `ARBISCAN_API_KEY` | `--verify` | An Etherscan V2 key from etherscan.io covers Arbiscan on both chains |
| `DEPLOYER_ACCOUNT` | `--account` | Keystore alias created by `cast wallet import <name> --interactive` |
| `DEPLOYER_PRIVATE_KEY` | `--private-key` | Alternative to the keystore; throwaway testnet keys only |
| `PRODUCTION` | `Deploy.s.sol` | `true` selects the mainnet floors and rejects anything below them |
| `MIN_INACTIVITY_SECONDS` | `Deploy.s.sol` | Optional override, seconds |
| `MIN_CONTEST_SECONDS` | `Deploy.s.sol` | Optional override, seconds |

The deployer is a plain EOA that signs the two `CREATE` transactions and nothing else. It is
unrelated to any user's P-256 key and holds no authority over `DeadManSwitch` or `ProofRegistry`
once they exist — neither contract has an owner, an admin, or an upgrade path.

```bash
forge script script/Deploy.s.sol \
  --rpc-url arbitrum_sepolia \
  --account $DEPLOYER_ACCOUNT \
  --broadcast --verify
```

Drop `--broadcast` for a dry run: the script still prints the addresses it would create and the
minimum periods in force. Both must be copied into the deployment record, along with the values
printed for `production`, `minInactivityPeriod` and `minContestPeriod` — they are constructor
arguments and cannot be changed after broadcast.

`--verify` submits every contract the script broadcasts, which here is both of them. The account
factory in [`p256-account`](../p256-account) is deployed separately and does not have that property;
see its README.

## Status

**Unaudited, nothing deployed.** The deployment record lives in
[`.docs/onchain-architecture.md`](../api-general/.docs/onchain-architecture.md#deployment-record)
and must capture, per deployment: commit hash, compiler version and settings, constructor
arguments, the minimum-period constants in force, and the Arbiscan verification link.
