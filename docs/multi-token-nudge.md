# BatchNFTMinterMultiToken — Whitelist-Selected Multi-Token Nudge

Status: **implemented** — landed as the sibling contract `src/BatchNFTMinterMultiToken.sol`
(story 022, stages 0-7; reward-token selection moved from a caller-supplied
array to an owner-managed whitelist in story 025). The deployed
`src/BatchNFTMinter.sol` is frozen and unchanged.
Supersedes: the owner-set single `nudgePaymentToken` model in
`src/BatchNFTMinter.sol` (which remains deployed and frozen; the new model
lives in `src/BatchNFTMinterMultiToken.sol`), and the story-022
caller-selected `rewardTokens` array (replaced in story 025 — the caller now
supplies only `minRewards`, ordered to match the on-chain whitelist view
`getNudgeTokens()`).

## 1. Motivation

Today the nudge reward is a single ERC20 chosen by the owner
(`nudgePaymentToken`), and a qualifying batcher receives the contract's entire
balance of that one token. Two consequences:

- The owner is a bottleneck on *what* the incentive is. Rotating the reward
  asset is an owner transaction.
- Any other ERC20 that lands on the contract is inert. It can only leave via
  `rescueERC20`.

The new model **keeps the owner in control of eligibility and of the SET of
reward assets, while funding stays permissionless**:

- `nudgeSize` still gates *who* qualifies (batch size >= threshold). Unchanged.
- The owner curates an on-chain whitelist of nudge tokens
  (`setNudgeTokenWhitelist`); the *caller* supplies only a per-token
  `minRewards` floor, ordered to match `getNudgeTokens()`.

So with USDC and WBTC whitelisted and 100 USDC + 10 WBTC sitting on the
contract, a caller reads `getNudgeTokens() == [USDC, WBTC]` and passes
`[100_000000, 1_00000000]`. The contract deals only in raw wei amounts, so
decimals are a UI concern, never a contract concern.

(Story 025 note: story 022 originally let the caller name arbitrary
reward-token addresses per call. That opened a weird-token attack surface on
attacker-chosen addresses and made the payment-token exclusion an
untrusted-input check; the owner-vetted whitelist removes both. Anything odd
that lands on the contract is now simply `rescueERC20` territory.)

### Intended side effects (features, not accidents)

- **Permissionless top-up.** Anyone can seed the batch incentive with any
  whitelisted token by sending it to the contract. No owner action is required
  to fund — only to curate the whitelist.
- **Exogenous reward capture.** If the official UI doesn't surface a
  whitelisted token, a sophisticated user or bot can still enumerate
  `getNudgeTokens()` and the contract's balances and claim them. This is
  deliberate — unclaimed value should not be stranded.

### Why the "honeypot" framing does not apply

The pot is a *nudge*: a subsidy funded by yield derived from protocol-owned
capital, paid to whoever performs the `nudgeSize` qualifying mints. In normal
operation it is a fraction of the cost of those mints.

**That relation is an operating policy, not a construction.** Nothing in the
contract compares the pot to the cost of qualifying — `qualifies`
(`BatchNFTMinterMultiToken.sol:510`) tests `_nudgeSize != 0 && count >= _nudgeSize`
and nothing more. It never reads `paymentAmount`, `price`, `budget` or
`snapshot[i]`; no expression anywhere in the file relates the pot to the cost.
The pot *can* exceed one batch's cost, and if it does, a claimant profits in
isolation. Do not read the paragraph above as a bound the code enforces, and do
not "fix" the code to make it one.

That outcome is accepted and intended. Because the pot is funded from
externally-derived yield rather than from principal or user deposits, an
over-large pot is an **opportunity cost** — that yield could have gone directly
into liquidity growth — not a loss to the protocol. It is treated as a short-run
cost and as marketing spend: a visible profit opportunity attracts users, and
the deficit closes as the lowest-bidding marginal user takes the mint.
`NudgeStreamer` meters release so the market can find a clearing price against
the pot rather than racing a lump sum. In live operation the pot has not reached
50% of the qualifying cost before being claimed.

