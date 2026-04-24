# Runway Dynamics and APY as a Policy Instrument

This note analyses the behaviour of the variable-runway / owner-set APY-target
emission model under ongoing NFT mint inflow, and discusses using `targetAPY`
as an active policy lever to modulate runway. It accompanies the spec in
`CLAUDE.md` and the original design rationale in
`scratchpad/planning-docs/phoenix/phase2/nft-staking/variable-runway.md`
(product-owner repo).

## Setup and notation

| Symbol   | Meaning                                                        |
| -------- | -------------------------------------------------------------- |
| `A`      | Target APY (owner-set, `0 <= A <= MAX_TARGET_APY`)             |
| `Y`      | `SECONDS_PER_YEAR`                                             |
| `N`      | Number of NFTs used in the T computation (total-supply today)  |
| `r`      | Per-mint growth ratio, `r = 1 + growthBasisPoints/10_000`      |
| `p_i`    | Mint price of the i-th NFT, `p_i = p_0 * r^(i-1)`              |
| `T`      | Aggregate NFT value: `p_0 * (r^N - 1) / (r - 1)`               |
| `V`      | Total budget: `balance + mintDebt` (pending at dispatcher hook)|
| `R`      | Per-second emission rate: `R = T * A / Y`                      |
| `k`      | Budget-to-value ratio: `k = V / T`                             |
| `λ`      | NFT mint rate (mints per second)                               |
| `runway` | `V / R` seconds                                                |

Mint inflow assumption: **50% of each NFT's mint price accrues to the
dispatcher as mint-debt** and is pulled into `V` via `pull()` on the hook.

## 1. Is runway stable under steady mint inflow?

### Large-N regime (geometric-series-dominated)

For `N` large enough that `r^N >> 1`, `T ≈ price / (r - 1)` and each mint adds
a roughly constant amount of runway at the then-current `R`:

```
runway_added_per_mint  ≈  0.5 · (r - 1) · Y / A
```

This is *independent of N or price*. With `r - 1 = 1e-4`, `A = 0.10`,
`Y = 31_536_000`:

```
runway_added_per_mint  ≈  15,768 s  (~ 4.4 hours)
```

Emissions drain runway at 1 second per second, so:

```
d(runway)/dt  =  λ · 0.5 · (r - 1) · Y / A  −  1
```

There is no direct negative-feedback term in this equation. Above a
break-even mint rate `λ* = 2A / ((r - 1) · Y)`, runway grows unboundedly;
below, runway drains to zero. **On the `d(runway)/dt` axis alone, `λ*` is a
knife-edge, not an attractor.**

### But there *is* a natural attractor on `k = V/T`

Tracking the ratio `k = V/T` gives a different picture. Each mint nudges
`k` by `(0.5 - k) · ε`, where `ε = price/T ≈ r - 1` in the large-N regime.
Emissions drain `k` at `A / Y` per second. Equating the two drifts:

```
k_eq  =  0.5  −  A / (Y · λ · (r - 1))
```

Runway at equilibrium:

```
runway_eq  =  k_eq · Y / A
```

| Mint rate (× `λ*`) | `k_eq` | runway_eq at A=10%, r-1=1e-4 |
| ------------------ | ------ | ---------------------------- |
| 1×                 | 0      | 0 (empty budget)             |
| 2×                 | 0.25   | ~2.5 years                   |
| 4×                 | 0.375  | ~3.75 years                  |
| → ∞                | → 0.5  | → 5 years                    |

So once mint inflow comfortably exceeds break-even, the system has a
self-stabilising runway near `Y / (2A)`.

### Early (small-N) regime

For small `N`, `T ≈ p_0 · N` rather than `p_0 / (r - 1)`, so each mint adds
`0.5 · Y / (N · A)` seconds of runway — huge when `N` is small, decaying as
`N` grows. Expect a long initial dilution phase before the large-N attractor
kicks in.

### Caveats

- The equilibrium is statistical. A sparse, bursty mint process oscillates
  around `k_eq` with amplitude `~ε`.
- If mints stop entirely, no equilibrium exists and `V` drains at `R`.
- The analysis above is the **total-supply** formulation (current spec).
  The **total-staked** alternative (see §3) adds a second feedback channel
  that makes the lever stronger but also introduces overshoot risk.

## 2. APY as a runway policy lever

Three channels make `setTargetAPY` an effective runway-modulating instrument:

1. **Direct (instant):** `R = T · A / Y` scales linearly with `A`, so
   `runway = V / R ∝ 1 / A`. Halving `A` doubles runway in the same block.
