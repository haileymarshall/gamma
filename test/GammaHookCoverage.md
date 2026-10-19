# Additional GammaHook coverage

These tests extend the existing launch, hook audit, and game accounting suites.

| File | Checks |
| --- | --- |
| `GammaHookBoundaries.t.sol` | Constructor arguments, failed initialization and retry, pool rebinding rejection, all minute boundaries, permanent floor, later pool creation, and partial-buy comparison against an identical pool without a hook. |
| `GammaHookOneSidedLaunch.t.sol` | Local deployment at the three supplied addresses; GAMMA-only pool seed; first buys before and after genesis; rejection of a sell with no available buy-side liquidity. |
| `GammaHookLedgerInvariant.t.sol` | Random trades, dust amounts, time advances, redemption, forbidden exact-output buys, and forged callbacks, with GAMMA in either currency position. |
| `utils/GammaHookLedger.sol` | Handler and fee oracle using the real PoolManager's pre-hook `Swap` amounts, actual participant balances, and fee events. |

The invariant campaigns start with 39.6 million GAMMA of deferred fees produced by actual swaps. Each campaign runs 128 sequences of 64 actions with `fail-on-revert` enabled. Explicitly rejected calls check their error selectors and rollback. A deterministic smoke sequence checks action reachability. After each sequence, all outstanding fees must be redeemable by an ordinary participant.

The properties check that assessed fees equal GAMMA delivered to the game plus outstanding claims; claims match `pendingFees` and have token backing; received fees enter the correct Harvest; GAMMA supply is conserved; IMD never becomes a hook fee; pool identity stays fixed; and v4 settlement leaves no outstanding deltas. The game's Reserve remains separate from fee receipts. New stateless fuzz tests each use 1,000 runs.

All swaps use the vendored real v4 PoolManager and the 12,500 LP fee. IMD is a standard local ERC-20 fixture; the supplied game address is populated with this repository's GammaGame. The beacon is the existing local fixture. This exercises local integration and constructor wiring; live deployed bytecode, chain state, and production IMD behavior still require a separate fork rehearsal. All dependencies are already in the repository.

Run from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xc31fb712ebeaa008d470d5984f995d00581280e79dcf2a30b234d1841af693a1 forge test
```

For task-local build artifacts, prefix both commands with `FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache`. No delivered test imports or reads `test/scratch/`.
