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

    function test_convertWithoutAnyEarlierObservationIsNoOp() public {
        // The fixture's pool saw no swap yet: no observation exists in any block.
        assertEq(game.obsPrice(), 0);
        swapExactOutBuy(bob, 50_000e18);
        uint256 pending = game.pendingImd();
        assertGt(pending, 0);
        uint256 held = game.gammaHeld();
        game.convertPendingImd(type(uint256).max); // returns before the slippage check could fire
        assertEq(game.pendingImd(), pending);
        assertEq(game.gammaHeld(), held);
        assertEq(game.obsBlock(), vm.getBlockNumber());
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

    function test_expiredCommitmentKeepsAskingForDrand() public {
        uint256 e = game.currentEpoch();
        buy(alice, 1, 10);
        vm.warp(game.epochEnd(e) + 2 hours);
        vm.roll(1000);
        game.settle(256, noProofs);
        assertEq(game.fallbackBlock(e), 1000);
        assertEq(game.pendingRound(), game.roundForEpoch(e));
        vm.roll(1300);
        game.settle(256, noProofs);
        assertEq(game.fallbackSeed(e), bytes32(0));
        assertEq(game.pendingRound(), game.roundForEpoch(e), "stuck epoch must still ask for its round");
        // A purchase in the meantime still works and does not settle the stuck epoch.
        uint256 id = buy(bob, 0, 1);
        assertEq(game.getBatch(id).epoch, game.currentEpoch());
        assertEq(game.cursor(), e);
    }
}
