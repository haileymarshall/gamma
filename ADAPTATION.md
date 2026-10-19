# Adaptation for the IMD `evm_contracts` launch

Launch: Robinhood Chain (chain id 4663), kind `evm_contracts`, two contracts in this order:

1. `DrandBeacon` (`src/DrandBeacon.sol`), no constructor arguments.
2. `GammaGame` (`src/GammaGame.sol`), constructor
   `(poolManager 0x8366a39cc670b4001a1121b8f6a443a643e40951, imd 0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127, beacon $contract:DrandBeacon, configurator $owner)`.

Both constructors were already nonpayable, took only static arguments, made no external calls and did not use
`msg.sender`, so no constructor change was needed. The configurator is `$owner` (the wallet the launch names), never
the factory. Neither contract has an owner, a mint, a withdraw, a pause, a proxy, `DELEGATECALL`, `CALLCODE` or
`SELFDESTRUCT`. Runtime sizes after the changes: `DrandBeacon` 19,275 bytes, `GammaGame` 18,959 bytes.

`test/GammaLaunch.t.sol:GammaLaunchDeployTest` rehearses the deployment on an empty chain with the brief's
addresses and scans both runtimes for size and forbidden opcodes, as the protected floor does.

## Changes

Game logic (machines, fail rates, emission, Shares, Harvest, claim fee, bonus index, swaps) is untouched. Every
change below was required by a reproduced audit finding or by the launch rules.

### 1. `src/GammaGame.sol`: hook fees are credited only when the tokens arrived

Finding `0d232182…` (high), reproduced with the auditor's proof (632,950,070 GAMMA taken from the Reserve).

- `onHookFee` now checks the game's balance: a GAMMA fee needs `gamma.balanceOf(game) >= gammaHeld + amount`, an
  IMD fee needs `imd.balanceOf(game) >= pendingImd + amount`, else it reverts with `FeeNotReceived`. The hook's word
  alone can no longer move the Harvest, so nothing a hook reports can be paid out of the Reserve.
- `gammaHeld` is a new public mirror of the GAMMA the game accounts for. It is set in `initialize`, raised by
  `donate`, `convertPendingImd` and a backed GAMMA hook fee, and lowered by `claim`'s payout and burn. Purchases are
  net zero (the GAMMA bought is burned in the same call). The invariant suite checks `gammaHeld ==
  gamma.balanceOf(game)` at every step.
- `onHookFee` is `nonReentrant`, so it cannot be called while the game itself is mid-swap and temporarily holds a
  buyer's IMD or the GAMMA it is about to burn. The real hook never calls it from inside a game swap (the game's
  swaps are exempt), so the honest flow is unchanged.

Tests: `test_unbackedGammaFeeIsRejected`, `test_backedGammaFeeIsCredited`, `test_imdFeeMustBeBacked`,
`test_configuratorCannotDrainReserveThroughItsHook`, `test_hookFeesStillFlowWithTheRealHook`,
`test_heldGammaFollowsEveryFlow` (test/GammaLaunch.t.sol) and `invariant_gammaHeldMatchesBalance`
(test/GammaInvariant.t.sol). The auditor's proof `Proof_0d232182b796.t.sol` passes against the fixed code (its
configurator-controlled hook is now rejected at `initialize`, see 2).

### 2. `src/GammaGame.sol`: `initialize` checks the key against the hook it names

Finding `2fa99416…` (medium), reproduced: `initialize` accepted a key with the wrong fee (500 instead of the pool's
12,500), set `genesis`, and every purchase then reverted inside `PoolManager.swap` with the Reserve locked forever.

- After the Reserve check, `initialize` requires `IGammaHook(key.hooks).game() == address(this)` and
  `IGammaHook(key.hooks).poolId() == keccak256(abi.encode(key))`. `GammaHook` records exactly that id in
  `afterInitialize`, so the key must be the pool the PoolManager initialized with this hook, and the hook must be
  the one whose fees go to this game. A wrong fee, tick spacing, currency or hook is rejected with `BadPool` and
  `genesis` stays zero, so the configurator can try again with the right key.
