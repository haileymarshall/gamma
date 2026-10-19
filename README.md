# GAMMA: Mine it. Don't buy it.

GAMMA is a token you can only mine by playing. Players burn GAMMA (bought with IMD) for **energies**, place them on one of **four machines** (Earth, Water, Fire, Air: 10/30/60/90% fail rate), and every **10 minutes** a fixed reward from the Reserve is shared among the miners. Survivors split the **Shares**. Failures split the evening **Harvest**.

Built for the [IMD Hackathon](https://www.imdradar.site/hackathon) and launched through the IMD swarm on Robinhood Chain.

## Repository

| Path | What |
|---|---|
| `src/`, `test/`, `script/`, `lib/` | Foundry project at the repo root (IMD imports require it): `GammaGame`, `GammaHook` (Uniswap v4), `DrandBeacon`, `GammaEmission`, tests |
| `frontend/` | Next.js app: live mode against the deployed contracts, demo mode (simulation) otherwise |
| `launch/` | `launch.open` / audit request bodies for api.imd.fun |
| `PROJECT.md` | Project log: goal, hackathon rules, decisions, build log, checklist |

## Token

| | GAMMA | Note |
|---|---|---|
| Supply | 1,000,000,000 | fixed by the IMD launch factory, no mint |
| Reserve | 800,000,000 (80%) | in `GammaGame`, released only by playing |
| Pool | 100,000,000 (10%) | single-sided against IMD |
| IMD swarm | 100,000,000 (10%) | 8% to identity.md NFT seats, 2% to the agents that built the launch |
| Team / presale / treasury | 0 | |

`src/GammaToken.sol:GammaToken` is the launch token. Its nonpayable constructor takes no arguments and mints
exactly `10^27` minor units (18 decimals) to its caller, the launch factory. The factory makes the three allocations;
the token has no post-construction mint or administrative functions and takes no transfer fee.

**Emission.** Year 1 releases exactly 500M, starting at ~3.28M/day and halving every 120 days. After that, each epoch releases a fixed fraction of the 300M left (0.1327%/day), forever, halving every ~522 days, with no jump at the switch. Computed in closed form (`GammaEmission`), so any range of epochs costs O(log n).

## Rules

- **Energy:** 1,000 GAMMA bought on the GAMMA/IMD pool with IMD and burned. Up to 500 per batch. All of the IMD buys GAMMA and none of it is kept.
- **Epoch (10 min):**
  - The tranche splits 90% to Shares and 10% to the Harvest.
  - The Shares are dealt 60/20/20/0 to the machines at random, and survivors split their machine's Share.
  - A machine with no survivors sends its Share to the Harvest.
- **Harvest (daily):**
  - The pot holds 10% of the day's tranches, 100% of hook trading fees, ⅓ of claim fees and any unclaimed Shares.
  - It is split equally among every energy that failed that day.
  - If nobody failed, the pot rolls over to the next day.
- **Claim:**
  - Claiming is the only exit.
  - The fee is 80% right after the Harvest, falls linearly to 10% at 24h, then stays at 10% forever.
  - The fee is split ⅓ burned, ⅓ to all harvested-but-unclaimed winnings (pro rata, which replaces staking) and ⅓ to tonight's Harvest.
  - Nobody earns a bonus from their own fee, however a claim is split: the part of a claimant's fee that falls on their own still-unclaimed batches is passed on to the other holders at their next claim (`selfBonusIndex`).
- **Donations:** `donate(amount)` adds GAMMA to today's Harvest. GAMMA sent with a plain transfer is credited the same way by `sweep()`, which anyone can call.
- **Hook fee:**
  - 99% at pool open, held there until the game's genesis is set; decay starts at the later of pool creation and
    genesis. It falls 1 percentage point per complete minute, reaching 3% forever from minute 96.
  - Always taken in GAMMA. Exact-output buys ("buy exactly X GAMMA"), the one swap shape that would pay in IMD, are refused: buy with an exact IMD amount instead.
  - Exact-input buys pay on realised GAMMA output. Both sell shapes pay the scheduled fraction of the seller's
    total GAMMA payment: exact-output sells add `poolInput * feeBps / (10000 - feeBps)` to the pool input.
    Integer fee division rounds down.
  - Exact-input sells are **full fill or revert**. If the price limit or lack of liquidity leaves some of the
    net input unspent, `PartialFillSellNotSupported` reverts the whole swap, including its fee. This prevents a fee
    on the unspent offer. A price limit is still respected; use a smaller sell or an exact-output sell for a partial fill.
  - 100% goes to the Harvest. Before genesis, delivered fees accumulate above the 800M Reserve and the existing
    `GammaGame.initialize` credits that surplus to day 0. Trading at 99% therefore works before game initialization.
  - Normally the fee is transferred and reported during the swap. If the PoolManager does not yet hold enough
    GAMMA (the seller settles after the hook returns), the hook holds the fee as an ERC-6909 claim in `pendingFees`.
    Anyone can call `GammaHook.redeemFees()` after the swap's unlock finishes, including later in the same transaction.
    It burns available claims and sends all proceeds to the fixed game; it cannot pay the caller or change recipients.
    Redemption can be partial if the manager's balance is short. A delayed redemption funds the Harvest **on receipt**,
    not a past day's Harvest. Integrators should redeem promptly; no backend signer or owner is required.
  - The game's own swaps are exempt. The pool's separate LP fee is 12,500 (1.25%), with tick spacing 60.

## What changed from the first design

| Problem | Fix |
|---|---|
| IMD launches mint a fixed 1B token and take 10% for the swarm | Rescaled ×100,000. The swarm's 10% replaces the NFT airdrop, `poolBps = 1000`, and the remaining 800M (`remainderTo`) goes to the game |
| Block-hash randomness is weak, and worse on an L2 sequencer | Each epoch is seeded by the first **drand evmnet** round after it closes. Its BLS signature is verified on-chain on BN254 (`DrandBeacon`), and the frontend attaches the signature to purchases. There is no block-data fallback: any fallback would let whoever settles choose between two public draws. A drand round can be proven at any later time, so a beacon outage only delays settlement and never changes an outcome (trust assumption: drand evmnet keeps publishing) |
| Mainnet gas | Deployed on **Robinhood Chain** (Arbitrum Nitro). A normal purchase costs ~180k gas |
| Immutable code with no audit | 111 Foundry tests (unit, fuzz, invariant solvency), drand checked against real signatures on a Robinhood fork, IMD's `audit-imported-code` + audit panel at launch, an optional IMD `audit` job (`launch/00-audit.json`), and a **7-day launch guardrail** (2,000 energies per machine per epoch) that lifts by itself |
| No admin, but a one-time wiring step | `configurator` can call `initialize(poolKey)` exactly once and nothing else. The key must name the pool the `GammaHook` bound to this game was initialized with, so a mistyped key is rejected (a deliberately crafted fake hook and token can still pass: that remains a trust assumption on the configurator) |
| A hook fee was credited on the hook's word | `onHookFee` only credits GAMMA that actually arrived (`gammaHeld` mirrors the game's balance) |
| Claiming batch by batch recovered the bonus third of one's own fee | Each owner's share of the bonus index is tracked (`selfBonusIndex`); a claim pays the same in one call or many |

