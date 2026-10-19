# Handoff: where the GAMMA launch stands

Last updated: 2026-10-19 08:00 UTC. Hackathon deadline: **21 Oct 2026** (submit at imdradar.site/hackathon).
Background and rules are in `PROJECT.md`; game rules in `README.md`; every audit change in `ADAPTATION.md`.

## Where we stopped

**Waiting for IMD to register the hook launch payment.** Paid on Robinhood Chain at ~07:35 UTC:

- tx `0x91a43c22d487f313fb28fa33d09855af69504f016d1ac0950541556e560f0ff5` (status 1, 0.5 IMD moved, Intake
  `Requested` event emitted).
- As of 08:00 UTC `GET https://api.imd.fun/intake/4663/<tx>` still returns `unknown_transaction`, and the order is not
  in `GET /requests/paid-by/0x4de63474f3715c407dafaa1429fa664559814401`. The two earlier payments were picked up in
  seconds, so this is a delay on IMD's side. If it never shows up, ask IMD (@imdradar / identity.md) about the tx.

Once it is admitted, the response carries `admission.result.jobId`. Watch `GET /jobs/<jobId>` until `state` is
`completed`, then `GET /launches/<launch.id>` until `status` is `live` (or `parked`, with `parkedReason`).

## What is live

| What | Address (Robinhood Chain, 4663) |
|---|---|
| GammaGame (IMD launch 2215, job `a95d8284-6bc6-479d-ac62-7e115d14a150`) | `0xb333a22c2c3dd0fe29fd1bf184c5ff2282148535` |
| DrandBeacon | `0x50f1a83477de01069731ab796eba9fd6456aa3a5` |
| Launch wallet (payer, owner, `configurator`) | `0x4De63474F3715C407DaFAa1429FA664559814401` |
| Swap router we deployed (Uniswap `PoolSwapTest`, used to buy IMD) | `0x0a8c4623A15eE743357855a28F07d14d37DF268B` |
| IMD token | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |
| Uniswap v4 PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| IMD Intake | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |

Verified on chain: game `configurator` = launch wallet, `imd`, `poolManager`, `beacon` correct, `genesis` = 0
(waiting for `initialize`).

The launch wallet's key is in `~/.gamma/deployer.env` on the user's machine (never committed). `launch/pay.sh` signs
with it. The user has their own copy. Balance after the hook payment: ~0.02 IMD, ~0.0014 ETH.

## Remaining steps

1. **Hook launch deploys** (`launch/02-hook.json`, kind `univ4_hook`, paired with IMD, `poolBps` 1000,
   `remainderTo` = GammaGame). It creates GAMMA, GammaHook and the GAMMA/IMD pool and sends 800M GAMMA to the game.
   If IMD's adapt step changes `src/GammaHook.sol`, merge the delivered commit (as done for 2210 and 2215) and check
   the hook still exposes `game()` and `poolId()` and charges fees only in GAMMA.
2. **Wire the game** from the launch wallet, once, with the pool from `GET /launches/<id>`:
   ```
   source ~/.gamma/deployer.env
   GAME=0xb333a22c2c3dd0fe29fd1bf184c5ff2282148535 GAMMA=<token> HOOK=<hook> LP_FEE=<fee> TICK_SPACING=<spacing> \
     forge script script/InitializeGame.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com \
     --broadcast --private-key $GAMMA_PRIVATE_KEY
   ```
   `initialize` checks `hook.game() == game` and `hook.poolId() == keccak256(abi.encode(key))`, so a wrong key
   reverts with `BadPool` and can be retried. It starts the clock (`genesis`) and the hook's 99% launch fee.
3. **Frontend live mode**: set `NEXT_PUBLIC_GAME_ADDRESS`, `NEXT_PUBLIC_GAMMA_ADDRESS`, `NEXT_PUBLIC_HOOK_ADDRESS`
   (see `frontend/.env.example`), run `pnpm build` in `frontend/`, then deploy to Vercel (user's Vercel account is
   logged in on this machine; ask before deploying).
4. **User**: create the project's X account.
5. **Submit** at imdradar.site/hackathon: project X handle, a 20 to 1,000 character description, and the contract
   address (GammaGame or the hook). Entries are public and cannot be edited.
6. Optional: forward the launch wallet's 1% LP fee share to the Harvest (`donate`), as `PROJECT.md` promises.

## What happened, in order

1. Built GAMMA (contracts, tests, Next.js frontend with demo mode). Pushed to
   https://github.com/haileymarshall/gamma (public). Moved the Foundry project to the repo root because
   `POST /requests/import` requires `foundry.toml` there.
2. Frontend redesigned in the style of priors.trade: warm dark palette, EB Garamond, voxel scenes (a four-element tree
   in the hero, one scene per machine). Dev server: `pnpm dev` in `frontend/`.
3. User funded the launch wallet with ETH; bought IMD on the IMD/ETH v4 pool (1% fee, no hook) through our router.
4. **Launch 2210** (game, job `137fee05-7413-46fb-b03b-45db0221ea93`): three audit and fix rounds, then **parked**
   (not deployed) on two medium findings. 0.5 IMD spent.
5. Merged the swarm's fixes and removed the two mechanisms behind those findings: the hook refuses exact-output buys
   so every fee is GAMMA (no IMD fee swap to sandwich), and seeding is drand-only (no block-hash fallback to choose
   from). Commit `baf28a8`.
6. **Launch 2215** (game, job `a95d8284-6bc6-479d-ac62-7e115d14a150`): passed and **went live** at 07:29 UTC. The
   swarm also fixed a claim-splitting bonus issue and added `sweep()`. Delivered commit `ee52608` merged into `main`;
   132 tests pass. Its manifest is archived as `launch/2215-game-manifest.json` (a root `launch.json` blocks a hook
   launch with `launch_kind_mismatch`).
7. **Hook launch** paid (tx above): `launch/02-hook.json` pinned to commit `38e05af`, with the live game
   address. Waiting for IMD to pick it up.

## Things the next session should know

- Prizes go to the "deployer" the radar shows. For IMD launches that is IMD's factory, not us; IMD records our wallet
  as payer (`paidBy`, factory `requester`). The user has been told to confirm payout with @imdradar.
- IMD launch steps must be `audit-imported-code`, `adapt-contract-project`, `adversarial-review` with
  `shape: "chain"`. Always run `POST /requests/check` (free) before paying; `launch/pay.sh` does.
- Any open medium or high finding parks a launch and the payment is lost. A parked launch cannot be retried; a new
  `launch.open` is needed.
- Commits: conventional format, no co-author or AI mention (user's global rule).