**What the contract does guarantee** (story 029, invariant-proven at 128,000
calls): the pot cannot leave through the refund path
(`refund <= budget <= paymentAmount`); a non-qualifying batch takes nothing; and
the minter's allowance is bounded at each mint's exact per-mint price. Those
three are constructions. The pot-versus-cost relation is not.

If someone erroneously over-funds the contract beyond the mint cost and a bot
snipes it, that is still correct behaviour — the error was in the sender, not in
`BatchNFTMinterMultiToken`. The contract makes no promise that arbitrary tokens sent to it
are recoverable, and the docstring must say so plainly.

Note the operational consequence (revised in story 025): for **whitelisted**
tokens, `rescueERC20` is still a race against watching bots — "pause first (or
unwhitelist first), then rescue" is the dependable sequence there. For
**non-whitelisted** tokens the race is gone: they can never be claimed through
`batchMint`, so `rescueERC20` is now the dependable escape hatch for anything
weird or unsupported that lands on the contract.

## 2. Interface change

```solidity
function batchMint(
    uint256 count,
    address recipient,
    uint256 paymentAmount,
    uint256[] calldata minRewards
) external whenNotPaused nonReentrant returns (uint256 totalPaid);

/// Owner-managed nudge-token whitelist (story 025). Hand-rolled enumerable
/// set (address[] + 1-based index mapping, swap-and-pop removal) because OZ
/// EnumerableSet requires solc ^0.8.24 and this repo pins 0.8.20.
function setNudgeTokenWhitelist(address token, bool allowed) external onlyOwner;
function getNudgeTokens() external view returns (address[] memory);
```

Removed (vs the frozen `BatchNFTMinter`):
- storage `address public nudgePaymentToken`
- `setNudgePaymentToken(address)` / `NudgePaymentTokenChanged`
- `error BatchMint__NudgeTokenMatchesPaymentToken` (replaced, see below)
- the scalar `uint256 minReward` parameter

Removed (vs the story-022 caller-selected shape):
- the `address[] calldata rewardTokens` parameter — the payout set is the
  on-chain whitelist, iterated in storage order

Retained unchanged:
- `nudgeSize`, `setNudgeSize`, `NudgeSizeChanged`
- `tokenMinter`, `dispatcherIndex` and their setters
- pauser wiring, `rescueERC20`, `DUST_THRESHOLD` refund threshold

Added:
```solidity
error BatchMint__RewardTokenIsPaymentToken(address token); // admin-time (story 025; defence in depth only since story 029)
error BatchMint__PaymentBudgetExhausted(uint256 mintIndex, uint256 price, uint256 remaining); // story 029
error BatchMint__ArrayLengthMismatch(uint256 tokensLength, uint256 minsLength);
error BatchMint__RewardBelowMinimum(address token, uint256 minReward, uint256 actualReward);
// story 025 whitelist admin:
error BatchMint__ZeroNudgeToken();
error BatchMint__NudgeTokenAlreadyWhitelisted(address token);
error BatchMint__NudgeTokenNotWhitelisted(address token);

event NudgeTokenWhitelistChanged(address indexed token, bool allowed);
```
`NudgePaid(recipient, token, amount)` is emitted **once per token actually
transferred** (its signature is already per-token, so no ABI change).

`minRewards.length` must equal the FULL whitelist length. **Every entry's
floor is live, including one currently equal to the derived payment token**
(story 029 removed the runtime skip that used to ignore it — see §4.1). An empty whitelist therefore demands an empty `minRewards` and the
batch is a plain mint loop. `getNudgeTokens()` must be re-fetched immediately
before every call: unwhitelisting uses swap-and-pop, which REORDERS the list.

## 3. Execution order (normative)

The ordering below is the correctness backbone. Do not reorder.

1. Validate `count != 0`, `recipient != address(0)`,
   `minRewards.length == _nudgeTokens.length` (the FULL whitelist).
2. Resolve `tokenMinter`, `dispatcherIndex`, `dispatcher`, and derive
   `paymentToken = dispatcher.primeToken()`.
