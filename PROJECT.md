# Project: GAMMA

> Living doc. Log everything we decide, build, deploy and submit here.

## Goal
Win a top-5 spot in the **Identity MD (IMD) Hackathon** by shipping a working project, launched through the IMD Protocol, that adds real use for IMD (its swarm, oracle or token) beyond a plain token.

## Status (2026-10-18, 3 days before the deadline)

### Done
- **Research**
  - Hackathon rules, prizes and judging (below).
  - IMD docs, the live launch list and contract addresses.
  - Chain chosen: **Robinhood Chain (4663)**. Base is not offered for launches, and Sepolia is a testnet.
- **Idea**: AETHER (your design, from the PDF) renamed to **GAMMA**, then redesigned to fit the IMD launch rules:
  - 1B supply: 80% Reserve, 10% pool, 10% swarm (the swarm share replaces the NFT airdrop)
  - drand randomness instead of block hashes
  - Robinhood Chain to keep gas low
  - a 7-day guardrail that lifts by itself
  - a fallback seed so funds can never freeze
- **Contracts** (Foundry project at the repo root):
  - GammaGame, GammaHook (Uniswap v4), DrandBeacon, GammaEmission and GammaToken (local and test runs only)
  - 54 Foundry tests passing (unit, fuzz, invariant)
  - drand verified against real signatures, including on a Robinhood Chain fork
  - Every contract is under 24 KB.
  - The full stack deploys on a local chain.
- **Scripts**:
  - `DeployLocal.s.sol`: full local stack
  - `InitializeGame.s.sol`: post-launch wiring
  - `HookMiner.sol`
- **Launch requests** (`launch/`):
  - `00-audit.json`: optional
  - `01-game.json`: `evm_contracts`
  - `02-hook.json`: `univ4_hook`, paired with IMD
- **Frontend** (`frontend/`, Next.js 16, wagmi 3):
  - Live mode reads the chain and attaches drand proofs.
  - Demo mode lets anyone play the real rules with a time speed-up.
  - Explainer sections and charts; works on mobile.
  - Build and lint are clean. The play flow was checked in headless Chromium.
- **Docs**: `README.md` (rules, fixes, how to run and launch) and this file.

### Still needed from you
1. **Public GitHub repo.** IMD only launches from public repos. Say the word and I'll commit and push. Nothing is committed yet.
2. **A wallet on Robinhood Chain**, holding a little ETH for gas and about 1.5 IMD (three paid IMD actions at 0.5 IMD each). That wallet becomes the deployer, and prizes are paid to the deployer.
3. **The project's X account** (a hackathon rule), plus approval to deploy the frontend to Vercel for a public link.

### Questions to ask IMD before paying
- Will `adapt-contract-project` deploy our code without changing the logic?
- Does `poolBps = 1000` mean 10% of total supply?
- We will send the paying wallet's 1% LP fee share to the Harvest, so the "no team" claim holds.

## Key dates
| Item | Date |
|---|---|
| Submissions open | 7 Oct 2026 |
| **Submission deadline** | **21 Oct 2026** |
| Winners announced | by 23 Oct 2026 |

## What IMD is
- **identity.md / $IMD**: an Ethereum project building "a community-owned company run by AI agents."
- **Swarm**: 2,000 NFTs, one worker seat each. Holders run agents (Claude Code or Codex) on their own machines, and verifiers check work before it is recorded onchain.
- **Hire the swarm** (explorer.imd.fun/launch): each paid action costs **0.5 IMD**, paid with x402 or the onchain Intake contract.
- **Launch kinds**:
  - `univ4_hook`: hook, token and pool deployed together
  - `evm_contracts`: contracts only
  - `custom_token`
  - Launch tokens: 1B supply, 10% to the swarm and 90% to us, 1.25% pool fee.
