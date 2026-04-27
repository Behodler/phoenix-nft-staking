# NFTStaker — Design & Implementation Plan

## Scope

Masterchef-style staking pool for units of a **single ERC1155 token ID at a
time** (initially the BalancerPooler NFT from `yield-claim-nft`). Stakers earn
per-second emissions of phUSD funded by `pull()`-ing realised mint-debt from
`BalancerPoolerMintDebtHook` (configured with this contract as `recipient`),
plus any owner top-ups.

**One staker contract per NFT at a time.** The ERC1155 contract is fixed at
construction; the token ID is owner-settable to accommodate `NFTMinter`
reconfiguration (e.g. a Balancer pool migration that reissues the NFT under a
new ID). Changing the ID is only safe when no user holds a stake (see "Changing
stakedId" below). If concurrent staking against two different NFTs is ever
required, deploy a second `NFTStaker` — the "how do multiple stakers share one
dispatcher hook" question is deferred and can be answered with a fan-out
splitter contract or a multi-recipient hook change in `yield-claim-nft` when
the need arises.

Dependencies: OpenZeppelin (`Ownable`, `Pausable`, `ReentrancyGuard`,
`ERC1155Holder`, `SafeERC20`, `IERC1155`, `IERC20`), `pauser/IPausable`,
`yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook`.

## Core decisions (resolved)

- **Single-ID, single-contract.** No `mapping(uint256 => PoolInfo)`, no
  `allocPoint`, no whitelist array. The NFT ID is a single storage slot; the
  ERC1155 contract address is immutable, the token ID is owner-settable but
  only while `totalStaked == 0`.
- **Masterchef, not ERC4626.** No mainstream "ERC4626 for ERC1155" standard
  exists, and more importantly 4626 assumes reward-denomination ==
  share-denomination. We deposit NFT units and pay phUSD — heterogeneous reward
  makes 4626 a poor fit. A transferable yield-bearing receipt (stkNFT) is a
  future composability feature, not a safety requirement.
- **One funded pot, one window.** phUSD from `pull()` (and from owner top-ups)
  funds a single emission schedule over `windowDuration` (default 540 days).

## Storage layout

```solidity
// Config set at construction (immutable)
IERC1155 public immutable stakedToken;
IERC20   public immutable rewardToken;      // phUSD

// Config set at construction but mutable (see "Changing stakedId" below)
uint256 public stakedId;

// Config set post-deploy (deployment ordering makes immutable awkward)
IBalancerPoolerMintDebtHook public dispatcherHook;
address public pauser;

// Window state
uint256 public windowDuration;              // default 540 days
uint256 public windowEnd;                   // timestamp schedule ends
uint256 public rewardRate;                  // phUSD per second
uint256 public rewardBudget;                // tracked remaining phUSD

// Accrual state
uint64  public lastRewardTime;
uint256 public totalStaked;                 // sum of ERC1155 units deposited
uint256 public accRewardPerShare;           // scaled by ACC_PRECISION

// Per-user position
struct UserInfo {
    uint256 amount;
    uint256 rewardDebt;
}
mapping(address => UserInfo) public users;

uint256 public constant ACC_PRECISION = 1e18;
uint256 public constant DEFAULT_WINDOW = 540 days;
uint256 public constant MIN_WINDOW = 1 days;
uint256 public constant MAX_WINDOW = 10 * 365 days;
```

## Public API

### User-facing (`whenNotPaused`, `nonReentrant`)

- `stake(uint256 amount)` — pull ERC1155 units of `stakedId`, sync budget,
  update pool, settle pending reward, adjust `rewardDebt`.
- `unstake(uint256 amount)` — inverse of stake.
- `claim()` — harvest without touching principal.

Every user call starts with `_syncBudget()` then `_updatePool()`.

### User-facing escape hatch (callable while paused, no `_syncBudget`)

- `emergencyWithdraw()` — returns the caller's full `amount` of `stakedId`
  ERC1155 units, zeros their `UserInfo`, decrements `totalStaked`. Does NOT
  call `_syncBudget` or `_updatePool` — any pending reward is **forfeited**.
  Still `nonReentrant`. Callable even when paused. Emits `EmergencyWithdrawn`.

  Purpose: (a) unblock an ID migration if stakers are slow to respond; (b)
  escape hatch if the dispatcher hook is ever broken and reverts on `pull()`,
  so user principal is never trapped. This is the standard masterchef pattern.

### Views

- `pendingReward(address user) returns (uint256)`
- `currentRewardRate() returns (uint256)` — 0 once `block.timestamp >= windowEnd`.

### Owner

- `setDispatcherHook(IBalancerPoolerMintDebtHook)` — initial wiring + rotation.
- `setPauser(address)` — already in scaffold.
- `setStakedId(uint256 newId)` — reverts unless `totalStaked == 0`. See
  "Changing stakedId" below. Emits `StakedIdChanged`.
- `setWindowDuration(uint256)` — bounded [MIN_WINDOW, MAX_WINDOW]; resets
  `windowEnd = now + newDuration` and recomputes `rewardRate` against
  `rewardBudget` after calling `_updatePool()` first.
- `topUp(uint256)` — `safeTransferFrom(owner, this, amount)`, folds into
  `rewardBudget`, resets window.
- `pullAndRefresh()` — explicit manual trigger of the inflow path (same as the
  implicit call at the top of every user action).

### Pauser

- `pause()` / `unpause()` — `onlyPauser`, already in scaffold.

### ERC1155 receiver

- Inherit `ERC1155Holder` from OpenZeppelin. Any transfer for an ID other than
  `stakedId` that arrives via the `stake()` path reverts (`stake` doesn't even
  ask for an ID — it calls `safeTransferFrom(msg.sender, this, stakedId, amount, "")`).
- Receiver itself stays permissive (default `ERC1155Holder` behavior) so the
  owner can recover accidentally-sent tokens via a future rescue function if
  desired — not in scope for v1.

## Funding / window mechanics

### `_syncBudget()` — called at the top of every user entrypoint + owner top-up

1. `_updatePool()` — bring `accRewardPerShare` and `lastRewardTime` up to now
   under the **current** `rewardRate`. This must happen before any rate/window
   mutation, otherwise elapsed-at-old-rate gets revalued at the new rate.
2. Snapshot `pre = rewardToken.balanceOf(address(this))`.
3. If `dispatcherHook != address(0)`: `dispatcherHook.pull()`. Reverts propagate.
4. `inflow = rewardToken.balanceOf(address(this)) - pre`.
5. If `inflow > 0`:
   - `rewardBudget += inflow`
   - `windowEnd = block.timestamp + windowDuration`
   - `rewardRate = rewardBudget / windowDuration`
   - emit `Pulled(inflow, rewardBudget, rewardRate, windowEnd)`
6. If `inflow == 0`: no-op — existing schedule continues untouched.

`topUp` and `setWindowDuration` reuse the same "update pool → mutate → recompute
rate" sequence. `setWindowDuration` doesn't change `rewardBudget` but resets the
timer and rate against the new duration.

### Changing `stakedId`

The ERC1155 contract address is immutable but the token ID is owner-settable to
handle `NFTMinter` reconfigurations (e.g. a Balancer pool migration that
reissues the staked NFT under a new ID).

The invariant is straightforward: **`setStakedId` reverts unless
`totalStaked == 0`.** Changing the ID while users hold positions would leave
the contract holding units of the old ID while `unstake` tries to transfer
units of the new ID — the latter would revert (zero balance of the new ID),
stranding user principal.

Operational flow for a migration:

1. Pauser pauses the contract (via global `Pauser`), halting new stakes.
2. Announce the migration; users call `unstake` (or `emergencyWithdraw` if
   the reward path is broken for any reason). `emergencyWithdraw` is reachable
   while paused.
3. Once `totalStaked == 0`, owner calls `setStakedId(newId)`.
4. Pauser unpauses; users stake the new ID.

This places the coordination cost on the operator (announce + wait + verify
`totalStaked == 0`) rather than embedding migration state in the contract.
`emergencyWithdraw` is what prevents a single unresponsive staker from
deadlocking the migration indefinitely — in practice, that user would
eventually be prompted by the frontend or another channel, but they can't
block the operator forever because the operator can always wait them out and
the stakers' principal is always individually withdrawable.

Note that accrued-but-unclaimed rewards against the old ID survive the change
(they're ERC20 phUSD, indifferent to `stakedId`), and any user who
`emergencyWithdraw`s forfeits them. Users who `unstake` normally before the
ID change collect their pending reward as usual.

### `_updatePool()`

```
if (block.timestamp <= lastRewardTime) return;
if (totalStaked == 0) { lastRewardTime = uint64(block.timestamp); return; }

uint256 end = block.timestamp < windowEnd ? block.timestamp : windowEnd;
uint256 elapsed = end > lastRewardTime ? end - lastRewardTime : 0;
uint256 reward = elapsed * rewardRate;
if (reward > rewardBudget) reward = rewardBudget;   // defensive clamp

rewardBudget -= reward;
accRewardPerShare += reward * ACC_PRECISION / totalStaked;
lastRewardTime = uint64(block.timestamp);
```

Notes:
- `rewardBudget` is the authoritative emission ledger — decremented on accrual,
  not on claim. On-chain phUSD balance will exceed `rewardBudget` by the sum
  of unclaimed pending rewards; expected.
- Clamp on `reward > rewardBudget` guarantees clean depletion under rounding.

## Events

```solidity
event Staked(address indexed user, uint256 amount);
event Unstaked(address indexed user, uint256 amount);
event Claimed(address indexed user, uint256 amount);
event EmergencyWithdrawn(address indexed user, uint256 amount);
event Pulled(uint256 inflow, uint256 newBudget, uint256 newRate, uint256 newWindowEnd);
event ToppedUp(address indexed from, uint256 amount, uint256 newBudget, uint256 newRate);
event WindowDurationChanged(uint256 previous, uint256 next);
event DispatcherHookChanged(address indexed previous, address indexed next);
event StakedIdChanged(uint256 previous, uint256 next);
event PauserChanged(address indexed previous, address indexed next); // already present
```

## Invariants (mapped to mechanics)

1. **No retroactive rewards** — `_updatePool` accrues only `now - lastRewardTime`
   at the current rate. A new staker's `rewardDebt` pins to the current
   `accRewardPerShare`.
2. **Clean depletion** — `rewardBudget` decremented on accrual + the
   `reward > rewardBudget` clamp means per-second rate × elapsed can never
   over-pay.
3. **Zero-inflow `pull()` is a no-op** — `inflow == 0` branch skips rate/window
   mutation entirely.
4. **Shrinking window can't inflate prior claims** — `setWindowDuration` calls
   `_updatePool()` first, so all prior emissions are already folded into
   `accRewardPerShare` at the old rate before any mutation.
5. **ID change never strands principal** — `setStakedId` reverts unless
   `totalStaked == 0`, so users always recover their deposit in the same ID
   they deposited. `emergencyWithdraw` guarantees this path works even if the
   dispatcher hook is broken.

## Test plan (TDD — red first)

### Fixtures

- Mock ERC1155 (OZ `ERC1155` subclass) for staked token.
- Mock ERC20 for phUSD (`ERC20` subclass with exposed `mint`).
- Mock `IBalancerPoolerMintDebtHook` with configurable mint amount on `pull()`.
- Deploy `NFTStaker(stakedToken, INITIAL_STAKED_ID, phUSD, owner)`, then
  `setPauser` and `setDispatcherHook` post-construction.

### `NFTStakerConfigTest`

- Constructor wires owner, staked token+ID, reward token.
- `setPauser` / `setDispatcherHook` / `setWindowDuration` / `setStakedId`
  are `onlyOwner`.
- `setWindowDuration` reverts outside [MIN_WINDOW, MAX_WINDOW]; emits event.
- Pauser / dispatcher / staked-ID changes emit events.

### `NFTStakerIdChangeTest`

- `setStakedId` succeeds while `totalStaked == 0`; updates storage and emits
  `StakedIdChanged`.
- `setStakedId` reverts while any user holds a stake (`totalStaked > 0`).
- After a successful ID change, `stake(amount)` pulls units of the new ID;
  attempting to transfer units of the old ID externally does not affect
  accounting.
- Full migration happy path: user stakes ID_A, warps, `unstake` returns
  ID_A units + phUSD reward; owner `setStakedId(ID_B)`; user stakes ID_B;
  subsequent accrual works on the new ID cleanly.
- Migration via `emergencyWithdraw`: user stakes ID_A, pause, user
  `emergencyWithdraw` returns ID_A units, pending reward is forfeited,
  owner sets new ID, unpause, new stakes work.

### `NFTStakerFundingTest`

- Nonzero `pull()`: `rewardBudget` increases by exact inflow;
  `windowEnd == now + windowDuration`; `rewardRate == rewardBudget / windowDuration`;
  `Pulled` emitted.
- Zero `pull()`: `windowEnd`, `rewardRate`, `rewardBudget` unchanged; no
  `Pulled` event.
- `topUp` has identical window-reset semantics and emits `ToppedUp`.
- `setWindowDuration` mid-window calls `_updatePool()` first; `accRewardPerShare`
  before and after the setter reflects old-rate accrual only; new rate applies
  strictly to future time.

### `NFTStakerAccrualTest`

- Stake at `t0`, warp `N` seconds, `pendingReward == rewardRate * N`.
- Claim transfers exactly pending, zeros pending.
- Two users stake equal amounts simultaneously: each gets half.
- User B joins halfway: A solo for first half, 50/50 for second half.
- Warp past `windowEnd`: emissions stop; pending caps at `windowEnd`.
- `rewardBudget` exhaustion: after total accrual == initial budget, warps
  don't grow pending further.

### `NFTStakerPullIntegrationTest`

- `stake()` with hook holding debt: implicit `pull()` lands new budget+rate
  *before* the staker's `rewardDebt` is set, so new budget doesn't retroactively
  reward existing stakers for the pre-pull elapsed time (that elapsed time
  accrued at the pre-pull rate — covered by the "update first, mutate second"
  ordering).
- `stake()` with zero hook debt: behaves like the pre-pull schedule (no rate
  change, no window reset).
- `pull()` mid-window while stakers hold positions: `accRewardPerShare`
  already advanced to `now` at old rate before the window reset.

### `NFTStakerPauseTest`

- `pause()` is `onlyPauser`; non-pauser reverts, owner alone cannot pause.
- Paused state blocks `stake`/`unstake`/`claim` with `Pausable: paused`.
- `emergencyWithdraw` remains callable while paused.
- Unpause restores normal operation.

### `NFTStakerEmergencyWithdrawTest`

- Returns full principal in a single ERC1155 transfer; zeros `UserInfo.amount`
  and `UserInfo.rewardDebt`; decrements `totalStaked`.
- Forfeits pending reward — user's phUSD balance unchanged, `rewardBudget`
  unchanged (no `_updatePool` called).
- Works when `dispatcherHook.pull()` would revert (mock hook set to revert):
  `emergencyWithdraw` must not call `_syncBudget`.
- Re-entrancy guard holds under a hostile ERC1155 `onERC1155Received`.

### `NFTStakerERC1155Test`

- `stake` with an ID other than `stakedId` isn't possible through the API
  (no ID param). Direct ERC1155 transfer of a foreign ID into the contract
  does not affect `totalStaked` or any user's balance (receiver accepts but
  accounting ignores it — it's just stuck tokens, recoverable via future
  rescue if we add one).

### Fuzz / invariant

- Fuzz `(amount, warp)` across 2–3 users; assert
  `sum(pendingReward) + sum(claimed) <= initial_budget` always.
- Optional invariant harness:
  `rewardBudget + sum_unclaimed_accrued == initial_budget - claimed_total`.

## Implementation phases

1. **Storage & events skeleton**: extend `src/NFTStaker.sol` (keeps existing
   pauser wiring) with immutables, window/accrual state, `UserInfo`, constants,
   constructor args; stub function bodies with `revert("not impl")`. Compiles.
2. **Funding math**: implement `_syncBudget`, `topUp`, `setWindowDuration`,
   `setDispatcherHook`, `pullAndRefresh`. Funding tests go green.
3. **Accrual math**: implement `_updatePool`, `pendingReward`, `stake`,
   `unstake`, `claim`. Accrual tests go green.
4. **Pull integration**: wire `_syncBudget()` calls into user entrypoints;
   integration tests go green.
5. **Receiver + safety**: inherit `ERC1155Holder` and `ReentrancyGuard`; add
   `nonReentrant` to stake/unstake/claim/emergencyWithdraw; pause tests go
   green.
6. **Migration path**: implement `setStakedId` (guarded by `totalStaked == 0`)
   and `emergencyWithdraw`; ID-change and emergency-withdraw tests go green.
7. **Fuzz/invariants**: add one fuzz harness for the depletion invariant.

## Deferred

- **Second NFT support.** If/when it happens: deploy a second `NFTStaker` and
  decide between (a) a fan-out splitter that sits between
  `BalancerPoolerMintDebtHook` and the stakers, or (b) a `yield-claim-nft`
  change allowing multiple recipients. Either is tractable; neither needs to
  be designed now.
- **Transferable stkNFT receipt.** Composability-only feature; adds attack
  surface without changing reward math. Not in scope.
- **Rescue for misrouted ERC1155 transfers.** Add if/when misrouting is
  observed in practice.
