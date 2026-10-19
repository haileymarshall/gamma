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



}
