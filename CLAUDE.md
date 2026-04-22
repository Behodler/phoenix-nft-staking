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

1. **ERC1155 multi-ID staking**: Stake/unstake units of a configured ERC1155 contract. Initially one token ID (the BalancerPooler NFT), but the design must allow the owner to whitelist additional IDs on the same ERC1155 contract later (not multiple ERC1155/ERC721 contracts). Per-ID accounting must support independent emission rates / share weighting if multiple IDs are active.
2. **Masterchef-style per-second emissions in phUSD**: Track `accRewardPerShare` scaled by a precision constant, `lastRewardTime`, and per-user `rewardDebt`, updated on every interaction. "Share" unit is NFT units staked (ERC1155 balances), not ERC20 wei.
3. **Depletion window**: Default 18 months (`540 days`). The remaining phUSD balance divided by remaining seconds in the window defines the per-second emission rate.
4. **Pull-on-interaction**: Every stake / unstake / claim call first invokes `pull()` on the configured dispatcher hook to sweep any outstanding mint-debt into this contract as phUSD.
5. **Window reset on inflow**: After `pull()` (or any owner top-up), if the contract's phUSD balance increased, reset the remaining window to the full configured depletion duration and recompute the per-second rate over the new balance. **If `pull()` produced zero new phUSD, do not reset** — emissions continue against the existing schedule.
6. **Owner-configurable window duration**: Setter that adjusts the depletion duration from the 18-month default to any (bounded-reasonable) value. Changing the duration resets the remaining time to the new full duration and recomputes the per-second rate against the current balance.
7. **Owner manual phUSD injection**: A function that lets the owner transfer phUSD into the contract as a top-up, which resets the window the same way a successful `pull()` does.
8. **Pausable via global Pauser**: Implement `IPausable` (from the `pauser` submodule). `pause()`/`unpause()` must be callable only by the registered pauser address; all user-facing state-changing functions (stake/unstake/claim) must be `whenNotPaused`. Follow the pattern used by `ATokenDispatcher` in `yield-claim-nft` — a `setPauser` owner-only setter and caller checks against it.
9. **Ownable**: Inherit OpenZeppelin `Ownable` with an `initialOwner` constructor argument (matches sibling pattern).
10. **Events and view functions**: At minimum emit on stake, unstake, claim, pull, top-up, window change, pauser change, token-ID whitelist change. Expose `pendingReward(user, id)` for frontends.

### Critical Invariants to Preserve in Tests

- Late stakers never get retroactive rewards: `accRewardPerShare` advances only between `lastRewardTime` and `block.timestamp`, scaled by current emission rate.
- Running out of phUSD mid-window stops emissions cleanly (per-second rate × elapsed can never exceed the tracked remaining budget).
- A `pull()` that mints zero leaves the existing schedule untouched — no window reset, no rate change.
- Reducing the window duration does not let users retroactively claim more than the current phUSD balance.
- Multi-ID accounting: rewards earned by holders of ID A never leak to holders of ID B.

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