- **Oracle**: a panel of agents answers a typed question and returns an EIP-712 attestation our contract can verify. It is not a price feed.
- **Chains**:
  - Launches: Sepolia, Ethereum and Robinhood Chain.
  - Hackathon contract address: Ethereum, Base or Robinhood Chain.
  - Checked `GET /requests/capabilities` on 2026-10-18: launches are only open on Sepolia (testnet), Ethereum (1) and Robinhood Chain (4663). Base is not offered, and Sepolia is a testnet. **We launch on Robinhood Chain**, which supports `univ4_hook` paired with IMD.
- **Docs**: https://imd.fun/docs/ · https://imd.fun/docs/llms.txt · https://api.imd.fun/openapi.json

## Rules / qualification
1. Launch through the IMD Protocol during the build period (explorer.imd.fun/launch).
2. Build something meaningful: a **Uniswap V4 hook or custom contract** with real functionality that **uses IMD**. A token is optional.
3. Create a **dedicated X account** for the project.
4. Submit at **imdradar.site/hackathon**:
   - project X handle
   - 20–1,000 character description
   - optional contract address
   - Entries are public and cannot be edited.
5. One entry per project. Prizes go to the **deployer address**.

## Prizes & judging
- Prize pool: the tweet says **$15k+** and the radar site says **$10k**. Paid in ETH, USDT, USDC and IMD.
- 15 winners. 1st place also gets an identity.md NFT.
- **IMD agents pick places 6–15. A human jury picks the top 5.**

## Our project: GAMMA
GAMMA is proof-of-play mining paired with IMD: a token you can only mine by playing.
- Players pay IMD for energies (the GAMMA bought is burned) and place them on four machines with different risk.
- A fixed 800M Reserve is released every 10 minutes. Survivors split the Shares, failures split the daily Harvest.
- A Uniswap v4 hook sends 100% of trading fees (99% at launch, falling to 3%) to the miners.
- Randomness comes from drand, verified onchain.
- See `README.md` for the full rules.

## Win strategy
Judges reward what helps IMD itself: paid demand for the swarm and oracle (its weakest point today), plus IMD burn and utility.

### Candidate ideas
1. **Oracle-settled prediction market / escrow hook** (top pick)
   - A v4 pool or contract that settles on IMD oracle attestations.
   - Creates recurring paid oracle demand.
2. **Agent-reputation fee hook**: dynamic swap fees with discounts for ERC-8004 agents, sIMD stakers or seat holders. Fee skim buys and burns IMD.
3. **Swarm bounty escrow**: users lock IMD for a task. The swarm delivers, the oracle attests, and the escrow pays out automatically.
4. **Fair-launch / anti-snipe hook** paired with IMD.

## Decisions log
- 2026-10-18: Researched the hackathon and set up this doc. Name and idea still to be chosen.
- 2026-10-18: Reviewed the **GAMMA** idea (originally named AETHER, `Downloads/AETHER-complete-guide-EN.pdf`, 14 Oct, 134 tests, not deployed).
  - Concept: a token you can only mine by playing, paired with IMD.
  - Strong fit for the judges.
  - Open issues: IMD launch path (the 10% swarm cut and pool cap conflict with its tokenomics), mainnet gas cost, block-hash randomness, stale simulation, and who owns the code.
- 2026-10-18: Project renamed from AETHER to **GAMMA**. The token, contracts, docs and branding all use GAMMA.
- 2026-10-18: Chose GAMMA as our hackathon project (over the candidate ideas above).
- 2026-10-18: GAMMA is our own project. Changing supply to 1B to fit the `univ4_hook` launch.
  - Proposed fixes:
    - Swarm's 10% replaces the NFT airdrop.
    - Deploy on Robinhood Chain.
    - drand beacon (or VRF) for randomness.
    - Swarm audit + fuzz tests before launch.
    - Present it as "mine by playing."

