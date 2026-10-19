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
- **Hook fee:**
  - 99% at pool open, falling 1 point per minute, 3% forever from minute 96.
  - Always taken in GAMMA. Exact-output buys ("buy exactly X GAMMA"), the one swap shape that would pay in IMD, are refused: buy with an exact IMD amount instead.
  - 100% goes to the Harvest. The game's own swaps are exempt.

## What changed from the first design

| Problem | Fix |
|---|---|
| IMD launches mint a fixed 1B token and take 10% for the swarm | Rescaled ×100,000. The swarm's 10% replaces the NFT airdrop, `poolBps = 1000`, and the remaining 800M (`remainderTo`) goes to the game |
| Block-hash randomness is weak, and worse on an L2 sequencer | Each epoch is seeded by the first **drand evmnet** round after it closes. Its BLS signature is verified on-chain on BN254 (`DrandBeacon`), and the frontend attaches the signature to purchases. There is no block-data fallback: any fallback would let whoever settles choose between two public draws. A drand round can be proven at any later time, so a beacon outage only delays settlement and never changes an outcome (trust assumption: drand evmnet keeps publishing) |
| Mainnet gas | Deployed on **Robinhood Chain** (Arbitrum Nitro). A normal purchase costs ~180k gas |
| Immutable code with no audit | 106 Foundry tests (unit, fuzz, invariant solvency), drand checked against real signatures on a Robinhood fork, IMD's `audit-imported-code` + audit panel at launch, an optional IMD `audit` job (`launch/00-audit.json`), and a **7-day launch guardrail** (2,000 energies per machine per epoch) that lifts by itself |
| No admin, but a one-time wiring step | `configurator` can call `initialize(poolKey)` exactly once and nothing else. The key must name the pool the `GammaHook` bound to this game was initialized with, so a mistyped key is rejected (a deliberately crafted fake hook and token can still pass: that remains a trust assumption on the configurator) |
| A hook fee was credited on the hook's word | `onHookFee` only credits GAMMA or IMD that actually arrived (`gammaHeld` mirrors the game's balance) |

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

1. Push this repo to a **public** GitHub repo. `foundry.toml` (at the repo root, as IMD requires) already sets `bytecode_hash = "none"`, as IMD requires.
2. Resolve the commit with `POST https://api.imd.fun/requests/import`, then put `repoUrl` and `baseCommit` into the files in `launch/`.
3. Submit `launch/01-game.json` (`evm_contracts`): deploys `DrandBeacon` and `GammaGame` with your wallet as `configurator`.
4. Put the game address into `launch/02-hook.json` as the `GAME_ADDRESS` placeholders, then submit it (`univ4_hook`, `pairWith: imd`): deploys GAMMA, the hook and the pool, sends 10% to the pool and 80% to the game.
5. `forge script script/InitializeGame.s.sol` with `GAME`, `GAMMA`, `HOOK`, `LP_FEE`, `TICK_SPACING` from the launch record (`GET /launches/:id`).
6. Set the frontend env vars and deploy the frontend.

Each paid action costs 0.5 IMD, paid with x402 or the onchain Intake contract. See https://imd.fun/docs/.

## Risks

GAMMA is an experimental game of chance. Energies can earn nothing, and spent GAMMA is burned, not refunded. Its only market is the GAMMA/IMD pool. The contracts cannot be changed, so any bug is permanent.

## Chosen launch constants

- `BEACON_DELAY` = 6 s: an epoch's drand round is the first one at least this long after the epoch closes.
- `GUARD_PERIOD` = 7 days, `GUARD_ENERGIES_PER_MACHINE` = 2,000: the launch guardrail.
