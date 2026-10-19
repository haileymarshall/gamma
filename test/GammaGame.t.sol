// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GammaFixture} from "./utils/GammaFixture.sol";
import {GammaGame} from "src/GammaGame.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract GammaGameTest is GammaFixture {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ------------------------------------------------------------------ setup

    function test_initializeOnlyOnce() public {
        PoolKey memory k = key;
        vm.expectRevert(GammaGame.AlreadyInitialized.selector);
        game.initialize(k);
    }

    function test_initializeOnlyConfigurator() public {
        GammaGame g2 = new GammaGame(manager, imd, beacon, address(this));
        vm.prank(alice);
        vm.expectRevert(GammaGame.NotConfigurator.selector);
        g2.initialize(key);
    }

    function test_initializeNeedsReserve() public {
        GammaGame g2 = new GammaGame(manager, imd, beacon, address(this));
        vm.expectRevert(GammaGame.ReserveNotFunded.selector);
        g2.initialize(key);
    }

    // ------------------------------------------------------------------ buying

    function test_buyBurnsGammaAndRecordsBatch() public {
        uint256 imdBefore = imd.balanceOf(alice);
        uint256 deadBefore = gamma.balanceOf(DEAD);
        uint256 id = buy(alice, 2, 100);

        assertEq(gamma.balanceOf(DEAD) - deadBefore, 100 * 1_000e18, "burned");
        assertEq(game.totalBurned(), 100 * 1_000e18);
        uint256 spent = imdBefore - imd.balanceOf(alice);
        assertGt(spent, 100_000e18, "paid at least the spot price");
        assertLt(spent, 103_000e18, "LP fee + impact stays small");

        GammaGame.Batch memory b = game.getBatch(id);
        assertEq(b.owner, alice);
        assertEq(b.machine, 2);
        assertEq(b.energies, 100);
        assertEq(b.epoch, game.currentEpoch());
        assertEq(gamma.balanceOf(address(game)), game.RESERVE(), "game keeps nothing from purchases");
    }

    function test_buyRefundsUnusedImd() public {
        vm.prank(alice);
        game.buyEnergies(0, 10, 1_000_000e18, noProofs);
        assertGt(imd.balanceOf(alice), 50_000_000e18 - 11_000e18);
        assertEq(imd.balanceOf(address(game)), 0);
    }

    function test_buySlippage() public {
        vm.prank(alice);
        vm.expectRevert();
        game.buyEnergies(0, 10, 9_000e18, noProofs);
    }

    function test_buyBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(GammaGame.BadMachine.selector);
        game.buyEnergies(4, 1, 2_000_000e18, noProofs);
        vm.expectRevert(GammaGame.BadAmount.selector);
        game.buyEnergies(0, 0, 2_000_000e18, noProofs);
        vm.expectRevert(GammaGame.BadAmount.selector);
        game.buyEnergies(0, 501, 2_000_000e18, noProofs);
        vm.stopPrank();
    }

    function test_guardCapsFirstWeek() public {
        for (uint256 i; i < 4; ++i) {
            buy(alice, 3, 500);
        }
        vm.prank(alice);
        vm.expectRevert(GammaGame.EpochCapReached.selector);
        game.buyEnergies(3, 1, 2_000_000e18, noProofs);
        // Other machines are not affected.
        buy(alice, 0, 1);
    }

    function test_guardLiftsAfterAWeek() public {
        warpDays(7);
        settleAll();
        for (uint256 i; i < 5; ++i) {
            buy(alice, 3, 500);
        }
    }

    // ------------------------------------------------------------------ settlement

    function test_epochWaitsForBeacon() public {
        buy(alice, 0, 50);
        uint256 e = game.currentEpoch();
        vm.warp(game.epochEnd(e) + 60);
        game.settle(256, noProofs);
        assertEq(game.cursor(), e, "stuck on the epoch until its round is proven");
        assertEq(game.pendingRound(), game.roundForEpoch(e));

        beacon.set(game.roundForEpoch(e), keccak256("r"));
        game.settle(256, noProofs);
        assertGt(game.cursor(), e);
        (,,,, bool finalized,) = game.getEpoch(e);
        assertTrue(finalized);
    }

    function test_beaconProofsAttachedToPurchase() public {
        buy(alice, 0, 50);
        uint256 e = game.currentEpoch();
        vm.warp(game.epochEnd(e) + 60);

        GammaGame.BeaconProof[] memory proofs = new GammaGame.BeaconProof[](1);
        proofs[0] = GammaGame.BeaconProof({round: game.roundForEpoch(e), signature: hex"1234"});
        vm.prank(bob);
        game.buyEnergies(1, 1, 2_000_000e18, proofs);
        assertGt(game.cursor(), e, "the purchase settled the previous epoch");
    }

    function test_noFallbackSeedOnlyDrand() public {
        buy(alice, 0, 50);
        uint256 e = game.currentEpoch();
        // However long drand is missing, block data never seeds the epoch: settlement waits.
        vm.warp(game.epochEnd(e) + 30 days);
        vm.roll(block.number + 10_000);
        game.settle(256, noProofs);
        assertEq(game.cursor(), e, "still waiting for drand");
        assertEq(game.epochSeed(e), bytes32(0));
        assertEq(game.pendingRound(), game.roundForEpoch(e));
        // The round proven late seeds the epoch exactly as it would have on time.
        bytes32 r = keccak256("late round");
        beacon.set(game.roundForEpoch(e), r);
        game.settle(256, noProofs);
        assertGt(game.cursor(), e);
        assertEq(game.epochSeed(e), keccak256(abi.encode(r, e)));
    }

    function test_roundForEpochIsAfterClose() public view {
        uint256 e = game.currentEpoch();
        uint64 r = game.roundForEpoch(e);
        uint256 roundTime = uint256(beacon.genesis()) + (uint256(r) - 1) * beacon.period();
        assertGe(roundTime, game.epochEnd(e) + game.BEACON_DELAY());
        assertLt(roundTime, game.epochEnd(e) + game.BEACON_DELAY() + beacon.period());
    }

    function test_emptyDayRollsIntoNextHarvest() public {
        uint256 d = game.today();
        toNextDay();
        settleAll();
        GammaGame.Day memory day = game.getDay(d);
        assertTrue(day.finalized);
        assertEq(day.fails, 0);
        GammaGame.Day memory next = game.getDay(d + 1);
        assertEq(next.pot, day.pot, "whole pot rolls over");
        assertGt(next.pot, 0);
    }

    function test_survivorsSplitShares_failsSplitHarvest() public {
        uint256 a = buy(alice, 0, 200); // Earth
        uint256 b = buy(bob, 3, 200); // Air
        toNextDay();
        settleAll();

        GammaGame.Batch memory ba = game.getBatch(a);
        GammaGame.Batch memory bb = game.getBatch(b);
        assertTrue(ba.drawn && bb.drawn);
        // Earth ~90% survive, Air ~10%.
        assertGt(ba.survivors, 160);
        assertLt(bb.survivors, 40);

        GammaGame.Day memory day = game.getDay(game.getBatch(a).epoch / 144);
        assertTrue(day.finalized);
        assertEq(day.fails, (200 - ba.survivors) + (200 - bb.survivors));
        assertGt(day.perFail, 0);
    }

    function test_claimFeeSchedule() public {
        uint256 d = game.today();
        uint256 end = game.dayEnd(d);
        vm.warp(end);
        assertEq(game.claimFeeBps(d), 8_000);
        vm.warp(end + 6 hours);
        assertEq(game.claimFeeBps(d), 6_250);
        vm.warp(end + 12 hours);
        assertEq(game.claimFeeBps(d), 4_500);
        vm.warp(end + 18 hours);
        assertEq(game.claimFeeBps(d), 2_750);
        vm.warp(end + 24 hours);
        assertEq(game.claimFeeBps(d), 1_000);
        vm.warp(end + 300 days);
        assertEq(game.claimFeeBps(d), 1_000);
    }

    // ------------------------------------------------------------------ claims

    function test_claimPaysWinningsMinusFee() public {
        uint256 id = buy(alice, 1, 300);
        toNextDay();
        settleAll();
        warpDays(1); // matured: 10%

        GammaGame.BatchView[] memory v = game.userBatches(alice, 0, 10);
        assertEq(v.length, 1);
        assertTrue(v[0].harvested);
        assertEq(v[0].feeBps, 1_000);
        uint256 w = v[0].winnings;
        assertGt(w, 0);

        uint256 deadBefore = gamma.balanceOf(DEAD);
        vm.prank(alice);
        uint256 paid = game.claim(ids1(id));
        uint256 fee = w * 1_000 / 10_000;
        assertEq(paid, w - fee, "only claimant: no bonus");
        assertEq(gamma.balanceOf(alice), paid);
        assertEq(gamma.balanceOf(DEAD) - deadBefore, fee / 3, "a third of the fee is burned");
        assertTrue(game.getBatch(id).claimed);

        vm.prank(alice);
        assertEq(game.claim(ids1(id)), 0, "no double claim");
    }

    function test_claimBeforeHarvestPaysNothing() public {
        uint256 id = buy(alice, 1, 10);
        vm.prank(alice);
        assertEq(game.claim(ids1(id)), 0);
        assertFalse(game.getBatch(id).claimed);
    }

    function test_claimNotOwnerReverts() public {
        uint256 id = buy(alice, 1, 10);
        toNextDay();
        settleAll();
        vm.prank(bob);
        vm.expectRevert(GammaGame.NotOwner.selector);
        game.claim(ids1(id));
    }

    function test_claimMaturedSkipsYoungDays() public {
        uint256 id = buy(alice, 1, 10);
        toNextDay();
        settleAll();
        vm.prank(alice);
        assertEq(game.claimMatured(ids1(id)), 0);
        warpDays(1);
        vm.prank(alice);
        assertGt(game.claimMatured(ids1(id)), 0);
    }

    function test_earlyClaimersPayPatientOnes() public {
        uint256 a = buy(alice, 2, 300);
        uint256 b = buy(bob, 2, 300);
        toNextDay();
        settleAll();

        // Alice exits right after the Harvest at ~80%.
        vm.prank(alice);
        game.claim(ids1(a));

        GammaGame.BatchView[] memory v = game.userBatches(bob, 0, 1);
        assertGt(v[0].bonus, 0, "bob earned a bonus from alice's fee");

        warpDays(1);
        uint256 w = game.userBatches(bob, 0, 1)[0].winnings;
        uint256 bonus = game.userBatches(bob, 0, 1)[0].bonus;
        vm.prank(bob);
        uint256 paid = game.claim(ids1(b));
        assertEq(paid, w - w / 10 + bonus);
        assertGt(paid, w, "bonus beats the 10% fee when the other miner fled");
    }

    function test_conservation() public {
        uint256 start = gamma.balanceOf(address(game));
        uint256[] memory ids = new uint256[](6);
        ids[0] = buy(alice, 0, 120);
        ids[1] = buy(bob, 1, 220);
        ids[2] = buy(carol, 2, 330);
        vm.warp(block.timestamp + 3 hours);
        ids[3] = buy(alice, 3, 440);
        ids[4] = buy(bob, 3, 50);
        ids[5] = buy(carol, 0, 5);
        toNextDay();
        settleAll();
        warpDays(1);
        settleAll();

        uint256 paidOut;
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < 6; ++i) {
            vm.prank(who[i % 3]);
            paidOut += game.claim(ids1(ids[i]));
        }
        uint256 burnedFromFees = game.totalBurned() - (120 + 220 + 330 + 440 + 50 + 5) * 1_000e18;
        assertEq(gamma.balanceOf(address(game)) + paidOut + burnedFromFees, start, "every GAMMA accounted for");
        assertGe(gamma.balanceOf(address(game)), game.totalUnclaimed());
    }

    function test_gasNormalPurchase() public {
        buy(alice, 0, 10);
        vm.prank(bob);
        uint256 g = gasleft();
        game.buyEnergies(1, 100, 2_000_000e18, noProofs);
        emit log_named_uint("purchase gas (same epoch)", g - gasleft());
    }

    function test_gasPurchaseDoingMaxSettlement() public {
        for (uint256 i; i < 8; ++i) {
            buy(i % 2 == 0 ? alice : bob, uint8(i % 4), 500);
        }
        vm.warp(block.timestamp + 10 minutes);
        seedAll();
        vm.prank(carol);
        uint256 g = gasleft();
        game.buyEnergies(1, 500, 2_000_000e18, noProofs);
        emit log_named_uint("purchase gas (8 large batches settled)", g - gasleft());
    }

    // ------------------------------------------------------------------ pure rules

    function testFuzz_survivorsBounded(bytes32 seed, uint256 id, uint16 energies, uint8 machine) public view {
        energies = uint16(bound(energies, 0, 500));
        uint256 s = game.drawSurvivors(seed, id, energies, game.failBps(machine % 4));
        assertLe(s, energies);
    }

    function test_survivalRatesMatchMachines() public view {
        for (uint256 m; m < 4; ++m) {
            uint256 total;
            for (uint256 i; i < 40; ++i) {
                total += game.drawSurvivors(keccak256(abi.encode(m, i)), i, 500, game.failBps(m));
            }
            uint256 expected = 20_000 * (10_000 - game.failBps(m)) / 10_000;
            assertApproxEqRel(total, expected, 0.05e18);
        }
    }

    function testFuzz_dealIsPermutation(bytes32 seed) public view {
        uint8[4] memory d = game.dealShares(seed);
        uint256 sixes;
        uint256 twos;
        uint256 zeros;
        for (uint256 i; i < 4; ++i) {
            if (d[i] == 6) ++sixes;
            else if (d[i] == 2) ++twos;
            else if (d[i] == 0) ++zeros;
        }
        assertEq(sixes, 1);
        assertEq(twos, 2);
        assertEq(zeros, 1);
    }

    function test_dealIsFair() public view {
        uint256[4] memory jackpots;
        for (uint256 i; i < 4000; ++i) {
            uint8[4] memory d = game.dealShares(keccak256(abi.encode(i)));
            for (uint256 m; m < 4; ++m) {
                if (d[m] == 6) ++jackpots[m];
            }
        }
        for (uint256 m; m < 4; ++m) {
            assertApproxEqRel(jackpots[m], 1000, 0.1e18);
        }
    }
}
