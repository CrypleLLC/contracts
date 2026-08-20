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

| Contract        | Purpose                                                                                          |
| --------------- | ------------------------------------------------------------------------------------------------ |
| `DeadManSwitch` | One record per account: timers, status, guardian commitment. Singleton keyed by account address. |
| `ProofRegistry` | One Merkle root per (account, epoch), anchoring vault-item hashes. Singleton.                    |

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

| Function          | Caller                 | Effect                                                                                                |
| ----------------- | ---------------------- | ----------------------------------------------------------------------------------------------------- |
| `configure(...)`  | **owner account only** | Sets periods and the guardian commitment; refreshes the clock. During `Contest` this also **revokes** |
| `checkIn()`       | **owner account only** | Refreshes the clock. During `Contest` this is the **revocation**                                      |
| `trigger(owner)`  | **anyone**             | Only after `lastCheckIn + inactivityPeriod`                                                           |
| `finalize(owner)` | **anyone**             | Only after `triggeredAt + contestPeriod`                                                              |

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
the root of _tampered_ data, and the heir's verification would then pass against the tampered blob —
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

**Client consequence.** If an anchor for epoch N is mined after epoch N closed _and_ N already holds
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

## Counterfactual deployment through a bundler

A user's smart account is not deployed at sign-up. Its address is derived, quoted, and only becomes
a contract when the first UserOperation carries `initCode`. That path had never been exercised:
every test called `factory.createAccount` directly and passed `initCode: ""`, so no bundler had ever
judged the factory.

Two things now cover it, and they answer different questions.

**`test/CounterfactualDeployment.t.sol`** proves the encoding and the state transition against a
local EntryPoint: one operation deploys the account and configures the switch, the deployed address
is the one derived beforehand, the switch records the account rather than the relayer as caller, and
a foreign key leaves nothing deployed. It cannot answer the bundler question, because ERC-7562's
rules for factories are enforced **off-chain** by the bundler.

**`script/bundler_userop.py`** answers that one, against the live Arbitrum Sepolia deployment.

```bash
python3 script/bundler_userop.py estimate           # bundler validation; spends nothing
python3 script/bundler_userop.py simulate           # eth_call of handleOps; spends nothing
python3 script/bundler_userop.py send               # broadcast; needs the sender funded
python3 script/bundler_userop.py receipt <opHash>   # poll and read back chain state
```

Every mode prints the sender's balance next to the prefund the declared gas limits require, so the
one failure this harness kept producing is visible before it is paid for.

It requires `cast` on the path and Python's `cryptography` package, and reads
`ARBITRUM_SEPOLIA_RPC_URL`, `BUNDLER_URL` and `OWNER_P256_KEY` from the environment — all three have
defaults, and the default key is a fixed test scalar that must never hold anything.

It reads the repository's `.env` itself, since only `forge` gets that for free, with real
environment variables taking precedence over the file.

Three details worth knowing before changing it:

- **The userOpHash comes from the chain, not from this repository.** EntryPoint v0.8 hashes a
  UserOperation with EIP-712, so the script calls `entryPoint.getUserOpHash` rather than
  reimplementing it. A local reimplementation that drifted would produce signatures that fail only
  in production.
- **`simulate` uses an `eth_call` state override** to give the counterfactual sender a balance. That
  covers the prefund without a transaction, so the whole path — factory, initialisation, P-256
  verification through RIP-7212, and `configure()` — is exercised for free against the deployed
  contracts. A wrong key reverts, so a clean result is meaningful rather than vacuous.
- **`estimate` is signature-blind.** Bundlers accept a dummy signature when estimating, so a clean
  estimate says the factory was accepted and says nothing about the signature. Use `simulate` for
  the signature.
- **`send` refuses to broadcast an underfunded operation, and does not trust its own success.** It
  aborts locally when the balance is below the required prefund rather than paying a bundler to
  return `AA21`; after the operation mines it re-reads `eth_getCode(sender)` and
  `DeadManSwitch.recordOf(sender)`, because a bundler accepting an operation and the operation
  having done its job are two different claims. `receipt` runs that same read-back on its own, for
  when the poll window expires while the op is still pending.

