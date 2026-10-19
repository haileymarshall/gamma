# Handoff: where the GAMMA launch stands

Last updated: 2026-10-19 (after the Vercel deploy). Hackathon deadline: **21 Oct 2026** (submit at imdradar.site/hackathon).
Background and rules are in `PROJECT.md`; game rules in `README.md`; every audit change in `ADAPTATION.md`.

## Where we stopped

**GAMMA is live on Robinhood Chain and the game clock is running** (`initialize` tx
`0xd1a32f0eb6472e436856df6393c6a5ffc15d8009590023ffe42c07fb6367804f`, genesis 1792428445 = 2026-10-19 ~19:00 UTC).
The frontend defaults to live mode against these addresses and passes `pnpm build`.

**Frontend is live at https://gamma-snowy.vercel.app** (Vercel project `haileymarshalls-projects/gamma`, root `frontend/`,
connected to the GitHub repo so pushes to `main` redeploy).

**Next: the user creates the X account, then submit.**

## What is live

| What | Address (Robinhood Chain, 4663) |
|---|---|
| GammaGame (IMD launch 2215) | `0xb333a22c2c3dd0fe29fd1bf184c5ff2282148535` |
| DrandBeacon (launch 2215) | `0x50f1a83477de01069731ab796eba9fd6456aa3a5` |
| GAMMA token (launch 2232) | `0xb30749417fd209f4bfc0a0270375fff8e30a0b44` |
| GammaHook (launch 2232) | `0x066fa23e6f598838824c2d172d3abd88bcad70cc` |
| MerkleDistributor (swarm's 10%, launch 2232) | `0x3b70b52ab3a15357b55673818b48b15fcea80f8c` |
| GAMMA/IMD pool key | currency0 IMD, currency1 GAMMA, fee 12500, tickSpacing 60, hooks = GammaHook |
| Launch wallet (payer, owner, `configurator`) | `0x4De63474F3715C407DaFAa1429FA664559814401` |
| Swap router we deployed (Uniswap `PoolSwapTest`) | `0x0a8c4623A15eE743357855a28F07d14d37DF268B` |
| IMD token | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |
| Uniswap v4 PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| IMD Intake | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |

Verified on chain before `initialize`: supply 1B; game held 800M + 66 wei; `hook.game()` = game;
`hook.poolId()` = keccak256 of the pool key; hook fee 99%. After: `genesis` set, `gamma` and `hook` wired.

IMD jobs: 2210 `137fee05-7413-46fb-b03b-45db0221ea93` (parked), 2215 `a95d8284-6bc6-479d-ac62-7e115d14a150`
(game, live), 2232 `3512e06f-1cd8-41ea-84f6-8e31b7bb985e` (hook, live; IMD took ~6h to register its payment).

The launch wallet's key is in `~/.gamma/deployer.env` on the user's machine (never committed). The user has their own
copy. Balance: ~0.02 IMD, ~0.0013 ETH.

## Remaining steps

1. **User**: create the project's X account and send the handle.
2. **Add the X link to the site**: set `NEXT_PUBLIC_X_URL` in Vercel (`vercel env add NEXT_PUBLIC_X_URL production`
   in `frontend/`), then redeploy (`vercel deploy --prod --yes` or push to `main`).
3. **Submit** at imdradar.site/hackathon **before 21 Oct**: project X handle, a 20 to 1,000 character description
   (draft it for the user), contract address (GammaGame `0xb333…8535` or GAMMA `0xb307…0b44`), site
   https://gamma-snowy.vercel.app. Public and not editable, so the user reviews it first.
4. Optional: a custom domain for the site (`gamma.vercel.app` is taken by someone else).
5. Optional: the launch wallet earns 1% of pool trades as payer; `PROJECT.md` promises to forward it to the Harvest
   (`donate`). Hook fees deferred on large sells can be pushed to the game by anyone with `GammaHook.redeemFees()`.
6. User: confirm prize payout with @imdradar (the radar lists IMD's factory as the deployer).

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
8. IMD registered the hook payment about 6 hours late (it was fine on chain). **Launch 2232 went live** first try:
   token, hook and pool. The swarm reworked the hook's fee collection (sell fee reserved in `beforeSwap`, collected
   after a full fill; deferred fees as ERC-6909 claims with `redeemFees()`; fees before genesis go to the game
   balance and are credited by `initialize`). Merged delivered commit `f918718`.
9. Ran `initialize` from the launch wallet: the game is live. Frontend switched to live mode by default, ABI
   regenerated, a prerender bug in `useLiveGame` (reading `Date.now()` during render) fixed.
10. Deployed the frontend to Vercel: project `haileymarshalls-projects/gamma`, production URL
    https://gamma-snowy.vercel.app (checked: 200, live game address on the page). Project root directory set to
    `frontend/` and the GitHub repo `haileymarshall/gamma` connected, so pushes to `main` redeploy (verified with
    commit `289249a`).
