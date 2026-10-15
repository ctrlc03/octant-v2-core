# CRISP allocation demo (local, end to end)

`run-demo.mjs` runs a whole Octant allocation round through
[`CrispAllocationMechanism`](../../../src/mechanisms/mechanism/CrispAllocationMechanism.sol) on a
local Interfold/CRISP stack. Ballots are encrypted for real, the ballot proofs are real, and a
ciphernode committee decrypts the tally.

```mermaid
sequenceDiagram
  participant O as Operator
  participant M as CrispAllocationMechanism
  participant I as Interfold
  participant C as CRISPProgram
  participant V as Voter (CRISP SDK)
  O->>M: signup x3, propose x3, fund matching pool
  O->>M: openRound() — freezes census + options, pays fee
  M->>I: request(E3) — CRISP reads census from M.getPastVotes
  Note over I: committee sortition + DKG → key published
  V->>C: encrypted ballot + Noir proof (relayed by CRISP server)
  Note over V,C: Bob re-votes; only his latest ballot counts
  Note over I: window closes → homomorphic sum → threshold decryption
  O->>M: finalizeVoteTally() pulls decodeTally(e3Id)
  O->>M: queueProposal x3, recipients redeem pro rata
```

## Scenario

| Voter | Deposit (= credits) | Ballot over projects 1/2/3 |
|---|---|---|
| alice | 10 | 7 / 3 / 0 |
| bob | 20 | 20 / 0 / 0 while coerced, then re-votes 0 / 15 / 5 |
| carol | 30 | 10 / 5 / 15 |

Someone else also adds a mask (an all-zero, unsigned input) to alice's slot. On chain, that mask
looks the same as bob's re-vote. That is why a coercer who watched bob's first ballot can't tell
whether it still counts.

The expected decrypted tally is 17 / 23 / 20 credits: bob's latest ballot counts, and the mask
leaves alice's ballot unchanged. The 660-token pot (600 matching plus 60 of deposits) is split pro
rata to those credits.

## Prerequisites

- An Interfold checkout next to this repo (`../interfold`, or set `INTERFOLD_DIR`). It needs the
  CRISP dev toolchain from `examples/CRISP/Readme.md`: Foundry, Node, pnpm, Rust, `nargo`, `yq`,
  `wasm-pack`.
- CRISP dev build: `pnpm dev:setup` in `examples/CRISP`.
  - That script `cargo install`s an `interfold` binary built with
    `--features test-only-skip-proof-aggregation`.
  - The ciphernodes need that feature. If another `interfold` comes first on your `PATH`, build one
    into the repo and put it first:
    ```sh
    cargo build --locked --release -p e3-cli --bin interfold --features test-only-skip-proof-aggregation
    export PATH="$PWD/target/release:$PATH"
    ```
- Circuits for 0.19.0. `crates/zk-prover/versions.json` has no `circuits_checksums` pin for 0.19.0,
  so the `interfold noir setup` inside `dev:up` fails with `checksum missing for circuits-0.19.0.tar.gz`.
  Install the release archive once, from `examples/CRISP`:
  ```sh
  gh release download v0.19.0 -R theinterfold/interfold -p 'circuits-0.19.0.tar.gz'
  interfold noir setup --circuits-archive circuits-0.19.0.tar.gz --allow-unpinned-archive
  ```
- Contracts built in this repo: `forge build`.

## Run

```sh
# terminal 1 — Interfold checkout
cd examples/CRISP && pnpm dev:up        # wait for "CIPHERNODES HAVE BEEN ADDED."

# terminal 2 — this repo
node script/demo/crisp/run-demo.mjs
```

The script uses fresh deterministic accounts funded with `anvil_setBalance`, so it never shares a
nonce with the CRISP server, the ciphernodes or the randomness helper. It uses anvil time travel to
reach the start and end of the ballot window.

A run takes about 6.5 minutes on an M-series Mac:
- about 90 s of committee setup (the sortition window is 60 s) and DKG;
- about 50 s to prove each ballot in Node;
- about 5 s for compute and decryption.

The run ends with:

```
[ 375s] decrypted credits per project: [17, 23, 20] (expected [17, 23, 20])
┌─────────┬─────┬──────────────────────────────────────────────┬─────────┬────────┬──────────┐
│ (index) │ pid │ recipient                                    │ credits │ shares │ received │
├─────────┼─────┼──────────────────────────────────────────────┼─────────┼────────┼──────────┤
│ 0       │ 1   │ '0x953d55fE2f5F06B66c34Ab8284dBD69A50225D18' │ 17      │ '17'   │ '187'    │
│ 1       │ 2   │ '0xFa1Ab5840A98315237F255467c735c89B8b0Ec6f' │ 23      │ '23'   │ '253'    │
│ 2       │ 3   │ '0x0Ce10fecFdAe77Ab20aCc4EC1FC18340C34aA7B0' │ 20      │ '20'   │ '220'    │
└─────────┴─────┴──────────────────────────────────────────────┴─────────┴────────┴──────────┘
```

## What is real and what is mocked locally

- **Real:**
  - BFV encryption under the committee key.
  - Noir/UltraHonk ballot proofs, verified on chain by `CRISPProgram`.
  - DKG and threshold decryption by 3 ciphernodes.
  - The `CRISPProgram` and `Interfold` contracts.
- **Mocked by the CRISP dev profile:**
  - The compute step's OpenVM receipt (`MockOpenVmReceiptVerifier`).
  - Data availability (`MockCrispDataAvailabilityVerifier`).
  - Randomness (`MockRandomnessProvider`).
  - Ciphernode proof aggregation (`test-only-skip-proof-aggregation`).
  - The fee token (`MockUSDC`).
- **Parameters:** `insecure-512` (`paramSet = 0`), so the plaintext modulus is `t = 100`. Each
  project's credit total has to stay below 100. The demo picks a voting power divisor of 1 token per
  credit to meet that.

## Limitations of the mechanism

- Funding is linear: a project's shares are its decrypted credits times the divisor. Private QF
  needs a CRISP circuit variant.
- At most 10 options (`MAX_OPTIONS`). The census is frozen at `openRound`, and summing total voting
  power there is O(voters).
- Ballots need an EOA signature, which is checked by in-circuit ECDSA. Safe and other ERC-1271
  wallets can't vote.
- There is no factory entry yet; the demo deploys the mechanism directly.
