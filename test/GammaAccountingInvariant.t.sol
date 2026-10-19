// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GammaFixture, MockBeacon} from "./utils/GammaFixture.sol";
import {GammaGame} from "src/GammaGame.sol";
import {GammaToken} from "src/GammaToken.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Uses real v4 swaps. Successful calls are never caught: fail_on_revert makes a broken
/// precondition or unexpectedly unavailable user action visible instead of discarding it.
contract GammaAccountingHandler is Test {
    GammaGame public immutable game;
    MockBeacon internal immutable beacon;
    GammaToken internal immutable gamma;
    MockERC20 internal immutable imd;
    PoolSwapTest internal immutable router;
    PoolKey internal key;
    address[3] public actors;
    GammaGame.BeaconProof[] internal none;

    uint256 public immutable initialBalance;
    uint256 public energies;
    uint256 public inflows;
    uint256 public payouts;
    uint256 public claimBurns;
    uint256 public directTransfers;
    uint256 public purchases;
    uint256 public claims;
    uint256 public conversions;

    constructor(
        GammaGame game_,
        MockBeacon beacon_,
        GammaToken gamma_,
        MockERC20 imd_,
        PoolSwapTest router_,
        PoolKey memory key_,
        address[3] memory actors_
    ) {
        game = game_;
        beacon = beacon_;
        gamma = gamma_;
        imd = imd_;
        router = router_;
        key = key_;
        actors = actors_;
        initialBalance = gamma_.balanceOf(address(game_));
        energies = game_.totalEnergies();
    }

    modifier cursorMonotonic() {
        uint256 oldCursor = game.cursor();
        uint256 oldActive = game.activeCursor();
        _;
        assertGe(game.cursor(), oldCursor, "settlement cursor decreased");
        assertGe(game.activeCursor(), oldActive, "active cursor decreased");
    }

    function buy(uint256 who, uint8 machineSeed, uint256 amount) external cursorMonotonic {
        address actor = actors[who % 3];
        uint8 machine = machineSeed % 4;
        uint256 max = imd.balanceOf(actor) / 2_000e18;
        if (max > 50) max = 50;
        if (block.timestamp < game.genesis() + game.GUARD_PERIOD()) {
            (uint32[4] memory used,,,,,) = game.getEpoch(game.currentEpoch());
            uint256 capacity = game.GUARD_ENERGIES_PER_MACHINE() - used[machine];
            if (max > capacity) max = capacity;
        }
        if (max == 0) return;
        amount = bound(amount, 1, max);
        uint256 deadBefore = gamma.balanceOf(game.DEAD());
        uint256 countBefore = game.batchCount();
        vm.prank(actor);
        uint256 id = game.buyEnergies(machine, amount, amount * 2_000e18, none);
        assertEq(id, countBefore);
        assertEq(gamma.balanceOf(game.DEAD()) - deadBefore, amount * 1_000e18);
        GammaGame.Batch memory b = game.getBatch(id);
        assertEq(b.owner, actor);
        assertEq(b.machine, machine);
        assertEq(b.energies, amount);
        energies += amount;
        ++purchases;
    }

    function donate(uint256 amount, bool rawTransfer) external cursorMonotonic {
        amount = bound(amount, 0, gamma.balanceOf(address(this)));
        if (rawTransfer) {
            gamma.transfer(address(game), amount);
            directTransfers += amount;
        } else {
            gamma.approve(address(game), amount);
            game.donate(amount);
            inflows += amount;
        }
    }

    /// @dev Covers exact-input buys, exact-input sells and exact-output sells. Exact-output buys are refused by
    /// the hook (they would pay the fee in IMD), see GammaHookTest.test_exactOutBuyIsRejected.
    function trade(uint256 who, uint256 amount, uint8 modeSeed) external cursorMonotonic {
        address actor = actors[who % 3];
        uint8 mode = modeSeed % 3;
        bool sell = mode != 0;
        ERC20 tokenIn = sell ? ERC20(address(gamma)) : ERC20(address(imd));
        uint256 max = tokenIn.balanceOf(actor);
        if (max > 5_000e18) max = 5_000e18;
        if (max < 1e18) return;
        // Exact-output sell: ask for a little IMD so the GAMMA it costs stays within the actor's balance.
        amount = mode == 1 ? bound(amount, 1e15, 1e17) : bound(amount, 1e18, max);
        uint256 potBefore = game.getDay(game.today()).pot;
        bool zeroForOne = sell == (address(gamma) < address(imd));
        vm.startPrank(actor);
        tokenIn.approve(address(router), type(uint256).max);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: mode == 1 ? int256(amount) : -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        inflows += game.getDay(game.today()).pot - potBefore;
    }


    function advance(uint256 secondsSeed, uint256 blocksSeed) external cursorMonotonic {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 1, 30 hours));
        uint256 previous = vm.getBlockNumber();
        uint256 next = previous + bound(blocksSeed, 1, 300);
        vm.roll(next);
        // Explicitly supply a hash when the old block is still readable, rather than rely on
        // the runner's synthetic block history. Gaps over 256 expire a commitment, which is never renewed.
        if (next - previous <= 256) vm.setBlockhash(previous, keccak256(abi.encode(previous, "history")));
    }

    function settle(uint256 unitsSeed, bool supplyProofs) external cursorMonotonic {
        if (supplyProofs) _proveClosed();
        game.settle(bound(unitsSeed, 0, 300), none);
    }

    function claim(uint256 who, bool maturedOnly, bool duplicate) external cursorMonotonic {
        _claimActor(actors[who % 3], maturedOnly, duplicate);
    }

    function rejectForeignClaim(uint256 who, uint256 idSeed) external cursorMonotonic {
        uint256 count = game.batchCount();
        if (count == 0) return;
        uint256 id = bound(idSeed, 0, count - 1);
        address actor = actors[who % 3];
        if (game.getBatch(id).owner == actor) actor = actors[(who % 3 + 1) % 3];
        uint256 beforeHeld = game.gammaHeld();
        uint256 beforeUnclaimed = game.totalUnclaimed();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(actor);
        vm.expectRevert(GammaGame.NotOwner.selector);
        game.claim(ids);
        assertEq(game.gammaHeld(), beforeHeld);
        assertEq(game.totalUnclaimed(), beforeUnclaimed);
    }

    // Excluded from random selectors: after every run, prove that all accrued user debts can exit.
    function finish() external {
        vm.warp(game.dayEnd(game.today()) + 1 days);
        _proveClosed();
        for (uint256 i; i < 8; ++i) {
            game.settle(256, none);
            if (game.cursor() == game.currentEpoch()) break;
        }
        assertEq(game.cursor(), game.currentEpoch(), "settlement cannot catch up");
        for (uint256 i; i < 3; ++i) {
            _claimActor(actors[i], true, false);
        }
        assertEq(game.totalUnclaimed(), 0, "mature winnings could not all exit");
    }

    function _proveClosed() internal {
        for (uint256 i = game.activeCursor(); i < game.activeEpochCount(); ++i) {
            uint256 e = game.activeEpochs(i);
            if (e >= game.currentEpoch()) break;
            uint64 round = game.roundForEpoch(e);
            if (beacon.randomness(round) == bytes32(0)) beacon.set(round, keccak256(abi.encode("drand", round)));
        }
    }

    function _claimActor(address actor, bool maturedOnly, bool duplicate) internal {
        GammaGame.BatchView[] memory batches = game.userBatches(actor, 0, game.userBatchCount(actor));
        uint256[] memory ids = new uint256[](batches.length * (duplicate ? 2 : 1));
        for (uint256 i; i < batches.length; ++i) {
            ids[i] = batches[i].id;
            if (duplicate) ids[i + batches.length] = batches[i].id;
        }
        uint256 beforeBalance = gamma.balanceOf(actor);
        uint256 beforeBurn = gamma.balanceOf(game.DEAD());
        vm.prank(actor);
        uint256 paid = maturedOnly ? game.claimMatured(ids) : game.claim(ids);
        assertEq(gamma.balanceOf(actor) - beforeBalance, paid, "claim return differs from transfer");
        payouts += paid;
        claimBurns += gamma.balanceOf(game.DEAD()) - beforeBurn;
        if (paid > 0) ++claims;
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract GammaAccountingInvariantTest is GammaFixture {
    GammaAccountingHandler internal accounting;

    function setUp() public override {
        super.setUp();
        // Start with real, harvested debts for all actors, so claims are live even in a short run.
        buy(alice, 0, 100);
        buy(bob, 1, 100);
        buy(carol, 3, 100);
        toNextDay();
        settleAll();
        accounting = new GammaAccountingHandler(game, beacon, gamma, imd, swapRouter, key, [alice, bob, carol]);
        gamma.transfer(address(accounting), 1_000_000e18);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = accounting.buy.selector;
        selectors[1] = accounting.donate.selector;
        selectors[2] = accounting.trade.selector;
        selectors[3] = accounting.advance.selector;
        selectors[4] = accounting.settle.selector;
        selectors[5] = accounting.claim.selector;
        selectors[6] = accounting.rejectForeignClaim.selector;
        targetContract(address(accounting));
        targetSelector(FuzzSelector({addr: address(accounting), selectors: selectors}));
    }

    /// @dev Exact external cash-flow identity, including unaccounted direct transfers.
    function invariant_cashFlowsConserveGamma() public view {
        uint256 expected = accounting.initialBalance() + accounting.inflows() + accounting.directTransfers()
            - accounting.payouts() - accounting.claimBurns();
        assertEq(gamma.balanceOf(address(game)), expected, "unexplained GAMMA inflow or outflow");
        assertEq(game.gammaHeld() + accounting.directTransfers(), expected, "custody mirror lost a flow");
        assertEq(game.totalEnergies(), accounting.energies());
        assertEq(game.totalBurned(), accounting.energies() * 1_000e18 + accounting.claimBurns());
        assertEq(gamma.balanceOf(game.DEAD()), game.totalBurned());
        assertEq(imd.balanceOf(address(game)), 0, "the game never keeps IMD");
    }

    /// @dev Includes accrued bonuses, which totalUnclaimed alone does not represent.
    function invariant_everyLiabilityIsBacked() public view {
        uint256 principal;
        uint256 bonuses;
        for (uint256 i; i < game.batchCount(); ++i) {
            GammaGame.Batch memory b = game.getBatch(i);
            assertLe(b.survivors, b.energies);
            if (!b.drawn) assertEq(b.survivors, 0);
            GammaGame.Day memory day = game.getDay(b.epoch / 144);
            if (b.claimed) assertTrue(day.finalized, "unharvested batch was claimed");
            if (!day.finalized || b.claimed) continue;
            (,, uint256[4] memory pps,, bool finalized,) = game.getEpoch(b.epoch);
            assertTrue(finalized, "Harvest precedes an active epoch's finalization");
            uint256 winnings = uint256(b.survivors) * pps[b.machine] + uint256(b.energies - b.survivors) * day.perFail;
            principal += winnings;
            bonuses += winnings * (game.bonusIndex() - day.bonusIndex) / 1e36;
        }
        assertEq(game.totalUnclaimed(), principal, "aggregate debt differs from individual winnings");
        uint256 owed = game.RESERVE() - game.released(game.cursor()) + principal + bonuses;
        for (uint256 d; d <= game.today() + 1; ++d) {
            GammaGame.Day memory day = game.getDay(d);
            if (!day.finalized) owed += day.pot + day.sharesPaid;
        }
        assertGe(game.gammaHeld(), owed, "Reserve, pots, or user bonuses are underfunded");
    }

    function invariant_supplyAndBatchAggregates() public view {
        assertEq(gamma.totalSupply(), 1_000_000_000e18);
        uint256 balances = gamma.balanceOf(address(this)) + gamma.balanceOf(address(game))
            + gamma.balanceOf(address(manager)) + gamma.balanceOf(address(accounting)) + gamma.balanceOf(game.DEAD());
        uint256 batches;
        for (uint256 i; i < 3; ++i) {
            address actor = accounting.actors(i);
            balances += gamma.balanceOf(actor);
            batches += game.userBatchCount(actor);
        }
        assertEq(balances, gamma.totalSupply(), "tokens escaped the closed actor set");
        assertEq(batches, game.batchCount());
        assertLe(game.cursor(), game.currentEpoch());
        assertLe(game.activeCursor(), game.activeEpochCount());
        uint256 nextBatch;
        for (uint256 i; i < game.activeEpochCount(); ++i) {
            uint256 e = game.activeEpochs(i);
            if (i > 0) assertGt(e, game.activeEpochs(i - 1));
            (uint32[4] memory used, uint32[4] memory survivors,,, bool finalized, uint256 count) = game.getEpoch(e);
            assertGt(count, 0);
            assertEq(finalized, i < game.activeCursor(), "finalized active prefix reopened or skipped");
            uint256[4] memory expectedEnergies;
            uint256[4] memory expectedSurvivors;
            uint256 expectedCount;
            while (nextBatch < game.batchCount()) {
                GammaGame.Batch memory b = game.getBatch(nextBatch);
                if (b.epoch != e) break;
                expectedEnergies[b.machine] += b.energies;
                if (b.drawn) expectedSurvivors[b.machine] += b.survivors;
                ++nextBatch;
                ++expectedCount;
            }
            assertEq(count, expectedCount);
            for (uint256 m; m < 4; ++m) {
                assertLe(survivors[m], used[m]);
                assertEq(used[m], expectedEnergies[m], "epoch energies differ from purchased batches");
                assertEq(survivors[m], expectedSurvivors[m], "epoch survivors differ from batch draws");
            }
        }
        assertEq(nextBatch, game.batchCount(), "batch missing from active epochs");
    }

    function afterInvariant() public {
        accounting.finish();
        assertGt(accounting.claims(), 0, "claim campaign was vacuous");
        invariant_cashFlowsConserveGamma();
        invariant_everyLiabilityIsBacked();
        invariant_supplyAndBatchAggregates();
    }
}