3. Compute `qualifies = (nudgeSize != 0 && count >= nudgeSize)`.
4. **Pre-loop snapshot pass** over the whitelist, in storage order. **No
   element is skipped** — including one equal to `paymentToken` (story 029,
   §4.1):
   - `snapshot[i] = qualifies ? IERC20(token).balanceOf(address(this)) : 0`;
   - revert `BatchMint__RewardBelowMinimum` if `snapshot[i] < minRewards[i]`.

   Failing the floor here (before the pull) rather than after the loop is a
   pure gas improvement over the current contract; the atomic-rollback
   guarantee is identical either way.

   **This pass MUST stay before step 5.** Because the caller's budget has not
   arrived yet, `paymentToken.balanceOf(address(this))` here is the
   uncontaminated pot, exactly as clean as any other whitelisted token's — and
   the caller's own money can never be paid back to them as a reward.
5. **Pull, and measure what arrived.**
   `before = paymentToken.balanceOf(address(this))`;
   `safeTransferFrom(msg.sender, address(this), paymentAmount)`;
   `budget = min(balanceOf(address(this)) - before, paymentAmount)`.

   The credit is **measured, not quoted**. `paymentAmount` is what the caller
   asked to send, not what the contract received: a fee-on-transfer payment
   token credits less, and a `budget` seeded with the quote refunds more than
   the caller ever contributed — with the difference necessarily coming out of
   `P`. The `min` keeps the measurement one-sided, so a token with a transfer
   callback cannot let a third party's funds land inside this window and be
   credited to `msg.sender`.

   **This is the ONLY place `balanceOf` may inform `budget`, and only as a
   difference across this one transfer.** `P` appears in both readings and
   cancels; `D` has not happened yet. Widen the bracket to span the mint loop
   and the measurement swallows `D`; take a single absolute reading anywhere
   after this point and it is the three-pool conflation of §4.1 again.
6 + 7. **Mint loop with a tracked budget.** Starting from that `budget`, for
   each of `count` iterations: re-read `(, price,,) = configs(dispatcherIndex)`;
   revert `BatchMint__PaymentBudgetExhausted(i, price, budget)` if
   `price > budget`; `forceApprove(minter, price)`; `budget -= price`; `mint`.
   The price is re-read every iteration because the minter charges
   `config.price` and *then* ramps it, so a pre-mint read is exactly what that
   mint will charge. Every `forceApprove` is an ABSOLUTE target, never a delta.
8. `forceApprove(minter, 0)` — absolute and idempotent, so it also zeroes any
   allowance a non-decrementing token left standing after the final mint.
9. **Budget refund**: `available = paymentToken.balanceOf(address(this))`;
   `refund = min(budget, available)`; transfer it to `msg.sender` if it clears
   `DUST_THRESHOLD`; `totalPaid = paymentAmount - refund`. This is a refund of
   the caller's UNSPENT BUDGET, **not** a balance sweep. `available` is now
   **belt-and-braces**: with `budget` measured at step 5 it is non-binding on
   every constructible path, and it is retained only so that an unforeseen
   shortfall degrades into a smaller refund rather than a revert. It can lower
   the refund, never raise it, and is never its source. It is emphatically not
   the fee-on-transfer defence — capping at the balance still lets the refund
   reach past the caller's credit and into `P`; only measuring the credit
   stops that.
10. **Payout pass**: for each `i` with `snapshot[i] != 0`,
    `safeTransfer(recipient, snapshot[i])` and emit `NudgePaid`.

**Steps 9 and 10 were swapped in story 029** (the refund used to be step 10 and
the payout step 9). The refund must precede the payout so that a payout can
never be funded out of a refund that is owed, and vice versa. Two ordering
constraints now hold `batchMint` up — snapshot-before-pull and
refund-before-payout — where there used to be one.

## 4. Invariants and the reasoning behind them

### 4.1 The payment token MAY be a reward token — refund path safe by construction (story 029)