2. **Second-order (stake response):** lower `A` reduces the attractiveness
   of staking. Marginal stakers exit, reducing `N_staked` (and therefore
   `T` in the total-staked model — see §3), further reducing `R`. In the
   total-supply model this channel is absent because `T` doesn't respond
   to stake exits.
3. **Third-order (break-even threshold):** `λ* = 2A / ((r - 1) · Y)` is
   proportional to `A`. Lowering `A` lowers the mint rate required to
   sustain runway, so a mint cadence that was below break-even at high
   `A` may clear it at low `A`.

Raising `A` reverses all three effects.

### Operating rule of thumb

At healthy mint inflow, expect:

```
runway ≈ Y / (2A)
```

| `A`   | `runway` near equilibrium |
| ----- | ------------------------- |
| 10%   | ~5 years                  |
| 25%   | ~2 years                  |
| 50%   | ~1 year                   |
| 100%  | ~6 months                 |

If observed runway sits persistently below this and keeps drifting down,
either mint rate has fallen below `λ*` (exogenous) or `A` is above what
inflow can sustain — lower `A`.

If mints stop entirely, `setTargetAPY(0)` is the only move: freeze
emissions and preserve `V` until issuance resumes.

## 3. Total-supply vs total-staked formulation of `T`

Current spec defines `T` from `nftMinter.totalSupply(stakedId)` — the entire
minted cohort. An alternative is `T` computed from `totalStaked` (units
held by this contract).

### Accuracy

- **Total-supply:** Stakers collectively earn `R = T_total · A / Y`. If only
  a fraction `f = N_staked / N_total` of NFTs are staked, each staked unit
  earns an APY of `A / f`. When `f = 1`, APY = `A`; when `f = 0.1`, APY =
  `10A`. APY-target is a lower bound, actual yield scales with unstaked
  share.
- **Total-staked:** Every staker sees exactly `A` regardless of `f`. Tighter
  APY guarantee; more predictable runway.

### MEV / manipulation

A common objection to "total-staked" formulations is flash-loan-style
supply inflation. That attack is not practical here: the ERC1155 NFT is
minted against a Balancer pool position, not freely lent or circulated,
so intra-block stake-count inflation requires real capital commitment at
the NFT-minter layer, not a flash borrow.

Residual concerns are mild:

- Staking bumps `R`, but the new entrant earns the same `A` as others, so
  no arbitrage.
- Existing stakers see runway shorten when someone stakes, but not APY.
  Arguably correct behaviour: unstaked NFTs shouldn't drain budget on
  behalf of non-participants.

### Which `N` feeds the geometric formula?

Two options if moving to total-staked:

1. Use `N = totalStaked` directly in `rpow(r, N) / (r - 1)`. This
   implicitly assumes staked units are the first `N_staked` mints
   (cheapest) — a conservative lower bound on `T_staked`. Preserves the
   "APY-as-floor for median NFT" property.
2. Compute average price from the total-supply geometric series, then
   scale: `T_staked = (T_total / N_total) · N_staked`. Unbiased when
   stakers are sampled uniformly from the cohort.

Option 1 is simpler (no need to read `totalSupply`). Option 2 is more
accurate if stake selection is random.

### Dynamic-system caveat

The total-staked variant adds real feedback between `A` and `T`. This
strengthens the policy lever but also enables overshoot loops:

```
A↓  →  stakers exit  →  T↓  →  R↓  →  runway↑  →  A looks too
conservative  →  A↑  →  stakers return  →  T↑  →  R↑  →  runway↓ ...
```

Mitigations to consider if adopting total-staked:

- A minimum hold time between `setTargetAPY` calls (dead-band in time).
- A bounded per-call APY delta (dead-band in magnitude).
- Off-chain observation window before raising `A` after a cut.

## 4. Summary

- **Runway is not knife-edge-unstable.** Under sustained mint inflow
  above `λ* = 2A / ((r-1)·Y)`, the system has a natural attractor at
  `runway ≈ Y / (2A)` in the total-supply model.
- **APY is a direct and effective policy lever.** Three compounding
  channels give the owner meaningful control over runway via
  `setTargetAPY`.
- **Switching to total-staked tightens the APY guarantee and strengthens
  the lever**, but introduces a feedback loop that may need rate-limiting
  on APY changes to avoid oscillation.
- **Small-N is a separate regime** where per-mint runway contribution is
  large and shrinking; intuition from the large-N equilibrium does not
  apply until `r^N >> 1`.
