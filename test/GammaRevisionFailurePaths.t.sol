// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GammaFixture} from "./utils/GammaFixture.sol";
import {GammaGame} from "src/GammaGame.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Failure paths of the revised purchase guard, conversion bound and fallback commitment.
contract GammaRevisionFailurePathsTest is GammaFixture {
    function test_rejectedPurchaseIntoProvenEpochMovesNothingAndNextEpochOpens() public {
        uint256 e = game.currentEpoch();
        beacon.set(game.roundForEpoch(e), keccak256("early"));
        uint256 imdBefore = imd.balanceOf(alice);
        uint256 deadBefore = gamma.balanceOf(game.DEAD());
        uint256 count = game.batchCount();
        vm.prank(alice);
        vm.expectRevert(GammaGame.EpochSeedKnown.selector);
        game.buyEnergies(0, 1, 2_000e18, noProofs);
        assertEq(imd.balanceOf(alice), imdBefore);
        assertEq(imd.balanceOf(address(game)), 0);
        assertEq(gamma.balanceOf(game.DEAD()), deadBefore);
        assertEq(game.batchCount(), count);

        vm.warp(game.epochEnd(e) + 1);
        uint256 id = buy(alice, 0, 1);
        assertEq(game.getBatch(id).epoch, e + 1);
    }

    /// @dev Change 10 replaced the last-block observation (obsPrice/obsBlock) with a rate-limited reference.
    /// The first observation seeds it from the pool rather than leaving conversion disabled, so the test
    /// checks that seed and that the conversion then runs against it and cannot move it twice in one block.
    function test_firstObservationSeedsReferenceThenConvertsAtIt() public {
        // No non-game swap has happened since genesis, so nothing has observed the pool yet.
        assertEq(game.refPrice(), 0);
        assertEq(game.refTime(), 0);

        swapExactOutBuy(bob, 50_000e18); // the hook's IMD fee report is the first observation
        uint256 pending = game.pendingImd();
        assertGt(pending, 0);
        uint160 seeded = game.refPrice();
        assertGt(seeded, 0, "first observation seeds the reference");
        assertEq(game.refTime(), uint64(block.timestamp));

        uint256 held = game.gammaHeld();
        game.convertPendingImd(0);
        assertLt(game.pendingImd(), pending, "conversion ran at the freshly seeded reference");
        assertGt(game.gammaHeld(), held);
        // Same timestamp: _observe may not move the reference a second time.
        assertEq(game.refPrice(), seeded);
    }

    function test_partialFillAtBoundKeepsRemainderBacked() public {
        for (uint256 i; i < 5; ++i) {
            swapExactOutBuy(bob, 2_000_000e18);
            swapExactIn(bob, true, gamma.balanceOf(bob));
        }
        uint256 pending = game.pendingImd();
        vm.roll(vm.getBlockNumber() + 1);
        // Thin the pool so the pending IMD cannot all be sold within the 1% sqrt-price bound.
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: -99_990_000e18,
                salt: 0
            }),
            ""
        );
        uint256 potBefore = game.getDay(game.today()).pot;
        uint256 gammaBefore = gamma.balanceOf(address(game));
        game.convertPendingImd(0);
        uint256 left = game.pendingImd();
        assertGt(left, 0, "bound reached before all IMD was sold");
        assertLt(left, pending, "something was sold");
        assertEq(imd.balanceOf(address(game)), left, "remainder is exactly the unsold IMD");
        uint256 out = gamma.balanceOf(address(game)) - gammaBefore;
        assertGt(out, 0);
        assertEq(game.getDay(game.today()).pot - potBefore, out);
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)));

        // The same block cannot be used to push past the bound again: the price is already at it.
        game.convertPendingImd(0);
        assertEq(game.pendingImd(), left);
    }

    /// @dev Change 9 makes a commitment binding: an expired hash is not an invitation to ask for drand again.
    /// Until the one-day recommit delay the epoch simply waits, and the frontend is not asked for a proof.
    function test_expiredCommitmentStaysBindingAndAsksForNoProof() public {
        uint256 e = game.currentEpoch();
        buy(alice, 1, 10);
        vm.warp(game.epochEnd(e) + 2 hours);
        vm.roll(1000);
        game.settle(256, noProofs);
        assertEq(game.fallbackBlock(e), 1000);
        assertEq(game.pendingRound(), 0, "no proof asked for once committed");
        vm.roll(1300); // 300 blocks later: the committed hash is gone
        beacon.set(game.roundForEpoch(e), keccak256("late"));
        game.settle(256, noProofs);
        assertEq(game.fallbackBlock(e), 1000, "the commitment is not replaced");
        assertEq(game.epochSeed(e), bytes32(0), "unread hash, not a drand seed");
        assertEq(game.pendingRound(), 0, "still no proof asked for");
        assertEq(game.cursor(), e, "the epoch waits rather than taking drand");
        // A purchase in the meantime still works and does not settle the stuck epoch.
        uint256 id = buy(bob, 0, 1);
        assertEq(game.getBatch(id).epoch, game.currentEpoch());
        assertEq(game.cursor(), e);
    }
}