> **Rewritten in story 029.** This section previously asserted a two-part
> "payment-token exclusion": an admin-time revert plus a runtime SKIP in the
> snapshot loop, and it listed "two distinct failures the pair prevents". The
> second of those — *perturbing the snapshot/refund accounting* — was
> **affirmatively false**, and yield-claim-nft submission `ycn19h1` (CONDITIONAL
> High) proved it: skipping the entry kept the payment token out of the
> **payout** but not out of the step-10 **balance sweep**, so the entire nudge
> pot left to any `count = 1` caller who paid one wei. 190 USDC out of a 200
> USDC pot, repeatable on every refill. That claim, and the list containing it,
> are deleted rather than qualified.

**The construct is now permitted, not forbidden. The refund path is safe by
construction; the payout path is governed by the funding policy in §1, not by a
code bound.** The mechanism is a swap of the refund's *source of truth*, plus a
bound on the minter's allowance. Story 029 established exactly those two
properties — `refund <= budget <= paymentAmount`, and the minter's allowance
held at each mint's exact price — and nothing wider. Read "safe by construction"
in this section as scoped to them.

**Why the old design could not be patched by reordering.** `batchMint` already
snapshotted before it pulled, so the *snapshot* was clean. The defect was the
refund: derived from `paymentToken.balanceOf(address(this))`, a single number
that after the mint loop conflates three pools no reordering can separate after
the fact.

| pool | belongs to | size |
|---|---|---|
| `P` — the standing nudge pot | the next qualifying batch | streamer-fed, unbounded |
| `A − C` — unspent caller budget | `msg.sender` | ≤ `paymentAmount` |
| `D` — this batch's own donations | the *next* claimant (§4.2) | per-batch |

Handing back `P + (A − C) + D` as "residual" is the whole bug.

**The two changes.**

1. **Budget tracking (steps 5-7).** `budget` starts at what the step-5 pull
   actually credited — `min(balance delta over that one transfer,
   paymentAmount)` — and is decremented by the authoritative price the minter is
   about to charge. It is the ONLY source of the refund. It never observes the
   pot and never observes this batch's own donations. Measuring the credit
   rather than trusting `paymentAmount` is what makes the pot-integrity claim
   below hold for a fee-on-transfer payment token instead of merely for a
   well-behaved one; the `min` is what stops the same measurement crediting the
   caller with someone else's mid-transfer donation.
2. **Absolute per-mint allowance.** The minter is approved for the EXACT price
   of the single mint it is about to make, re-asserted absolutely every
   iteration, instead of `type(uint256).max` for the whole loop. An under-funded
   batch can no longer top itself up out of the contract's balance; it reverts
   `BatchMint__PaymentBudgetExhausted`.

**Why it holds.** With `P`, `A`, `C`, `D` as above:

| step | payment-token balance |
|---|---|
| after flush + snapshot (`P` captured) | `P` |
| after pull of `A`, crediting `A'` | `P + A'` |
| after loop | `P + A' − C + D` |
| after refund of `A' − C` (step 9) | `P + D` |
| after payout of `P` (step 10, qualifying) | `D` |

`A'` is the **credited** amount, `A' ≤ A`, and `budget = A'`. For an ordinary
ERC20 `A' = A` and the table reads exactly as before. The distinction only
becomes visible for a token that skims its own transfers — and there it is the
whole ballgame, because refunding `A − C` out of a balance holding `A' − C` of
the caller's money takes the difference from `P`.

- **Solvency** — the refund needs `A' − C`; the balance holds
  `P + A' − C + D ≥ A' − C`. Always solvent.
- **Pot integrity** — `refund ≤ budget = A' ≤ A`. The pot can never leave through the
  refund, for any `count`, any `nudgeSize`, any dispatcher index. `totalPaid`
  consequently loses its `paymentAmount > remaining ? … : 0` floor guard:
  `paymentAmount - refund` is unconditionally safe now, and the guard's absence
  is the visible marker that the property holds. **Do not reinstate it.**
- **`ycn19h1` is dead** — `count = 1` does not qualify, so the snapshot is `0`
  and nothing is paid; the refund is `A − C`; the pot is untouched. The one-wei
  call reverts `BatchMint__PaymentBudgetExhausted(0, price, 1)`.