- New `src/interfaces/IGammaHook.sol` declares the two views (`GammaHook` already exposes both; it is not changed).

Why `initialize` stays: the GAMMA token, the hook and the pool are created by the separate `univ4_hook` launch, and
the hook's constructor takes the game's address. Neither address can exist when the factory constructs `GammaGame`,
so they cannot be constructor arguments. The brief names this one-time wiring ("the configurator can only call
initialize once"); it is the configurator's only power, and after this change it can neither pick a hook of its
own nor lock the Reserve with a mistyped key. A deliberately malicious contract behind the hook address could still
answer the two views correctly, but with change 1 it can only stop the game, never take from it. That is the
remaining trust assumption on the configurator, and it is the launch owner. If `initialize` is never called the
Reserve stays in the contract; that is inherent to the requester's two-launch design and unchanged.

Tests: `test_initializeRejectsKeyOfAnotherPool`, `test_initializeRejectsHookBoundToAnotherGame`,
`test_initializeRejectsHookWithoutCode`, `test_initializeRecordsHeldGamma` (test/GammaLaunch.t.sol). The existing
`test_initializeOnlyOnce`, `test_initializeOnlyConfigurator` and `test_initializeNeedsReserve` still pass.

### 3. `src/GammaGame.sol`: the fallback seed is committed before it is read, once per epoch

Finding `aead30a2…` (high), reproduced with the auditor's proof: a settler probing `settle` in different blocks saw
3 survivors in one block and 0 in another for the same Air batch, and could submit only in the block it liked.

- `epochSeed(e)` no longer reads `blockhash(block.number - 1)` at call time. When the drand round for `e` is not
  proven and the two-hour window has passed, the first settlement call stores `fallbackBlock[e] = block.number` (an
  event `FallbackCommitted` is emitted) and stops. From the next block on, `blockhash(fallbackBlock[e])` seeds the
  epoch and the seed is stored in `fallbackSeed[e]` the first time it is used. The settler who commits cannot know
  the hash of the block its transaction is in, and every later caller gets the same seed, so probing blocks no longer
  changes the outcome and every batch of the epoch is drawn under one seed even if settlement spans many
  transactions.
- Once committed, the fallback is final for that epoch: a drand proof arriving later is stored by the beacon but not
  used, so nobody gets to choose between a known drand outcome and a known block outcome. A proof that arrives
  before the commit still wins (unchanged).
- If nobody reads the commitment within 256 blocks the hash is gone, so settlement commits again. Liveness is
  therefore kept: funds can never freeze, which was the requester's reason for the fallback. Remaining limit, stated
  for the auditor: during a period in which nobody at all settles for 256 blocks (about 51 minutes of L1 blocks on
  Robinhood Chain, since `block.number` there is the L1 number), the commitment is re-rolled. Any purchase, claim or
  settle by anyone fixes it, and the internal `_seed` helper keeps `epochSeed` a pure view.
- `pendingRound()` returns 0 once an epoch's fallback is committed, so the frontend stops attaching a proof that
  would not be used.

Tests: `test_fallbackSeedCannotBeGroundPerBlock` (the auditor's grinder against the real hook),
`test_fallbackSeedIsOneSeedForTheWholeEpoch`, `test_fallbackRecommitsWhenTheHashExpired`,
`test_lateProofDoesNotReplaceCommittedFallback`, `test_proofBeforeFallbackStillWins` (test/GammaLaunch.t.sol).
`test_fallbackSeedAfterTwoHours` (test/GammaGame.t.sol) encoded the old same-block behaviour and now expects the
commit, then the read in the next block. The invariant handler's `warp` also advances the block number, as a chain
does, so a committed epoch can settle. The auditor's proof `Proof_aead30a29aef.t.sol` cannot run unchanged against
the fixed code: its `setUp` initializes the game with a bare hook address that change 2 now rejects, so the
scenario is reproduced with the real hook in `test_fallbackSeedCannotBeGroundPerBlock` instead.

### 4. `test/DrandBeacon.t.sol`: `test_idempotent` gas threshold

Not an audit finding; it was the one failing test as the project arrived (finding `0dfc668e…` notes it: 26,088 gas
against a 10,000 limit, a threshold problem, not a correctness one). The test now asserts the stored value and that
a repeated `prove` costs less than a fifth of the first (no pairing), which is what it meant to check. Required
because the launch needs `forge test` to pass with the project's own configuration.

### Informational finding `0dfc668e…`

Coverage note, nothing to fix. The return-tuple order at the `BLS.verifySingle` call site it mentions is unchanged:
both flags are required, so the order is harmless.

## Revision round (reviewer findings)

### 5. `src/GammaGame.sol`: drand always wins, a fallback commitment is never renewed (finding `a48fbd6d…`, high)
Reproduced with the reviewer's proof (a lone settler re-committed until a 77-survivor draw). `_seed` now reads
`beacon.randomness(roundForEpoch(e))` first, so a proven round seeds the epoch unless a fallback seed has already
been read and stored. An expired (unread for 256 blocks) commitment is no longer replaced: the epoch waits for its
drand round, which stays provable at any later time. `pendingRound` keeps asking for the round until a fallback
seed is stored. Change 3's tests `test_fallbackRecommitsWhenTheHashExpired` and
`test_lateProofDoesNotReplaceCommittedFallback` encoded the old behaviour and were rewritten as
`test_expiredFallbackIsNeverRecommitted` and `test_proofWinsOverUnreadFallback`. `BEACON_FALLBACK` stays 2h.

### 6. `src/GammaGame.sol`: `convertPendingImd` swaps only near an earlier block's price and keeps unfilled IMD (findings `250bf221…`, `deb689d5…`, medium)
Both reproduced. The game records the pool price on every hook fee report and every game swap (`obsPrice`,
`prevObsPrice`, `obsBlock`); every non-game swap carries a fee, so this is the last price of each block.
`convertPendingImd` uses the last price of an earlier block as reference, does nothing if none exists or the price
is already more than `CONVERT_SQRT_TOLERANCE_BPS` (1% of sqrtPrice, ~2% of price) beyond it, and otherwise swaps
with that bound as `sqrtPriceLimitX96`. `pendingImd` is set to the IMD not consumed, so a partial fill (bound
reached, or no liquidity) keeps the rest for later. `unlockCallback` takes the price limit as a fourth field and
returns `(gammaOut, imdIn)` for exact-input. Tests: `test/GammaRevision.t.sol` (`test_convertWaitsForEarlierBlockPrice`,
`test_convertAfterPumpDoesNotSwapAtPumpedPrice`, `test_convertWithNoLiquidityKeepsImdPending`); `GammaHook.t.sol`
`test_exactOutBuyFeeInImdThenConverted` now rolls one block before converting.

### 7. `src/GammaGame.sol`: no purchase into an epoch whose drand round is already proven (finding `59bd4b18…`, medium)
Reproduced. `buyEnergies` reverts `EpochSeedKnown` when `beacon.randomness(roundForEpoch(currentEpoch()))` is set.
Test: `test_buyIntoProvenEpochReverts`.

### 8. `src/GammaHook.sol`, `src/interfaces/IGammaGame.sol`: fee decay starts at the game's genesis (finding `77519280…`, medium)
Reproduced. `feeBps` holds the 99% start fee while `game.genesis()` is 0 and decays from the later of pool creation
and genesis, so the first trade possible pays the launch fee. `IGammaGame` gains the `genesis()` view (already public
on `GammaGame`). The hook is not deployed by this launch. The pool remaining untradeable until `initialize` is
unchanged (a game that has not started cannot account fees). Test: `test_feeHeldAtStartUntilGameGenesis`.

### Advisory findings not changed
- `bb6f63d5…` (claim fee measured from dayEnd): reproduces, low; left as the requester's fee schedule, since the
  claimant gains nothing over waiting 24h.
- `a93dc71c…` (crafted key in `initialize`): trust assumption on the configurator (the launch owner); the README
  wording that overstated the check was corrected.
- `e3c0656d…` (hook binds to the first IMD pool): belongs to the hook launch, which creates hook and pool in one
  transaction; not changed.
- `731480c4…` (bonus index dust): wei-level rounding, not changed.

## Not changed

- `foundry.toml`, `remappings`, `lib/`, `.gitmodules`: protected. `bytecode_hash = "none"` was already set.
- `src/GammaHook.sol`, `src/GammaToken.sol`, `src/libraries/GammaEmission.sol`, `src/vendor/bls/*`: not deployed
  by this launch (the hook is a later `univ4_hook` launch; the token exists only for local runs and tests).
- `script/`, `launch/`, `frontend/`: the requester's own tooling. `launch/01-game.json` is their request body, not a
  manifest; no `launch.json` is written here.
- Constructor arguments and the `$owner` configurator: as the brief states them.

## Checks run

- `forge build` (solc 0.8.26, via-IR, optimizer 200 runs): clean.
- `forge test` with `FOUNDRY_FUZZ_SEED=0x9b803955cb8fb1b015dcf4566c4bf3bea29d8f7c0b68296b73cc4da463f49d2f`:
  all suites pass, including the invariant suite (64 runs, depth 64).
- The two audit proofs were copied to `test/scratch/` and failed on the original code (reproduced) before the
  changes; after them, `Proof_0d232182b796` passes and `Proof_aead30a29aef` stops in `setUp` for the reason given
  in change 3.

## Second revision round (reviewer findings)

### 9. `src/GammaGame.sol`: a fallback commitment is binding; drand is ignored once it exists (finding `f9624bc3…`, medium)
Reproduced: after a commitment both the fallback seed and the drand seed were usable, and the settler chose. `_seed`
now uses drand only while `fallbackBlock[e] == 0`; once committed, only `blockhash(fallbackBlock[e])` seeds the epoch
and `pendingRound` stops asking for the round. If that hash expires unread it may be renewed (new `fallbackBlock`,
recorded in the new `fallbackAt`) only `FALLBACK_RECOMMIT_DELAY` = 1 day after the commitment, so rejecting a known
draw costs a day in which nobody else settles, and the new draw is unknown when it is made. This replaces change 5's
"drand wins / never renewed" rule. Tests: `test_proofAfterCommitmentDoesNotChooseSeed`,
`test_expiredFallbackRecommitsOnlyAfterDelay` (replaces `test_expiredFallbackIsNeverRecommitted`);
`test_fallbackSeedCannotBeGroundPerBlock` now expects `pendingRound() == 0` after the commitment.

### 10. `src/GammaGame.sol`: `convertPendingImd` reference is rate-limited (finding `9ea7101d…`, medium)
Reproduced (both a pump held across blocks and a pump unwound by an exact-input sell left a pumped previous-block
reference). `obsPrice`/`prevObsPrice`/`obsBlock` are replaced by `refPrice`/`refTime`: each observation moves the
reference toward the pool's current price by at most `REF_RATE_BPS_PER_MINUTE` (1% of sqrtPrice per minute
elapsed) and at most `REF_MAX_STEP_BPS` (2%) at once, and at most once per timestamp. Moving it 2x therefore takes
holding the price for over an hour against arbitrage; a stale pre-swap observation moves it one capped step only.
The conversion bound (1% sqrtPrice past the reference) is unchanged. After a real price move, conversion waits
until the reference catches up; IMD stays pending meanwhile. Tests: `test_pumpHeldAcrossBlocksDoesNotConvert`,
`test_pumpAndUnwindLeavesNoStaleReference`, `test_convertAtSettledReference` (replaces
`test_convertWaitsForEarlierBlockPrice`); `GammaHook.t.sol` `test_exactOutBuyFeeInImdThenConverted` converts in the
same block again, since the reference exists from the first observation.

New constants (chosen values): `FALLBACK_RECOMMIT_DELAY` 1 day, `REF_RATE_BPS_PER_MINUTE` 100, `REF_MAX_STEP_BPS` 200.

Advisory findings left unchanged: `5f3b7fff` (off-chain drand knowledge with a lagging chain clock; `BEACON_DELAY`
stays 6 s, changing it moves every epoch's round), `b447e15e` (claim fee measured from the day's end, documented),
`a5ae147a` (configurator's one-shot initialize is a trust assumption), `6385a04e` (hook must be created with its
pool in one transaction; the hook is not in this manifest), `9f981c3e` (wei-level rounding dust).

## Requester revision after launch 2210 was parked

Launch 2210 was parked on two medium findings that the revisions above narrowed but could not close, because both
came from mechanisms that cannot be made choice-free: a swap of fee IMD at a price someone can lean on, and a
block-data fallback beside a public drand draw. Both mechanisms are removed rather than patched again. Changes 3, 5,
6 and 9 are superseded.

### 10. No IMD fees, so no fee swap (closes `9ea7101d…`, `250bf221…`, `deb689d5…`)
- `src/GammaHook.sol`: `beforeSwap` reverts `ExactOutputBuyNotSupported` for an exact-output buy (output GAMMA,
  `amountSpecified > 0`) from anyone but the game. That is the only swap shape whose fee falls on IMD; every other
  shape is charged in GAMMA exactly as before (exact-input sells in `beforeSwap`, exact-input buys and exact-output
  sells in `afterSwap`). Buyers use an exact IMD input. The game's own exact-output purchases stay exempt.
- `src/GammaGame.sol`: `pendingImd`, `convertPendingImd`, the reference price (`refPrice`, `refTime`, `_observe`)
  and their constants are removed. `onHookFee` reverts `FeeNotReceived` for any currency other than GAMMA. The game
  never holds IMD between calls, so nothing it holds can be sandwiched. `unlockCallback` only performs the game's
  exact-output purchase.

### 11. drand only, no block-data fallback (closes `f9624bc3…`, `aead30a2…`, `a48fbd6d…`)
- `src/GammaGame.sol`: `epochSeed(e)` is `keccak256(drand randomness of roundForEpoch(e), e)`, or zero until that
  round is proven. `BEACON_FALLBACK`, `FALLBACK_RECOMMIT_DELAY`, `fallbackBlock`, `fallbackSeed`, `fallbackAt` and
  `FallbackCommitted` are removed. With no second source there is no draw for a settler to choose.
- Liveness: a drand round is a BLS signature that anyone can prove on-chain at any later time (`DrandBeacon.prove` is
  permissionless), so an outage delays settlement and never changes an outcome. The remaining trust assumption is
  that drand evmnet keeps publishing, the same kind of external dependency as an oracle.
- `EpochSeedKnown` (change 7) is unchanged.

Tests: `GammaHookTest.test_exactOutBuyIsRejected`, `GammaLaunchTest.test_imdFeeIsRejected`,
`GammaGameTest.test_noFallbackSeedOnlyDrand` (30 days and 10,000 blocks without drand: the epoch waits, then a late
proof seeds it exactly as on time). The accounting invariant now asserts the game never keeps IMD, and its trade
handler covers exact-input buys, exact-input sells and exact-output sells. The tests of the removed mechanisms are
removed. `forge test`: 106 passed.

## Launch audit of the revised code (audit_imported_code, 7 findings)

Each finding was reproduced against the code as it arrived before anything was changed. Two reproduce and are
fixed below; the rest are design decisions the requester already made, or belong to the hook launch, and are left as
they are with the reason.

### 12. `src/GammaGame.sol`: a claimant never collects the bonus third of their own fee, however the claim is split (finding `177ef269…`, medium)
Reproduced with the auditor's proof `Proof_177ef2692a35.t.sol` on the unchanged code: alice's two Air batches paid
649,073 GAMMA claimed together and 1,072,838 GAMMA claimed one call at a time, because the bonus third of the first
call's fee was spread over `totalUnclaimed`, which still held her second batch.

- Each owner has a `selfBonusIndex`: the part of the global `bonusIndex` that their own claim fees produced. When a
  claim shares its bonus third, the same step is added to both indexes and a `SelfCheckpoint` (global index after,
  self index after) is pushed for the owner.
- A batch's bonus is `w * (bonusIndex - day.bonusIndex)` minus `w * (selfBonusIndex - self index at that Harvest)`.
  The self index at the Harvest is found by binary search over the owner's checkpoints (the last one whose global
  index is at or below `day.bonusIndex`, which is the global index at the Harvest). Batches harvested after an
  owner's claim were not unclaimed then and are not touched by it.
