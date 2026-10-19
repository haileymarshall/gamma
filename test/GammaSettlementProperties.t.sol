// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GammaFixture} from "./utils/GammaFixture.sol";
import {GammaGame} from "src/GammaGame.sol";
import {IGammaBeacon} from "src/interfaces/IGammaBeacon.sol";

contract GammaSettlementPropertiesTest is GammaFixture {
    function test_oneUnitDrawsOneBatchAndFinalizationNeedsAnotherUnit() public {
        settleAll();
        uint256 a = buy(alice, 0, 10);
        uint256 b = buy(bob, 3, 10);
        uint256 e = game.getBatch(a).epoch;
        vm.warp(game.epochEnd(e) + 6);
        seedAll();

        game.settle(0, noProofs);
        assertFalse(game.getBatch(a).drawn);
        game.settle(1, noProofs);
        assertTrue(game.getBatch(a).drawn);
        assertFalse(game.getBatch(b).drawn);
        assertEq(game.cursor(), e);
        game.settle(1, noProofs);
        assertTrue(game.getBatch(b).drawn);
        (,,,, bool beforeFinalize,) = game.getEpoch(e);
        assertFalse(beforeFinalize);
        game.settle(1, noProofs);
        (,,,, bool afterFinalize,) = game.getEpoch(e);
        assertTrue(afterFinalize);
        assertEq(game.cursor(), e + 1);
        assertEq(game.activeCursor(), 1);
        bytes32 state = _settlementDigest(e);
        game.settle(type(uint256).max, noProofs);
        assertEq(_settlementDigest(e), state, "finished epoch changed on repeated settlement");
    }

    function test_harvestAtExactDayBoundaryUsesItsOwnUnit() public {
        settleAll();
        uint256 id = buy(alice, 3, 100);
        vm.warp(game.dayEnd(0));
        seedAll();
        game.settle(1, noProofs); // draw
        game.settle(1, noProofs); // finalize the active epoch
        game.settle(1, noProofs); // skip the empty remainder of day 0
        assertEq(game.cursor(), 144);
        assertFalse(game.getDay(0).finalized);
        assertEq(game.totalUnclaimed(), 0);
        game.settle(1, noProofs); // Harvest, even though cursor == currentEpoch
        assertTrue(game.getDay(0).finalized);
        assertTrue(game.getBatch(id).drawn);
        assertGt(game.totalUnclaimed(), 0);
        assertEq(game.cursor(), 144);
        assertEq(game.claimFeeBps(0), 8_000);
    }

    function test_settlementWorkIsClampedTo256EvenForMaximumInput() public {
        settleAll();
        uint256 e = game.currentEpoch();
        for (uint256 i; i < 257; ++i) {
            buy(alice, 0, 1);
        }
        vm.warp(game.epochEnd(e) + 6);
        seedAll();
        game.settle(type(uint256).max, noProofs);
        assertTrue(game.getBatch(255).drawn);
        assertFalse(game.getBatch(256).drawn, "oversized units bypassed work limit");
        assertEq(game.cursor(), e);
        game.settle(1, noProofs);
        assertTrue(game.getBatch(256).drawn);
        assertEq(game.cursor(), e, "drawing the last batch also finalized the epoch");
        game.settle(1, noProofs);
        assertEq(game.cursor(), e + 1);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_settlementCadenceCannotChangeOutcome(uint16[4] memory amounts, bytes32 randomness) public {
        settleAll();
        uint256 e = game.currentEpoch();
        for (uint256 m; m < 4; ++m) {
            buy(m % 2 == 0 ? alice : bob, uint8(m), bound(amounts[m], 1, 500));
        }
        vm.warp(game.dayEnd(0));
        beacon.set(game.roundForEpoch(e), keccak256(abi.encode(randomness)));
        uint256 checkpoint = vm.snapshotState();

        game.settle(256, noProofs);
        assertTrue(game.getDay(0).finalized);
        bytes32 bulk = _settlementDigest(e);
        vm.revertToState(checkpoint);
        for (uint256 i; i < 8; ++i) {
            game.settle(1, noProofs);
        }
        assertTrue(game.getDay(0).finalized);
        assertEq(_settlementDigest(e), bulk, "splitting settlement changes debts or draws");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_eachEpochAccountsForItsEntireTranche(uint16[4] memory amounts, bytes32 randomness) public {
        settleAll();
        uint256 e = game.currentEpoch();
        GammaGame.Day memory beforeDay = game.getDay(0);
        for (uint256 m; m < 4; ++m) {
            buy(m % 2 == 0 ? alice : bob, uint8(m), bound(amounts[m], 1, 500));
        }
        beacon.set(game.roundForEpoch(e), keccak256(abi.encode(randomness)));
        vm.warp(game.epochEnd(e) + 6);
        game.settle(256, noProofs);
        GammaGame.Day memory afterDay = game.getDay(0);
        uint256 additionalPot = afterDay.pot - beforeDay.pot;
        uint256 additionalShares = afterDay.sharesPaid - beforeDay.sharesPaid;
        assertEq(additionalPot + additionalShares, game.tranche(e), "tranche vanished or was counted twice");

        (uint32[4] memory used, uint32[4] memory survivors, uint256[4] memory pps,, bool finalized,) = game.getEpoch(e);
        assertTrue(finalized);
        uint256 winnings;
        uint256 fails;
        for (uint256 m; m < 4; ++m) {
            winnings += uint256(survivors[m]) * pps[m];
            fails += used[m] - survivors[m];
        }
        assertEq(winnings, additionalShares);
        assertEq(afterDay.fails - beforeDay.fails, fails);
        assertEq(game.totalUnclaimed(), 0, "unharvested shares must not earn bonuses yet");
    }

    function test_badProofDoesNotBlockPurchaseOrInventRandomness() public {
        settleAll();
        uint256 id = buy(alice, 0, 10);
        uint256 e = game.getBatch(id).epoch;
        vm.warp(game.epochEnd(e) + 10);
        uint64 round = game.roundForEpoch(e);
        bytes memory badSignature = hex"1234";
        vm.mockCallRevert(address(beacon), abi.encodeCall(IGammaBeacon.prove, (round, badSignature)), hex"bad0");
        GammaGame.BeaconProof[] memory proofs = new GammaGame.BeaconProof[](1);
        proofs[0] = GammaGame.BeaconProof(round, badSignature);
        vm.prank(bob);
        uint256 newId = game.buyEnergies(1, 1, 2_000e18, proofs);
        assertEq(newId, id + 1);
        assertFalse(game.getBatch(id).drawn);
        assertEq(game.pendingRound(), round);
        assertEq(beacon.randomness(round), bytes32(0));
        vm.clearMockedCalls();
        beacon.set(round, keccak256("valid later round"));
        game.settle(256, noProofs);
        assertTrue(game.getBatch(id).drawn);
    }

    function test_maturedClaimSkipsUntilTheExact24HourBoundary() public {
        uint256 id = buy(alice, 3, 100);
        vm.warp(game.dayEnd(0));
        settleAll();
        vm.warp(game.dayEnd(0) + 1 days - 1);
        assertGt(game.claimFeeBps(0), 1_000);
        vm.prank(alice);
        assertEq(game.claimMatured(ids1(id)), 0);
        assertFalse(game.getBatch(id).claimed);
        vm.warp(game.dayEnd(0) + 1 days);
        assertEq(game.claimFeeBps(0), 1_000);
        uint256 winnings = game.userBatches(alice, 0, 1)[0].winnings;
        vm.prank(alice);
        uint256 payout = game.claimMatured(ids1(id));
        assertEq(payout, winnings - winnings / 10);
        assertTrue(game.getBatch(id).claimed);
    }

    function test_futureHarvestDoesNotReceivePastClaimBonuses() public {
        uint256 a = buy(alice, 3, 200);
        buy(bob, 3, 200);
        toNextDay();
        settleAll();
        buy(carol, 3, 200); // day 1 is not harvested, so Carol is not yet a bonus creditor
        vm.prank(alice);
        game.claim(ids1(a));
        assertGt(game.bonusIndex(), 0);
        assertGt(game.userBatches(bob, 0, 1)[0].bonus, 0);
        toNextDay();
        settleAll();
        GammaGame.BatchView memory carolBatch = game.userBatches(carol, 0, 1)[0];
        assertTrue(carolBatch.harvested);
        assertGt(carolBatch.winnings, 0);
        assertEq(carolBatch.bonus, 0, "future debt captured a prior fee");
        assertEq(game.getDay(1).bonusIndex, game.bonusIndex());
    }

    function test_guardResetsPerEpochAndLiftsAtExactBoundary() public {
        for (uint256 i; i < 4; ++i) {
            buy(alice, 2, 500);
        }
        vm.prank(bob);
        vm.expectRevert(GammaGame.EpochCapReached.selector);
        game.buyEnergies(2, 1, 2_000e18, noProofs);
        vm.warp(game.epochEnd(game.currentEpoch()));
        buy(bob, 2, 1);
        vm.warp(game.genesis() + game.GUARD_PERIOD());
        for (uint256 i; i < 5; ++i) {
            buy(alice, 2, 500);
        }
        (uint32[4] memory used,,,,,) = game.getEpoch(game.currentEpoch());
        assertEq(used[2], 2_500);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_claimFeeIsBoundedAndNeverIncreases(uint32 first, uint32 second) public {
        uint256 a = bound(first, 0, 1 days);
        uint256 b = bound(second, a, 2 days);
        vm.warp(game.dayEnd(0) + a);
        uint256 feeA = game.claimFeeBps(0);
        vm.warp(game.dayEnd(0) + b);
        uint256 feeB = game.claimFeeBps(0);
        assertGe(feeA, feeB);
        assertLe(feeA, 8_000);
        assertGe(feeB, 1_000);
        if (b >= 1 days) assertEq(feeB, 1_000);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_roundIsFirstAtOrAfterRequiredDelay(uint32 epochSeed) public view {
        uint256 e = bound(epochSeed, 0, 365 * 144 * 100);
        uint256 target = game.epochEnd(e) + 6;
        uint256 round = game.roundForEpoch(e);
        uint256 emittedAt = uint256(beacon.genesis()) + (round - 1) * beacon.period();
        assertGe(emittedAt, target);
        assertLt(emittedAt - target, beacon.period());
    }

    function testFuzz_drawRiskIsMonotonicAndExtraEnergyAddsAtMostOneSurvivor(
        bytes32 seed,
        uint256 id,
        uint16 amountSeed,
        uint16 rateSeed
    ) public view {
        uint256 amount = bound(amountSeed, 0, 499);
        uint256 rate = bound(rateSeed, 0, 10_000);
        uint256 survivors = game.drawSurvivors(seed, id, amount, rate);
        uint256 extended = game.drawSurvivors(seed, id, amount + 1, rate);
        assertGe(extended, survivors);
        assertLe(extended - survivors, 1, "extra energy rerolled previous draws");
        assertLe(game.drawSurvivors(seed, id, amount, 10_000), survivors);
        assertEq(game.drawSurvivors(seed, id, amount, 10_000), 0);
        assertEq(game.drawSurvivors(seed, id, amount, 0), amount);
        if (rate < 10_000) assertLe(game.drawSurvivors(seed, id, amount, rate + 1), survivors);
    }

    function test_batchPaginationHandlesEmptyPagesAndKeepsNewestFirst() public {
        uint256 a = buy(alice, 0, 1);
        uint256 b = buy(alice, 1, 2);
        uint256 c = buy(alice, 2, 3);
        assertEq(game.userBatches(bob, 0, 10).length, 0);
        assertEq(game.userBatches(alice, 0, 0).length, 0);
        assertEq(game.userBatches(alice, 3, type(uint256).max).length, 0);
        assertEq(game.userBatches(alice, type(uint256).max, 1).length, 0);
        GammaGame.BatchView[] memory page = game.userBatches(alice, 1, type(uint256).max);
        assertEq(page.length, 2);
        assertEq(page[0].id, b);
        assertEq(page[1].id, a);
        page = game.userBatches(alice, 0, 1);
        assertEq(page.length, 1);
        assertEq(page[0].id, c);
        assertEq(page[0].energies, 3);
        assertEq(page[0].machine, 2);
        assertFalse(page[0].drawn);
        assertFalse(page[0].claimed);
        assertFalse(page[0].harvested);
        assertEq(page[0].winnings, 0);
    }

    function _settlementDigest(uint256 e) internal view returns (bytes32) {
        bytes32 batches;
        for (uint256 id; id < game.batchCount(); ++id) {
            batches = keccak256(abi.encode(batches, game.getBatch(id)));
        }
        (
            uint32[4] memory used,
            uint32[4] memory survivors,
            uint256[4] memory pps,
            uint8[4] memory deal,
            bool done,
            uint256 count
        ) = game.getEpoch(e);
        return keccak256(
            abi.encode(
                batches,
                used,
                survivors,
                pps,
                deal,
                done,
                count,
                game.getDay(0),
                game.getDay(1),
                game.cursor(),
                game.activeCursor(),
                game.totalUnclaimed(),
                game.gammaHeld()
            )
        );
    }
}