- **Donate-forward survives** — `D` arrives after the snapshot and is not part of
  `budget`, so it stays behind for the next claimant. Unchanged for the payment
  token and for every other whitelisted token.
- **No self-funding** — `A` arrives after the snapshot, so it can never be paid
  back to the caller as a reward.

**Consequences accepted.**

- The **runtime skip is gone.** The payment token is snapshotted, floor-checked
  and paid out like any other whitelisted token. Its `minRewards[i]` floor is
  now **live** instead of silently ignored — a strict improvement.
- The **admin-time revert is retained as defence in depth only.**
  `setNudgeTokenWhitelist` still refuses the current derived payment token, so
  the collision cannot be created by a single whitelist call; but it can be
  reached by repointing `tokenMinter`/`dispatcherIndex`, and `batchMint` is safe
  when it is. The check may be removed in a later release with no change to any
  guarantee here.
- **Gas.** One `configs` staticcall plus one `forceApprove` SSTORE per mint,
  replacing two SSTOREs per batch. Deliberate: this contract is a convenience
  wrapper, not a hot path, and the cost buys token-behaviour independence.
- **Under-quoting front-ends now revert loudly** rather than drawing silently on
  the contract's balance. This is the intended regression, and the reason
  `BatchMint__PaymentBudgetExhausted` carries the mint index, the price and the
  remaining budget.
- **Same-denomination arbitrage is accepted** (owner decision, 2026-07-25). Once
  cost and reward share a denomination, `pot > Σ(nudgeSize mint prices)` is
  arithmetic any bot can do in one `eth_call`. That is intended, but **not**
  because any code bound keeps the pot under the cost — none does (see §1). It
  is accepted because the pot is funded from externally-derived yield rather
  than from principal or user deposits, so a pot that outruns the cost is an
  opportunity cost and deliberate marketing spend, not a value leak; and because
  `NudgeStreamer` meters release, so the market discovers a clearing price
  against the pot instead of racing a lump sum. Making the comparison legible
  does not change the economics.

**Sub-threshold dust.** Payment-token residue below `DUST_THRESHOLD`, and any
third-party donation of payment token, are no longer swept to the next caller.
They are not that caller's budget, so they stay behind as pot — which is the
correct owner for them, and which is what the `DUST_THRESHOLD` floor was
achieving in spirit all along.

### 4.2 Snapshot BEFORE the mint loop — LOAD-BEARING, DO NOT "SIMPLIFY"

> **Story 029: the substance of this section is UNCHANGED.** Donate-forward
> works exactly as it always did, and it now works for the payment token too —
> `D` arrives after the snapshot, is not part of `budget`, and is therefore
> neither refunded to the batcher nor paid to `recipient`. The only edits below
> are step renumbering (the payout is step 10, not step 9) and the note that the
> property is pinned for the colliding token as well, by
> `test_OwnDonationsDoNotRefundToBatcher_paymentTokenArm`. Nothing about the
> mechanism, the ordering constraint or the reasoning changed.

Balances are read in step 4 and paid out in step 10. The gap is the mint loop.

The dispatcher donates reward token into this contract on every mint. Reading
balances *before* the loop means the batcher is paid only the **prior
accumulated pot**; the donations generated by their own batch stay behind to
seed the next claimant. This is the "donate forward" mechanic, and it is the
only thing preventing a caller from **funding their own reward within a single
transaction** — a post-loop read would refund a batch's own donations straight
back to the batcher, collapsing the incentive to a no-op round-trip.

This is a trap for future refactors: reading the balance immediately before the
transfer looks obviously cleaner and is silently wrong. The implementation must
carry a comment saying so at both the snapshot site and the payout site, and
the property must be pinned by a dedicated test
(`test_OwnDonationsDoNotRefundToBatcher`) whose failure message names this
section.

### 4.3 Reentrancy guard — retained