## Build log
- 2026-10-18: Wrote GAMMA from scratch.
  - **Contracts** (repo root, Foundry, solc 0.8.26):
    - `GammaGame`: epochs, machines, Shares, Harvest, claim fee, unclaimed bonus, swaps through Uniswap v4 unlock.
    - `GammaHook`: v4 hook with a 99%→3% fee, sent to the Harvest.
    - `DrandBeacon`: drand evmnet BLS verification on BN254, using vendored randa-mu/bls-solidity (MIT).
    - `GammaEmission`: closed-form schedule. Year 1 is 500M; the tail is 300M.
    - `GammaToken`: for local and test runs only.
  - Tokenomics rescaled ×100,000:
    - energy = 1,000 GAMMA
    - Reserve 800M, pool 100M (`poolBps = 1000`), swarm 100M (this replaces the NFT airdrop)
  - Launch guardrail: 2,000 energies per machine per epoch for the first 7 days. It lifts by itself.
  - Fallback seed from block data if drand is missing for 2h, so settlement can never freeze.
  - **Tests**: 54 passing.
    - unit, fuzz, and invariants (solvency, supply, cursor)
    - drand checked against real evmnet signatures, including on a Robinhood Chain fork
  - Gas:
    - normal purchase ≈ 180k
    - purchase that also settles 8 batches of 500 ≈ 1.5M
    - drand proof ≈ 250k
  - Contract sizes are all under 24 KB.
  - **Local deploy**: `script/DeployLocal.s.sol` deploys the full stack on anvil and works. `script/InitializeGame.s.sol` is the post-launch wiring step.
  - **Launch requests** (`launch/`):
    - `00-audit.json`: optional IMD audit job
    - `01-game.json`: `evm_contracts`, deploys DrandBeacon and GammaGame
    - `02-hook.json`: `univ4_hook` on Robinhood Chain, paired with IMD, `remainderTo` = the game
  - **Frontend** (`frontend/`, Next.js 16, wagmi 3, viem):
    - Live mode reads the chain and attaches drand proofs to transactions.
    - Demo mode runs the same rules against a simulated crowd, with a time speed-up.
    - The production build passes and the full play flow was checked in headless Chromium.

- 2026-10-19: Launch run on Robinhood Chain.
  - Foundry project moved to the repo root (IMD import requires it). Pinned commit `b9b13e8`.
  - Launch wallet `0x4De63474F3715C407DaFAa1429FA664559814401` (key in `~/.gamma/deployer.env`, never committed). It is the payer, so IMD records it as `paidBy`/requester and it gets the owner role.
  - Bought 1.02 IMD on the IMD/ETH v4 pool through a self-deployed `PoolSwapTest` router (`0x0a8c…268B`).
  - Paid `01-game.json` (tx `0xea4f…4558`), IMD job `137fee05-7413-46fb-b03b-45db0221ea93`.
  - The prize "deployer" on the radar is IMD's factory for every IMD launch; IMD records the paying wallet onchain.

## Submission checklist
- [x] Pick name + idea (GAMMA)
- [x] Contracts + tests
- [x] Frontend (demo mode works)
- [x] Push to a **public** GitHub repo and resolve the commit with `POST /requests/import`
- [x] Fill `repoUrl` and `baseCommit` in `launch/*.json` (no `owner`: the payer is the owner)
- [x] Skip `launch/00-audit.json`: every launch already runs the audit panel
- [x] Submit `launch/01-game.json` (0.5 IMD) — paid; waiting for the GammaGame address
- [ ] Fill `GAME_ADDRESS` in `launch/02-hook.json` and submit it (0.5 IMD)
- [ ] Run `InitializeGame.s.sol` with the pool from the launch record
- [ ] Commit to sending the paying wallet's 1% LP fee share to the Harvest (`donate`)
- [ ] Deploy the frontend with the live env vars
- [ ] Create the X account
- [ ] Submit on imdradar.site/hackathon before 21 Oct (project X handle, description, GammaGame or hook address)