See `ADAPTATION.md` for the changes made for the IMD launch and the audit findings behind them.

## Run it

```bash
# contracts
forge build && forge test

# full local stack (anvil)
anvil &
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# frontend (demo mode without env vars)
cd frontend
pnpm install && pnpm dev
```

Live mode: copy `frontend/.env.example` to `frontend/.env.local` and fill in the addresses.

## Launch through IMD (Robinhood Chain, chain 4663)

This assignment launches only `GammaToken` and `GammaHook`. GammaGame already exists at
`0xb333a22c2c3dd0fe29fd1bf184c5ff2282148535`; the game and beacon sources remain here for local integration tests.

The hook's unchanged nonpayable constructor is `(IPoolManager poolManager, address imd, IGammaGame game)`.
The manifest step supplies `$poolManager`, the IMD pair `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, and that game,
in that order. It makes no external calls during construction. GAMMA is discovered from the initialized PoolKey.
The launch factory creates the hook and initializes its pool in the same transaction. It allocates 10% to the
pool, 10% to the network's distributor, and the complete 80% remainder (800M GAMMA) to the game.
The deployer determines the opening price from the policy's 2,500 IMD opening market cap and token ordering.

After the launch, the game's existing configurator uses `script/InitializeGame.s.sol` with `GAME` set to the address
above, `GAMMA` and `HOOK` from the accepted launch record, `LP_FEE=12500`, and `TICK_SPACING=60`. The game checks that
its balance is at least `RESERVE` (800M) and that the hook's game and pool id match before starting genesis. This
step is already scripted; it starts gameplay and fee decay, while ordinary swaps can run at 99% beforehand. A
failed attempt leaves the game uninitialized and can be retried with the correct key. No deployment or signing
is part of this adaptation, and the later manifest step writes `launch.json`.

The hook implements `IHooks` directly and keeps exactly six permissions: `beforeInitialize`, `afterInitialize`,
`beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta` (address bits `0x30cc`). CREATE2 salt mining
must use the final bytecode, constructor arguments and actual factory address; `script/HookMiner.sol` provides the
internal mining helper. Every enabled callback and the claim redemption callback requires the PoolManager. The
hook has no owner, shares, signer, upgrade path, LP fee override or liquidity-removal callbacks. It uses checked
delta casts and the manager's `take` / `mint` / `burn` settlement operations, without its own transient storage.

The files in `launch/` describe the earlier request workflow; they are not this adaptation's deployment manifest.

## Risks

GAMMA is an experimental game of chance. Energies can earn nothing, and spent GAMMA is burned, not refunded. Its only market is the GAMMA/IMD pool. The contracts cannot be changed, so any bug is permanent.

## Chosen launch constants

- `BEACON_DELAY` = 6 s: an epoch's drand round is the first one at least this long after the epoch closes.
- `GUARD_PERIOD` = 7 days, `GUARD_ENERGIES_PER_MACHINE` = 2,000: the launch guardrail.