Whitelisted nudge tokens are addresses the contract calls twice (`balanceOf`,
`transfer`). Under story 025 they are owner-vetted rather than caller-chosen,
which shrinks the surface from "arbitrary attacker code on every call" to "a
mistakenly whitelisted malicious or compromised token" — but the payout pass
is still an external-code hook, and an owner mistake must fail closed rather
than interleave.

The nested frame would re-snapshot balances the outer frame has already claimed
title to. In the current code shape that happens to fail closed (the outer
`safeTransfer` reverts on insufficient balance), but that is an accident of
ordering and of non-zero minimums, not a designed property.

Keep OpenZeppelin `ReentrancyGuard` (the non-transient variant, matching
`NFTStaker`) with `nonReentrant` on `batchMint`. Cheap, and it removes the
need to reason about the interleaving at all.

`ReentrancyGuardTransient` is present in `lib/immutable/openzeppelin-contracts`
and would cost ~200 gas instead of ~2-3k, but it requires solc >= 0.8.24 with
`evm_version = cancun` and this module is pinned to `0.8.20` in `foundry.toml`.
Not worth bumping the pragma for 2k gas (see §8).

### 4.4 Fee-on-transfer / rebasing tokens — documented, not defended

`minRewards[i]` is checked against the **pre-transfer snapshot**, not against
what `recipient` actually receives. For a fee-on-transfer or negatively-rebasing
token the recipient lands below the floor they declared.

Decision: **do not defend against this in code.** Measuring delivered amounts
(balance-delta on `recipient`) costs two extra `balanceOf` calls per token on
every batch to serve an asset class the protocol does not use. Instead:

- state it explicitly in the `batchMint` NatSpec, in the caller's own terms:
  *"`minRewards` is a floor on the contract's pre-transfer balance, not on the
  amount `recipient` receives. For fee-on-transfer or rebasing tokens the
  delivered amount will be lower. Whitelisting such a token is at the owner's
  discretion."*
- the official UI will not list known fee-on-transfer tokens, and the owner
  should not whitelist them.

Sophisticated callers read the source and decide whether the tax is worth it.

### 4.5 Duplicates are structurally impossible; weird tokens are the owner's problem

Story 025 dissolves most of the old "malformed arrays" surface: the caller no
longer supplies token addresses at all, only `minRewards`, and the only
remaining caller-side validation is length equality against the whitelist.

- **Duplicates** (audit-21 M-02): the whitelist is a set —
  `setNudgeTokenWhitelist` reverts `BatchMint__NudgeTokenAlreadyWhitelisted`
  on a re-add — so duplicate reward entries cannot exist by construction. The
  story-022 fail-closed-duplicate behaviour (and story-024's proposed O(n²)
  dedupe scan) are both obsolete; no per-call scan runs.
- **Long lists**: whitelist growth is owner-gated; snapshot/payout gas is
  O(whitelist length) and paid by the caller, who opted in by qualifying.
- **Non-ERC20 / reverting addresses**: an owner who whitelists one bricks the
  qualifying path until it is unwhitelisted (`balanceOf` reverts roll the
  batch back). Whitelist curation is an owner responsibility — the same trust
  class as `tokenMinter` itself.
- **Wrong `minRewards` ordering**: the caller's problem, bounded by the floor
  semantics — at worst the batch reverts on a floor breach or the caller
  accepts a smaller floor than intended. Re-fetch `getNudgeTokens()` before
  every call (swap-and-pop reorders).

### 4.6 Preserved from the current contract

- Eligibility remains a pure `count >= nudgeSize` test against the
  owner-pinned minter and dispatcher, so qualifying still costs `nudgeSize`
  real mints at the ramping price (the drain vector closed by pinning
  `tokenMinter` stays closed).
- Whole-batch atomic rollback on a floor breach.
- `DUST_THRESHOLD` semantics and the `totalPaid` return value. (Story 029
  changed the refund's SOURCE from a balance sweep to the caller's tracked
  budget, and `totalPaid` lost its `>` floor guard as a result — see §4.1 — but
  the threshold behaviour and the meaning of `totalPaid` are unchanged.)