The stake question this settles is recorded in
[`p256-account/README.md` § The factory needs no EntryPoint stake](https://github.com/CrypleLLC/p256-account#the-factory-needs-no-entrypoint-stake),
along with the result of the real send on 2026-08-17.

### The unsponsored path needs the address funded before it holds code

With no paymaster the account pays its own prefund, so ETH has to reach the counterfactual address
*before* the deploying operation. **Re-measured on EntryPoint v0.8, 2026-08-19**, deploy-plus-configure
burns **654,529 gas** and cost **0.0000786 ETH** — the 660,006 figure recorded on 2026-08-17 was
measured on v0.9 against the old implementation and is superseded. The version change was worth
0.8%; the declared limits below were worth far more.

**Size the transfer against the declared gas limits, not against that cost.** The EntryPoint demands
`(verificationGasLimit + callGasLimit + preVerificationGas) × maxFeePerGas` in hand before it starts.
Fund for the cost and the send fails with `AA21` while holding more than enough ETH to have paid for
itself.

### The declared limits are measured, not constants

The harness used to declare a flat 3,300,000 gas, which demanded 0.00066 ETH of prefund for an
operation that spends a tenth of it — and made the paymaster price every sponsored operation off that
figure. `measure_gas_limits` now calls `eth_estimateUserOperationGas` before every send and declares
the result plus headroom.

| Operation | declared before | declared now | prefund at 0.2 gwei |
| --- | --- | --- | --- |
| deploy + `configure()` | 3,300,000 | ~613,000 | 0.00066 → **0.000123 ETH** |
| `checkIn()` | 3,300,000 | ~265,000 | 0.00066 → **0.000053 ETH** |

**The headroom differs by field because the refund rules do.** Unused `verificationGasLimit` and
`callGasLimit` are refunded, so headroom there costs only a larger prefund requirement — they carry
`EXECUTION_GAS_HEADROOM`, 1.25. **`preVerificationGas` is charged in full as declared, used or not**,
so every unit of headroom is spent; it carries `PRE_VERIFICATION_GAS_HEADROOM`, 1.15. Declaring
300,000 there against a real requirement near 127,000 is where most of the old waste sat: it is why
the on-chain operation was billed 654,529 gas for roughly 373,000 gas of measured work.

**`preVerificationGas` cannot be hardcoded lower on Arbitrum.** It embeds the L1 data-availability
fee, so it moves with the L1 base fee — observed between 51,802 and 147,188 for the same operation.
A constant tuned to a quiet L1 turns into a rejected operation on a busy one, which is why this is
measured per-send rather than lowered. `PROBE_*` are the ceilings used for the estimate call itself,
and remain the declared values when the bundler cannot be reached.

Nothing is lost to the gap: the unspent prefund lands in the account's EntryPoint **deposit** rather
than its balance, where it is withdrawable with `withdrawTo` and spendable on later `checkIn()`
operations. The 2026-08-17 run left 0.00058 ETH there; under measured limits the same gap is about
0.00004 ETH, so the deposit no longer quietly absorbs most of what a user transferred.

**The cost figure is the least durable number here.** The EntryPoint charges
`min(maxFeePerGas, baseFee + maxPriorityFeePerGas)`, and the base fee at execution was 0.02002 gwei
against a 0.2 gwei ceiling — so the same operation at the ceiling costs about **0.000132 ETH**.
Budget from the gas number.

With sponsorship (Task 50) the funding step disappears entirely, which is why that task and this one
share a dependency.

## Gas sponsorship

The account is an ERC-4337 account bound to **EntryPoint v0.8** at
`0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108`, set by an `entryPoint()` override in `P256Account`
that returns `ERC4337Utils.ENTRYPOINT_V08` instead of OpenZeppelin's `Account` default of v0.9.

**Bundler support does not imply paymaster support, and assuming it cost a round-trip.** Pimlico's
bundler for chain 421614 lists v0.9 in `eth_supportedEntryPoints`, and this section previously
concluded from that alone that no account change was needed for sponsorship. It was wrong: bundling
and sponsoring are separate services, and a verifying paymaster is deployed per EntryPoint version.
Against a live key and policy, `pm_getPaymasterStubData` answers v0.7 and v0.8 with stub data and
rejects v0.9 with **"Paymaster is not enabled for this EntryPoint version"**. The version is
therefore chosen by what the *paymaster* supports, not the bundler.

**Nothing in this protocol used a v0.9-only feature.** `PackedUserOperation` is byte-identical
between the two versions, EIP-7702 support exists in both, and RIP-7212 is a precompile that owes
nothing to the EntryPoint. What v0.9 adds and this codebase never referenced: the optional
`paymasterSignature` appended to `paymasterAndData`, `getCurrentUserOpHash()`, the `Stakeable`
helper, and a handful of finer-grained errors and events. The one real cost of v0.8 is thinner
revert data on some paymaster and beneficiary failure paths.

[`test/SponsoredCheckIn.t.sol`](test/SponsoredCheckIn.t.sol) proves the mechanism against the **live
chain** rather than a local EntryPoint: an account holding zero wei, with no deposit of its own,
configures and checks in while a paymaster pays. It also asserts the account's balance and deposit
are still zero afterwards, so a passing test cannot mean "it quietly paid for itself".

```bash
forge test --match-contract SponsoredCheckIn    # needs ARBITRUM_SEPOLIA_RPC_URL
```

The test skips itself when that variable is unset, so `forge test` stays green on a machine or CI
job without an endpoint.

### What the test cannot prove, and what is needed to close it

The paymaster in that test is `TestPaymasterAcceptAll`, deployed and funded inside the fork. It
proves the **EntryPoint accounting** — that a zero-balance account can be paid for — and it cannot
prove that a *hosted* sponsor will agree to pay, because that decision is a policy on someone
else's server.

Probed against Pimlico's public endpoint on 2026-08-17, the `pm_*` methods are routed but
unsponsored:

```
pm_getPaymasterStubData -> "Sponsorship policy ID is required for this API key"
```

That error is the whole remaining gap, and it is an account signup rather than any code change. Two
environment variables turn it on:

| Variable | Meaning |
| --- | --- |
| `PIMLICO_API_KEY` | project key; the harness routes `pm_*` to `api.pimlico.io` when set |
| `PIMLICO_SPONSORSHIP_POLICY_ID` | the policy that decides what gets paid for |

```bash
python3 script/bundler_userop.py sponsor      # ERC-7677 stub -> estimate -> final -> send
```

**Scope the policy to contract addresses if the provider allows it, and to a spend cap regardless.**
A policy that sponsors any target turns the paymaster into a public faucet for arbitrary calldata,
since anyone may deploy a `P256Account` through the same factory. Pimlico's documented policy schema
covers chain ids, date bounds and spend limits; target-address scoping is a dashboard/webhook
feature whose exact form should be read off the dashboard rather than assumed from here. On testnet
the spend cap is sufficient; **on Arbitrum One target scoping is not optional.** The three targets
this protocol needs are:

| Address | Why |
| --- | --- |
| `0x6951a65CDc706A2D23E1015d35B8353F18A569a9` | `DeadManSwitch` — `configure`, `checkIn` |
| `0xd344197975C4D47f97dDB1d26b91a96be6e83930` | `ProofRegistry` — `anchor` |
| `0xa2Cd247C12f087450f4991c92e6FBc7cE015a527` | `P256AccountFactory` — first-operation deployment |

The factory entry is what makes a **fresh** account sponsorable. Without it the very first
operation — the one the user has no ETH for and no way to fund — is the one that gets refused, and
sponsorship helps only users who already needed no help.

`sponsor` adapts to the account's state: an undeployed sender gets `initCode` plus `configure()`,
an already-configured one gets `checkIn()`. Point it at a fresh `OWNER_P256_KEY` to exercise the
zero-ETH path from nothing. It verifies sponsorship by **arithmetic rather than by trust** — the
sender's balance and EntryPoint deposit must both be unchanged and zero afterwards, so an operation
that quietly paid for itself is reported as a failure, not a success.

### An account must always be able to pay for itself

Sponsorship is not only a convenience here — its failure points the wrong way. A user who cannot
check in looks exactly like a user who has died: after `inactivityPeriod` anyone may `trigger()`,
and the switch fires on a living owner. So the unsponsored path is a **safety requirement**, not a
fallback of last resort. The EntryPoint charges the account directly when `paymasterAndData` is
empty, which needs no extra contract, and
`test_AnUnsponsoredAccountCanStillCheckInFromItsOwnDeposit` pins that it works. This is limitation
**L7** in the architecture document.

## Deployment

Configuration lives in two places: the network aliases and verification keys in
[`foundry.toml`](foundry.toml), and the secrets they expand, which are listed in
[`.env.example`](.env.example). Copy it to `.env` and fill it in; `forge` loads `.env` from the
repository root automatically.

| Variable                   | Used by                      | Notes                                                                |
| -------------------------- | ---------------------------- | -------------------------------------------------------------------- |
| `ARBITRUM_SEPOLIA_RPC_URL` | `--rpc-url arbitrum_sepolia` | Public endpoint works; a keyed provider is steadier for `--verify`   |
| `ARBITRUM_ONE_RPC_URL`     | `--rpc-url arbitrum_one`     | Production only                                                      |
| `ARBISCAN_API_KEY`         | `--verify`                   | An Etherscan V2 key from etherscan.io covers Arbiscan on both chains |
| `DEPLOYER_ACCOUNT`         | `--account`                  | Keystore alias created by `cast wallet import <name> --interactive`  |
| `DEPLOYER_PRIVATE_KEY`     | `--private-key`              | Alternative to the keystore; throwaway testnet keys only             |
| `PRODUCTION`               | `Deploy.s.sol`               | `true` selects the mainnet floors and rejects anything below them    |
| `MIN_INACTIVITY_SECONDS`   | `Deploy.s.sol`               | Optional override, seconds                                           |
| `MIN_CONTEST_SECONDS`      | `Deploy.s.sol`               | Optional override, seconds                                           |

The deployer is a plain EOA that signs the two `CREATE` transactions and nothing else. It is
unrelated to any user's P-256 key and holds no authority over `DeadManSwitch` or `ProofRegistry`
once they exist — neither contract has an owner, an admin, or an upgrade path.

```bash
forge script script/Deploy.s.sol \
  --rpc-url arbitrum_sepolia \
  --account cryple-deployer \
  --sender 0xYourDeployerAddress \
  --broadcast
```

For a dry run, drop `--broadcast` and pass `--sender` alone — no password is needed, and the script
still prints the addresses it would create, the gas estimate, and the minimum periods in force. Note
that a dry run computes addresses from the sender's _current_ nonce, so they will not match the real
deployment if anything else is broadcast in between.

Verify afterwards, explicitly — **`--verify` cannot be trusted here.** On the 2026-08-16 deployment
it reported _"We haven't found any matching bytecode"_ and then _"All (0) contracts were verified!"_,
exiting zero having submitted nothing. It has to infer which source produced each address by matching
bytecode against build artifacts, and a failed match is not treated as an error.

```bash
forge verify-contract <DeadManSwitch> src/DeadManSwitch.sol:DeadManSwitch --chain 421614 --watch \
  --constructor-args $(cast abi-encode "constructor(uint32,uint32)" 300 120)

forge verify-contract <ProofRegistry> src/ProofRegistry.sol:ProofRegistry --chain 421614 --watch
```

`DeadManSwitch` needs its constructor arguments re-encoded with **the values actually used at
broadcast**; `ProofRegistry` takes none. Neither command needs the deployer key — verification is an
HTTPS POST of source code, not a transaction. Confirm the result on Arbiscan rather than trusting the
CLI: an unverified contract returns an empty `SourceCode` field from
`module=contract&action=getsourcecode`.

The account factory in [`p256-account`](../p256-account) is deployed separately and has an additional
wrinkle — its implementation is created inside the factory constructor and needs its own submission.
See its README.

## Status

**Unaudited.** Deployed to Arbitrum Sepolia on 2026-08-16 from commit `db9582f`, compiler `v0.8.30`,
optimizer enabled at 200 runs. Both contracts are verified on Arbiscan:

| Contract        | Address                                                                                                                             | Constructor                               |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| `DeadManSwitch` | [`0x6951a65CDc706A2D23E1015d35B8353F18A569a9`](https://sepolia.arbiscan.io/address/0x6951a65CDc706A2D23E1015d35B8353F18A569a9#code) | `minInactivity = 300`, `minContest = 120` |
| `ProofRegistry` | [`0xd344197975C4D47f97dDB1d26b91a96be6e83930`](https://sepolia.arbiscan.io/address/0xd344197975C4D47f97dDB1d26b91a96be6e83930#code) | none                                      |

**This deployment is for demonstration and testing only.** Its minimum periods are 300 and 120
seconds, so a full `configure → trigger → contest → finalize` cycle completes in about seven minutes.
They are constructor arguments with no upgrade path, so Arbitrum One requires a fresh deployment at
the production floors — see [Minimum periods are a deployment
constant](#minimum-periods-are-a-deployment-constant).

The full deployment record lives in
[`.docs/onchain-architecture.md`](../api-general/.docs/onchain-architecture.md#deployment-record)
and must capture, per deployment: commit hash, compiler version and settings, constructor
arguments, the minimum-period constants in force, and the Arbiscan verification link.