- The withheld part (`selfTotal`) is not kept by the game: it is added to the bonus third of the claim that
  withholds it and shared over the other unclaimed holders, or sent to the Harvest if none exist, exactly as the
  claimed fee's own third. So a split claim pays the claimant what one call pays, and the other holders receive the
  same bonus either way (wei-level rounding apart).
- `userBatches` shows the net bonus a batch would pay.

Game rules (fee schedule, thirds, index mechanics for everyone else) are unchanged. Tests, `test/GammaClaimBonus.t.sol`:
`test_splitClaimPaysTheSameAsOneClaim` (the auditor's scenario, plus bob's bonus and the Harvest share equal either
way), `testFuzz_anySplitPaysTheSame` (every partition of four batches on every machine),
`test_bonusFromOthersFeesIsStillPaid`, `test_batchesHarvestedLaterAreNotPenalised`,
`test_selfIndexCheckpointsOnlyOnFeeSharing`, `test_loneClaimantSplitSendsTheThirdToTheHarvest`. The auditor's proof
passes against the fixed code (run from `test/scratch/`). The accounting invariant's liability check still holds: it
counts the whole index growth as owed, which bounds the net bonus from above.

### 13. `src/GammaGame.sol`: `sweep()` credits GAMMA sent with a plain transfer (finding `84966529…`, low)
Reproduced: a plain `transfer` to the game raised its balance but neither `gammaHeld` nor any pot, so no function
could ever pay it. `sweep()` (anyone, `nonReentrant`, after `initialize`) adds `balanceOf - gammaHeld` to `gammaHeld`
and to today's Harvest with source `SOURCE_STRAY`, the same path as `donate`. It cannot run inside a purchase (both
hold the reentrancy lock, so the GAMMA the game briefly holds mid-swap is never swept), and before `initialize` the
surplus over the Reserve is already credited by `initialize` itself. Tests: `test_sweepCreditsStrayGammaToTheHarvest`,
`test_sweepNeedsInitialize`, `test_sweptGammaIsPaidOutThroughTheHarvest` (`test/GammaClaimBonus.t.sol`).