- `whenNotPaused` on `batchMint` only; setters and `rescueERC20` stay callable
  while paused.

## 5. MEV posture — unchanged, and deliberately so

This change does not alter the winner-take-all structure. Whoever qualifies
first takes the entire balance of every token they list. `minRewards` protects
the *loser* (they don't pay mint costs for a pot that was sniped) but does
nothing to help them *win*.

That is acceptable precisely because of §1: winning requires paying more into
the protocol than the pot is worth. Bot competition here is a subsidy to the
protocol, not an extraction from it. Per-mint accrual accounting would be the
fix if fairness among claimants ever became a goal; it is explicitly out of
scope.

## 6. Test plan (TDD — red first)

New file `test/BatchNFTMinterMultiTokenNudge.t.sol`. The two original suites were
copied to `test/BatchNFTMinterMultiTokenNudgeCore.t.sol` and
`test/BatchNFTMinterMultiTokenCore.t.sol` and ported to the new signature
(the latter needing only mechanical call-site updates — empty arrays);
`test/BatchNFTMinterNudge.t.sol` and `test/BatchNFTMinter.t.sol` remain as the
regression suites for the frozen deployed contract.

Mocks needed beyond the existing set: `MockFeeOnTransferERC20`,
`MockReentrantERC20` (reenters `batchMint` from `transfer`).

> **Story 025 note:** the plan below is the historical story-022 test plan
> for the caller-selected model. Story 025 re-targeted the suites to the
> whitelist API: the payment-token exclusion tests became whitelist-admin
> reverts plus runtime-skip tests (**story 029 in turn replaced the runtime-skip
> tests with the payment-token-as-nudge-token suite — see §4.1 — and added
> `test/PoC_PaymentTokenCollision.t.sol`,
> `test/BatchNFTMinterMultiTokenBudget.t.sol` and
> `test/BatchNFTMinterMultiTokenBudgetInvariant.t.sol`**),
> `test_DuplicateRewardTokenFailsClosed`
> became `test_DuplicateNudgeTokensStructurallyImpossible` (duplicates now
> revert at admin time), "empty arrays" became "empty whitelist", and a full
> `setNudgeTokenWhitelist` admin suite (add/remove/swap-and-pop
> reorder/re-add/zero-address/already-whitelisted/not-whitelisted/
> payment-token/unconfigured-path/non-owner/while-paused) was added in
> `BatchNFTMinterMultiTokenNudgeCore.t.sol`, along with
> `test_MinRewardsOrderTracksGetNudgeTokens` for ordering correspondence.

Payment-token exclusion
1. `test_RevertWhen_RewardTokenIsPaymentToken` — single element.
2. `test_RevertWhen_RewardTokenIsPaymentTokenAmongOthers` — third of three.
3. `test_RevertWhen_RewardTokenIsPaymentToken_EvenWhenNotQualifying` —
   `count < nudgeSize`; must still revert.
4. `test_PaymentTokenDustNotClaimableAsReward` — leave sub-threshold dust, prove
   it survives a batch and is swept normally.

Snapshot-before-loop (§4.2)
5. `test_OwnDonationsDoNotRefundToBatcher` — dispatcher donates during the loop;
   assert payout == pre-loop balance exactly and the donation remains.
6. `test_SecondBatcherReceivesFirstBatchersDonations` — two sequential batches.

Reentrancy
7. `test_RevertWhen_RewardTokenReentersBatchMint`.

Multi-token payout
8. `test_PaysAllRequestedTokens` — USDC + WBTC, both balances delivered.
9. `test_PaysOnlyRequestedTokens` — a third token on the contract is untouched.
10. `test_EmptyArraysMintWithoutReward`.
11. `test_ZeroBalanceTokenIsNoOp` — listed, empty, `min == 0`, no transfer/event.
12. `test_EmitsNudgePaidPerToken`.

Floors
13. `test_RevertWhen_AnyMinRewardExceedsBalance` — first / middle / last.
14. `test_ZeroMinRewardsNeverRevert`.
15. `test_FloorCheckedBeforePaymentPull` — assert caller's payment-token balance
    is untouched on revert.
16. `test_RevertWhen_ArrayLengthMismatch`.

Eligibility
17. `test_NoRewardWhenCountBelowNudgeSize` — arrays supplied, nothing paid.
18. `test_NoRewardWhenNudgeSizeZero`.

Documented-behaviour witnesses (these encode §4.4/§4.5 so a future change that
"fixes" them fails loudly and forces a docs update)
19. `test_FeeOnTransferDeliversBelowMinReward`.
20. `test_DuplicateRewardTokenFailsClosed`.

Fuzz
21. `testFuzz_TotalPaidAccounting` — arbitrary `count`, `paymentAmount`, and
    reward-array shape; assert the §4.6 sweep/`totalPaid` invariant holds.

## 7. Implementation order

1. Port existing tests to the new signature (red).
2. Write the new test file (red).
3. Implement: remove `nudgePaymentToken` state + setter, add `ReentrancyGuard`,
   restructure `batchMint` per §3.
4. Write the NatSpec — §4.1, §4.2, §4.4, §4.5 and the "tokens sent here may be
   claimed by anyone" warning are all contract-level comments, not just doc
   material. Re-frame `rescueERC20`'s docstring per §1.
5. `forge fmt`, full `forge test`, gas snapshot diff (see §8 for what the diff
   should look like).
6. Update `CLAUDE.md` if the nudge is described there.

## 8. Gas

The payout path becomes **O(n)** in the whitelist length, where the frozen
contract is O(1). That is inherent to paying out n tokens. The one shape that
would have made it O(n²) — a dedupe pass — is ruled out in §4.5 (story 025:
by set construction rather than by policy).

### Per reward token

| Cost | Gas |
| --- | --- |
| `balanceOf` staticcall (cold account + cold slot) | ~5k |
| `safeTransfer` — token account already warmed by the snapshot; recipient slot zero -> nonzero | ~25k |
| ... same, recipient already holds the token (nonzero -> nonzero) | ~8k |
| `NudgePaid` event | ~2k |
| calldata, one `address` + one `uint256` | ~0.5k |
| memory for the snapshot array | negligible below ~700 words |

**~30k first-time, ~15k warm, per token.** The transfer dominates and is
irreducible — that is simply what moving an ERC20 costs.

### Why this does not matter in practice

The relevant comparison is the mint loop that a qualifying caller has already
committed to. Rewards only pay out when `count >= nudgeSize`, and each
`ITokenMinterV2.mint` is an ERC1155 mint plus a dispatcher price-ramp SSTORE
plus a payment transfer — on the order of 100k gas. With `nudgeSize = 5` the
batch is already >= ~500k gas before any reward logic runs, so two or three
reward tokens is single-digit-percent noise. A caller who lists twenty tokens
pays ~600k of rewards overhead on top of a multi-million-gas batch, out of their
own pocket, having opted in explicitly (§4.5).

### Three properties worth preserving

1. **The empty-array path is free.** One length comparison and a zero-iteration
   loop. Callers who want no reward pay nothing for the feature, which is what
   keeps the `BatchNFTMinterMultiTokenCore.t.sol` port mechanical.
2. **The revert path gets cheaper than today's.** Moving the floor check ahead
   of the payment pull (§3 step 4) means a breached floor aborts before
   `safeTransferFrom` and before `count` mints, rather than after both.
3. **`nonReentrant` is the only unconditional new cost** — ~2-3k on every
   `batchMint`, paid even by empty-array callers. Accepted; see §4.3 for why the
   transient variant is not an option at solc 0.8.20.

### Acceptance check

Take a `forge snapshot` before the change and diff after. Expected shape:

- existing single-token nudge cases: **+2-3k** (the guard) and otherwise flat;
- no-reward cases: **+2-3k**, no other movement;
- new multi-token cases: **~+30k per additional token**, roughly linear.

A superlinear trend across increasing array lengths means a dedupe or nested
loop crept in — treat that as a bug against §4.5, not as a tuning problem.
