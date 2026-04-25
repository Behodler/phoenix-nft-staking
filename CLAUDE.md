# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Submodule: NFTStaking

Foundry submodule implementing a masterchef-style staking pool for NFTs minted via the `yield-claim-nft` sibling. Stakers deposit ERC1155 units of the BalancerPooler NFT and earn per-second emissions of phUSD. The reward budget is refilled by invoking `pull()` on the `BalancerPoolerMintDebtHook` dispatcher hook in `yield-claim-nft`, which realises accrued mint-debt as freshly-minted phUSD directed at this staking contract (which must be set as the hook's `recipient`).

This submodule is part of the Phoenix ecosystem; see `../phase-2-staging` for end-to-end integration context and `../yield-claim-nft` for the NFT and dispatcher/hook it depends on.

### Parent Repo Conventions (apply before any code is written)

- Follow the submodule + dependency rules in `../CLAUDE.md`. Mutable siblings (`lib/mutable/`) expose **interfaces only** — never reach into implementations. Cross-submodule changes go through the `MutableChangeRequests.json` flow, after which development must stop and wait for the user.
- Use OpenZeppelin for anything standard (`Ownable`, `Pausable`, `ReentrancyGuard`, ERC1155 receiver, `SafeERC20`). See `../solidity-standards-dependency.md`. Custom reimplementations are prohibited.
- All work is TDD: red → green → refactor, using Foundry only. No Hardhat/Truffle.
- Solidity `^0.8.20`, matching the sibling modules.

### Expected Dependencies

Once scaffolded, this submodule is expected to pull in:

- **Immutable**: `openzeppelin-contracts` (for `Ownable`, `Pausable`, `ReentrancyGuard`, ERC1155 holder, `SafeERC20`, `IERC1155`, `IERC20`).
- **Mutable**: `yield-claim-nft` (for the dispatcher/hook interface exposing `pull()` — implementation lives at `src/V2/hooks/BalancerPoolerMintDebtHook.sol`) and `pauser` (for `IPausable` / `IPauser` to integrate with the global pauser).

This submodule was not bootstrapped with the parent repo's `.claude/scripts/` scaffolding. Wire dependencies manually as needed (git submodule add into `lib/immutable/` or `lib/mutable/`, then update `foundry.toml` remappings — see a sibling like `yield-claim-nft/foundry.toml` for the remapping pattern).

**Keep `remappings.txt` in sync with `foundry.toml`.** The VSCode Solidity extension doesn't read `foundry.toml`, so a checked-in `remappings.txt` at the submodule root is what drives editor import resolution. Whenever you add, remove, or edit a remapping in `foundry.toml`, regenerate it with `forge remappings > remappings.txt` and commit both files together. Out-of-sync files surface as spurious "Source ... not found: File import callback not supported" lints even though `forge build` succeeds.

### Feature Specification (implementation checklist)

Treat the list below as the authoritative spec. When the user asks for a new feature, cross-reference this list and remind them of any items still outstanding.

The emission model is the **variable-runway / owner-set APY target** — the owner configures a target APY for the average NFT, the contract computes the per-second emission rate `R = T * A / SECONDS_PER_YEAR` from the live aggregate NFT value `T`, and runway (`V / R` seconds) becomes a derived quantity. Full design rationale and math derivation live in `scratchpad/planning-docs/phoenix/phase2/nft-staking/variable-runway.md` (in the product-owner repo).

1. **Single-ID ERC1155 staking, one staker contract per NFT at a time**: Stake/unstake units of a configured ERC1155 token ID (initially the BalancerPooler NFT). The ERC1155 contract address is an immutable constructor arg; the token ID is owner-settable via `setStakedId` but **only while `totalStaked == 0`** — this accommodates `NFTMinter` reconfiguration (e.g. a Balancer pool migration that reissues the NFT under a new ID) without stranding user principal. No in-contract whitelist, no per-ID mapping, no allocation-point math — a single active ID at any moment.

   Pair the mutable ID with a standard masterchef `emergencyWithdraw()` that returns principal, forfeits pending reward, skips `_syncBudget`/`_updatePool`, and is callable while paused. This is the escape hatch that keeps an ID-change migration from deadlocking on unresponsive stakers and prevents principal from being trapped if the dispatcher hook, NFT minter, or recompute path is ever broken.
2. **Masterchef-style per-second emissions in phUSD**: Track `accRewardPerShare` scaled by a precision constant, `lastRewardTime`, and per-user `rewardDebt`, updated on every interaction. "Share" unit is NFT units staked (ERC1155 balances), not ERC20 wei.
3. **APY-driven emission rate**: `rewardRate = S * targetAPY / SECONDS_PER_YEAR` where `S = totalStaked * latestPrice` is the notional of the *staked subset* of NFTs valued at the most recent mint price. `latestPrice = price / r` with `r = 1 + growthBasisPoints/10_000` (where `price` from `nftMinter.configs(dispatcherIndex)` is the *next* mint price, so dividing by `r` recovers the most-recent paid price); `growthBasisPoints == 0` collapses `latestPrice` to `price` directly. Computed via OZ `Math.mulDiv` with floor rounding (conservative for a reward contract). Edge cases: `totalStaked == 0 || targetAPY == 0 || price == 0` → `R = 0`. Sizing the rate against the staked subset (rather than aggregate minted notional) is what closes audit M-03: per-NFT effective APY no longer scales with `N / totalStaked`, and runway is exactly `V / R`. See `scratchpad/planning-docs/phoenix/phase2/nft-staking/audit-05/M-03-submission.md`.
4. **Variable runway as derived quantity**: `V = balance + mintDebt` (balance plus pending phUSD at the dispatcher hook). `windowEnd = now + V / R` at the most recent recompute. Runway grows with V and shrinks as emissions drain the budget.
5. **Pull-on-interaction**: Every stake / unstake / claim call first invokes `_syncBudget`, which calls `pull()` on the configured dispatcher hook (if set) to sweep any outstanding mint debt, then recomputes the schedule.
6. **Recompute triggers**: `_recomputeSchedule` fires from `_syncBudget` (and thus user actions), `topUp`, `setTargetAPY`, `setDispatcherIndex`, `setNFTMinter`, and `pullAndRefresh`. Setters that could swing the math violently (`setDispatcherIndex`, `setNFTMinter`, `setStakedId`) are gated on `totalStaked == 0`.
7. **Owner setters**:
   - `setTargetAPY(uint256)`: bounded `0 <= A <= MAX_TARGET_APY (0.5e18)`; `A == 0` is a supported "pause emissions via APY" mode. Settles accrual at the OLD rate before mutating.
   - `setDispatcherIndex(uint256)`: only while `totalStaked == 0`; triggers a recompute.
   - `setNFTMinter(INFTSupply)`: only while `totalStaked == 0`; triggers a recompute.
   - `setDispatcherHook(IBalancerPoolerMintDebtHook)`: no empty-pool guard (hook rotation is a live operation).
   - `topUp(uint256)`: `onlyOwner`, non-zero amount; does NOT call `_syncBudget`, preserving dispatcher-hook-independence.
   - `pullAndRefresh()`: manual trigger of `_syncBudget`.
   - `setStakedId(uint256)`: only while `totalStaked == 0`.
8. **Pausable via global Pauser**: Implement `IPausable` (from the `pauser` submodule). `pause()`/`unpause()` must be callable only by the registered pauser address; all user-facing state-changing functions (stake/unstake/claim) must be `whenNotPaused`. `emergencyWithdraw` explicitly stays callable while paused.
9. **Ownable**: Inherit OpenZeppelin `Ownable` with an `initialOwner` constructor argument.
10. **Events and view functions**: Emit `Staked`, `Unstaked`, `Claimed`, `EmergencyWithdrawn`, `Pulled(inflow, newBudget)`, `ToppedUp(from, amount, newBudget)`, `ScheduleRecomputed(S, budget, newRate, newWindowEnd)` (first field is `S = totalStaked * latestPrice`, the staked-subset notional; second field is `budget = V - committedDebt`; the on-chain field name `totalNFTValue` is preserved for off-chain consumer compatibility but its meaning shifted in audit M-03 from aggregate `T` to staked-subset `S`), `TargetAPYChanged`, `DispatcherIndexChanged`, `NFTMinterChanged`, `DispatcherHookChanged`, `StakedIdChanged`, `PauserChanged`. Expose `pendingReward(user)`, `currentRewardRate()`, `totalDebt()`, `totalBudget()`, `runwaySeconds()`.

### Critical Invariants to Preserve in Tests

- **APY stability under repeated pulls/top-ups within a block**: `R = S * A / SECONDS_PER_YEAR` depends only on on-chain state (`nftMinter.configs(dispatcherIndex).price/growthBasisPoints`, `totalStaked`, `targetAPY`), not on inflow cadence or size. Calling `pullAndRefresh()` or `topUp(small)` with unchanged `totalStaked`, `latestPrice`, and `A` must leave `rewardRate` unchanged.
- **Runway = V / R**: After every recompute, `windowEnd = block.timestamp + V / rewardRate` (with floor division).
- **APY-as-floor for latest minter**: With `R = totalStaked * latestPrice * targetAPY / SECONDS_PER_YEAR`, per-NFT emissions are `latestPrice * targetAPY / SECONDS_PER_YEAR`. The most-recent minter (who paid `latestPrice`) earns exactly `targetAPY`. Earlier minters paid `latestPrice / r^k` for some `k > 0` and earn `targetAPY * r^k > targetAPY`. With `growthBasisPoints == 0` every staker earns exactly `targetAPY`. **There is no participation multiplier** — a lone staker earns `targetAPY` (or the geometric-growth multiple), not `N * targetAPY`. (See `NFTStakerSustainability.t.sol::test_M03_LowParticipationDoesNotInflateAPY`.)
- **Late stakers never get retroactive rewards**: `accRewardPerShare` advances only between `lastRewardTime` and `block.timestamp`, scaled by current emission rate.
- **Emissions stop cleanly at `windowEnd`**: `_updatePool` caps `elapsed` at `min(now, windowEnd) - lastRewardTime`. A recompute that pushes `windowEnd` forward after depletion is not retroactive — prior accrual is settled first.
- **APY-decrease settles old accrual at the OLD rate**: `setTargetAPY(newAPY)` calls `_updatePool()` before mutating `targetAPY`, so stakers are paid what they earned under the prior policy.
- **`stake` and `unstake` re-size `R` against the new `totalStaked`**: `R` scales linearly with `totalStaked`, so both functions invoke `_recomputeSchedule()` *after* the `totalStaked` mutation (in addition to the head-of-function `_syncBudget` recompute, which runs at the OLD `totalStaked` to settle accrual at the OLD rate). `claim` does not need the tail recompute — `totalStaked` is unchanged.
- **`setDispatcherIndex` / `setNFTMinter` / `setStakedId` only while `totalStaked == 0`**: prevents a mid-stake reconfiguration from swinging the APY math.
- **Cross-staker isolation**: within a single staker there is only one active token ID, so within-contract cross-ID leakage is structurally impossible.
- **ID change never strands principal**: `setStakedId` reverts unless `totalStaked == 0`. `emergencyWithdraw` works while paused and without touching `_syncBudget`/`_updatePool`, so migration is never blocked by a broken dispatcher hook, NFT minter, or recompute.
- **Solvency (always)**: `balance == rewardBudget + committedDebt` holds at *all* times. `_updatePool` moves accrual from `rewardBudget` to `committedDebt`; `_safePay` decrements `committedDebt` and `balance` by the same amount (with a wei-level dust escape into `rewardBudget` when per-user `pending` floor-rounding marginally exceeds cumulative `_updatePool` increments); `_recomputeSchedule` resizes `rewardBudget` to `V - committedDebt` where `V = balance + mintDebt`; `topUp` increases `balance` and (via `_recomputeSchedule`) `rewardBudget` by the same amount; `pull()` swaps `mintDebt` for `balance` 1:1 and is invariant-neutral; `emergencyWithdraw` moves the exiting user's pending out of `committedDebt` and into `rewardBudget` (the forfeited phUSD stays in balance and recycles into runway). `_safePay` reverts on any shortfall rather than silently capping payouts — so the contract never pays out more than `balance` and earned rewards are never silently forfeited.

## Dependency Management

### Types of Dependencies

1. **Immutable Dependencies** (`lib/immutable/`)
   - External libraries with full source available.
   - Examples: OpenZeppelin.

2. **Mutable Dependencies** (`lib/mutable/`)
   - Sibling submodules. Only interfaces / abstract contracts are exposed; **never** access implementation details.
   - Changes require the change-request process below.

### Cross-Submodule Changes

If a feature needs a sibling's interface to change, stop work and tell the user — they'll make the edit in the sibling submodule directly. No `MutableChangeRequests.json` / script-driven flow in this submodule.

## Foundry Commands

- `forge build` — compile.
- `forge test` / `forge test -vvv` — run tests (verbose).
- `forge test --match-contract <ContractName>` — single contract.
- `forge test --match-test <testName>` — single test.
- `forge coverage` — coverage report.
- `forge fmt` — format.
- `forge snapshot` — gas snapshots.

## Project Structure (to be created)

- `src/` — Solidity source.
- `test/` — Foundry tests (TDD).
- `script/` — deployment scripts.
- `lib/mutable/` — sibling interfaces (`yield-claim-nft`, `pauser`).
- `lib/immutable/` — OpenZeppelin etc.
