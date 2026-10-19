// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GammaFixture} from "./utils/GammaFixture.sol";
import {GammaGame} from "src/GammaGame.sol";

/// @notice Audit finding 177ef269 (medium): splitting a claim into several calls let the claimant collect the bonus
/// third of their own claim fee through their remaining unclaimed batches. The bonus third is for the other
/// unclaimed holders, however a claim is split. Also covers the stray-GAMMA sweep (finding 84966529).
contract GammaClaimBonusTest is GammaFixture {
    uint256 internal constant SCALE = 1e36;

    function ids2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function harvestDay0() internal {
        vm.warp(game.dayEnd(0) + 1);
        settleAll();
        assertTrue(game.getDay(0).finalized, "day 0 harvested");
    }

    function winningsOf(uint256 id) internal view returns (uint256) {
        GammaGame.Batch memory b = game.getBatch(id);
        (,, uint256[4] memory pps,,,) = game.getEpoch(b.epoch);
        return
            uint256(b.survivors) * pps[b.machine] + uint256(b.energies - b.survivors)
                * game.getDay(b.epoch / 144).perFail;
    }

    /// @dev The auditor's scenario: two 500-energy Air batches claimed together versus one call each, same block.
    function test_splitClaimPaysTheSameAsOneClaim() public {
        uint256 a1 = buy(alice, 3, 500);
        uint256 a2 = buy(alice, 3, 500);
        uint256 b1 = buy(bob, 3, 10);
        harvestDay0();

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 together = game.claim(ids2(a1, a2));
        uint256 potTogether = game.getDay(game.today()).pot;
        vm.prank(bob);
        uint256 bobTogether = game.claim(ids1(b1));
        vm.revertToState(snap);

        vm.prank(alice);
        uint256 p1 = game.claim(ids1(a1));
        vm.prank(alice);
        uint256 p2 = game.claim(ids1(a2));
        assertLe(p1 + p2, together, "splitting a claim earned the claimant a bonus from their own fee");
        assertLe(together - (p1 + p2), 2, "split claim lost more than rounding dust");
        assertApproxEqAbs(game.getDay(game.today()).pot, potTogether, 4, "Harvest share depends on the split");

        // Bob's bonus is the same whichever way alice claimed: the part of her first fee that fell on her own
        // second batch was passed on to him with her second claim.
        vm.prank(bob);
        uint256 bobSplit = game.claim(ids1(b1));
        assertApproxEqAbs(bobSplit, bobTogether, 4, "other holders' bonus depends on how the claimant split");
        assertEq(game.totalUnclaimed(), 0);
    }

    /// @dev Any partition of the claimant's batches pays what one call pays (up to a wei per call of rounding).
    function testFuzz_anySplitPaysTheSame(uint8 pattern, uint8 machineSeed) public {
        uint8 machine = machineSeed % 4;
        uint256[] memory ids = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            ids[i] = buy(alice, machine, 50 + i * 37);
        }
        uint256 b1 = buy(bob, (machine + 1) % 4, 40);
        harvestDay0();

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 together = game.claim(ids);
        vm.prank(bob);
        uint256 bobTogether = game.claim(ids1(b1));
        vm.revertToState(snap);

        // Each bit of `pattern` ends a chunk after that batch; the last chunk always closes.
        uint256 paid;
        uint256 calls;
        uint256 start;
        for (uint256 i; i < 4; ++i) {
            bool cut = i == 3 || (pattern >> i) & 1 == 1;
            if (!cut) continue;
            uint256[] memory chunk = new uint256[](i + 1 - start);
            for (uint256 j = start; j <= i; ++j) {
                chunk[j - start] = ids[j];
            }
            vm.prank(alice);
            paid += game.claim(chunk);
            ++calls;
            start = i + 1;
        }
        assertLe(paid, together, "a split claim paid more than one claim");
        assertLe(together - paid, calls * 2, "a split claim lost more than rounding dust");
        vm.prank(bob);
        assertApproxEqAbs(game.claim(ids1(b1)), bobTogether, calls * 2 + 2, "bob's bonus changed with alice's split");
    }

    /// @dev Bonuses from other players' fees are still paid in full.
    function test_bonusFromOthersFeesIsStillPaid() public {
        uint256 a1 = buy(alice, 0, 300);
        uint256 b1 = buy(bob, 0, 300);
        harvestDay0();

        uint256 wa = winningsOf(a1);
        uint256 wb = winningsOf(b1);
        vm.prank(bob);
        game.claim(ids1(b1));
        uint256 step = (wb * game.claimFeeBps(0) / 10_000 / 3) * SCALE / wa;
        assertEq(game.bonusIndex(), step);
        assertEq(game.selfBonusIndex(alice), 0);
        assertEq(game.selfBonusIndex(bob), step);

        GammaGame.BatchView[] memory view_ = game.userBatches(alice, 0, 1);
        assertEq(view_[0].bonus, wa * step / SCALE, "view bonus");

        vm.prank(alice);
        uint256 paid = game.claim(ids1(a1));
        assertEq(paid, wa - wa * game.claimFeeBps(0) / 10_000 + wa * step / SCALE, "alice's bonus from bob's fee");
    }

    /// @dev A batch harvested after the owner's claim was not unclaimed then and is not penalised for that claim.
    function test_batchesHarvestedLaterAreNotPenalised() public {
        uint256 a0 = buy(alice, 1, 200);
        uint256 b0 = buy(bob, 1, 200);
        vm.warp(game.dayEnd(0) + 1); // day 1
        uint256 a1 = buy(alice, 1, 200);
        uint256 b1 = buy(bob, 1, 200);
        settleAll();
        assertTrue(game.getDay(0).finalized);

        // Alice claims her day-0 batch: her fee third goes to bob's day-0 batch only.
        vm.prank(alice);
        game.claim(ids1(a0));
        uint256 aliceStep = game.selfBonusIndex(alice);
        assertGt(aliceStep, 0);

        vm.warp(game.dayEnd(1) + 1);
        settleAll();
        assertTrue(game.getDay(1).finalized);
        assertEq(game.getDay(1).bonusIndex, game.bonusIndex());

        // Bob claims both of his: bob's fee is shared over alice's day-1 batch only.
        uint256 wa1 = winningsOf(a1);
        uint256 wb = winningsOf(b0) + winningsOf(b1);
        vm.prank(bob);
        game.claim(ids2(b0, b1));
        uint256 bobStep = game.bonusIndex() - game.getDay(1).bonusIndex;
        assertEq(
            bobStep,
            (winningsOf(b0) * game.claimFeeBps(0) / 10_000 + winningsOf(b1) * game.claimFeeBps(1) / 10_000) / 3 * SCALE
                / wa1
        );
        assertEq(wb > 0, true);

        vm.prank(alice);
        uint256 paid = game.claim(ids1(a1));
        uint256 fee = wa1 * game.claimFeeBps(1) / 10_000;
        assertEq(paid, wa1 - fee + wa1 * bobStep / SCALE, "day-1 batch keeps bob's whole bonus");
        assertEq(game.totalUnclaimed(), 0);
    }

    /// @dev The self index is tracked per owner and checkpointed only when a claim moved the index.
    function test_selfIndexCheckpointsOnlyOnFeeSharing() public {
        uint256 a1 = buy(alice, 0, 100);
        harvestDay0();
        vm.prank(alice);
        game.claim(ids1(a1)); // nobody else unclaimed: the bonus third goes to the Harvest, no checkpoint
        assertEq(game.bonusIndex(), 0);
        assertEq(game.selfBonusIndex(alice), 0);
    }

    /// @dev A lone claimant who splits: the bonus of the first call falls entirely on their own remaining batch,
    /// is withheld at the second call and, with nobody else unclaimed, goes to the Harvest like a whole claim's.
    function test_loneClaimantSplitSendsTheThirdToTheHarvest() public {
        uint256 a1 = buy(alice, 2, 100);
        uint256 a2 = buy(alice, 2, 100);
        harvestDay0();
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 together = game.claim(ids2(a1, a2));
        uint256 potTogether = game.getDay(game.today()).pot;
        vm.revertToState(snap);

        vm.prank(alice);
        uint256 p1 = game.claim(ids1(a1));
        assertGt(game.bonusIndex(), 0);
        vm.prank(alice);
        uint256 p2 = game.claim(ids1(a2));
        assertApproxEqAbs(p1 + p2, together, 2);
        assertApproxEqAbs(game.getDay(game.today()).pot, potTogether, 4);
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)));
    }

    // ------------------------------------------------------------------ stray GAMMA (finding 84966529)

    function test_sweepCreditsStrayGammaToTheHarvest() public {
        uint256 held = game.gammaHeld();
        gamma.transfer(address(game), 1_000e18);
        assertEq(game.gammaHeld(), held, "a plain transfer is not credited by itself");
        uint256 pot = game.getDay(game.today()).pot;

        vm.prank(carol);
        uint256 swept = game.sweep();
        assertEq(swept, 1_000e18);
        assertEq(game.gammaHeld(), held + 1_000e18);
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)));
        assertEq(game.getDay(game.today()).pot, pot + 1_000e18, "stray GAMMA funds today's Harvest");

        vm.prank(carol);
        assertEq(game.sweep(), 0, "nothing left to sweep");
    }

    function test_sweepNeedsInitialize() public {
        GammaGame fresh = new GammaGame(game.poolManager(), imd, beacon, address(this));
        vm.expectRevert(GammaGame.NotInitialized.selector);
        fresh.sweep();
    }

    function test_sweptGammaIsPaidOutThroughTheHarvest() public {
        uint256 a1 = buy(alice, 3, 100); // Air: 90% fail, failures split the Harvest
        gamma.transfer(address(game), 5_000e18);
        game.sweep();
        harvestDay0();
        GammaGame.Day memory day = game.getDay(0);
        assertGt(day.perFail, 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        uint256 paid = game.claimMatured(ids1(a1));
        assertEq(paid, winningsOf(a1) - winningsOf(a1) * 1_000 / 10_000);
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)));
    }
}