### Findings left unchanged
- `ba20f416…` (low, off-chain knowledge of the drand round while the chain clock lags by 7 s or more): reproduces
  only under a lagging sequencer clock, as the auditor states. `BEACON_DELAY` is the requester's value (their
  advisory `5f3b7fff`, kept at 6 s), and raising it does not remove the window, it only moves it to a larger lag; the
  on-chain `EpochSeedKnown` check (change 7) is unchanged. Recorded as a trust assumption on the sequencer's clock.
- `ddfe13e7…` (low, the claim fee decays from the day's end rather than from its Harvest): reproduces when a
  Harvest lands 24 h or more after the day's end. It is the requester's fee schedule, listed by them as advisory
  (`bb6f63d5`/`b447e15e`); a fee rate is the requester's, so it is not changed here. The README's "80% right after
  the Harvest" holds whenever settlement keeps up, which every purchase and claim works toward (`AUTO_SETTLE_UNITS`).
- `8a93bd22…` (low, drand evmnet is the single randomness source): the requester's stated design (change 11); the
  audit agrees the fallback was worse. No change.
- `eb3b9e8e…` (low, the hook binds to the first IMD pool initialized with it): `GammaHook` is not deployed by this
  launch; the hook launch creates hook and pool in one transaction. No change.
- `0fcb2987…` (info): scope note, nothing to fix.

### Checks run for this round
- `forge build`: clean (solc 0.8.26, via-IR). `GammaGame` runtime 18,959 bytes, `DrandBeacon` 19,275 bytes.
- `forge test` with `FOUNDRY_FUZZ_SEED=0xcf3d6ee599120ea7becb1356b4deb3e853b97d8b7f0518c56bd4587c16f344ff`:
  111 passed, 0 failed, including both invariant suites (`GammaAccountingInvariant` 128 runs x 96 depth,
  `GammaInvariant` 64 x 64).
- The auditor's proof `Proof_177ef2692a35.t.sol`, copied to `test/scratch/`: fails on the original code (the numbers
  above), passes on the fixed code.
