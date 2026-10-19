// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GammaFixture} from "./utils/GammaFixture.sol";
import {GammaGame} from "src/GammaGame.sol";
import {GammaHook} from "src/GammaHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {stdError} from "forge-std/StdError.sol";

contract GammaFailurePathsTest is GammaFixture {
    function test_uninitializedEntryPointsRejectWithoutMovingTokens() public {
        GammaGame fresh = new GammaGame(manager, imd, beacon, address(this));
        vm.expectRevert(GammaGame.NotInitialized.selector);
        fresh.buyEnergies(0, 1, 2_000e18, noProofs);
        vm.expectRevert(GammaGame.NotInitialized.selector);
        fresh.settle(1, noProofs);
        vm.expectRevert(GammaGame.NotInitialized.selector);
        fresh.donate(1);
        vm.expectRevert(GammaGame.NotInitialized.selector);
        fresh.claim(new uint256[](0));
        vm.expectRevert(GammaGame.NotInitialized.selector);
        fresh.claimMatured(new uint256[](0));
        assertEq(fresh.batchCount(), 0);
        assertEq(fresh.totalBurned(), 0);
        assertEq(fresh.gammaHeld(), 0);
        assertEq(fresh.genesis(), 0);
    }

    function test_unlockCallbackCannotBeCalledByPlayerOrConfigurator() public {
        bytes memory data = abi.encode(false, 1_000e18, 2_000e18);
        vm.prank(alice);
        vm.expectRevert(GammaGame.NotPoolManager.selector);
        game.unlockCallback(data);
        vm.expectRevert(GammaGame.NotPoolManager.selector);
        game.unlockCallback(data);
        assertEq(gamma.balanceOf(address(game)), game.RESERVE());
    }

    function test_failedSlippageRollsBackAutoSettlementAndTransfer() public {
        uint256 id = buy(alice, 1, 20);
        uint256 e = game.getBatch(id).epoch;
        vm.warp(game.epochEnd(e) + 10);
        beacon.set(game.roundForEpoch(e), keccak256("rollback seed"));
        uint256 cursorBefore = game.cursor();
        uint256 imdBefore = imd.balanceOf(bob);
        uint256 heldBefore = game.gammaHeld();
        uint256 deadBefore = gamma.balanceOf(game.DEAD());
        uint256 countBefore = game.batchCount();

        vm.prank(bob);
        vm.expectRevert(GammaGame.SlippageExceeded.selector);
        game.buyEnergies(2, 10, 1, noProofs);

        assertEq(game.cursor(), cursorBefore, "failed buy persisted settlement");
        assertFalse(game.getBatch(id).drawn);
        assertEq(imd.balanceOf(bob), imdBefore);
        assertEq(imd.balanceOf(address(game)), 0);
        assertEq(game.gammaHeld(), heldBefore);
        assertEq(gamma.balanceOf(game.DEAD()), deadBefore);
        assertEq(game.batchCount(), countBefore);
        // The failed call must not leave the reentrancy lock engaged.
        buy(bob, 2, 10);
        assertTrue(game.getBatch(id).drawn);
    }

    function test_missingAllowanceAndBalanceCannotCreateFreeEnergies() public {
        uint256 count = game.batchCount();
        uint256 deadBefore = gamma.balanceOf(game.DEAD());
        vm.prank(alice);
        imd.approve(address(game), 0);
        vm.prank(alice);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        game.buyEnergies(0, 1, 2_000e18, noProofs);
        address unfunded = makeAddr("unfunded player");
        vm.prank(unfunded);
        imd.approve(address(game), type(uint256).max);
        vm.prank(unfunded);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        game.buyEnergies(0, 1, 2_000e18, noProofs);
        assertEq(game.batchCount(), count);
        assertEq(game.totalEnergies(), 0);
        assertEq(gamma.balanceOf(game.DEAD()), deadBefore);
    }

    function test_failedDonationDoesNotFundHarvest() public {
        uint256 potBefore = game.getDay(game.today()).pot;
        uint256 heldBefore = game.gammaHeld();
        vm.prank(alice);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        game.donate(1);
        assertEq(game.getDay(game.today()).pot, potBefore);
        assertEq(game.gammaHeld(), heldBefore);
    }

    function test_zeroDonationIsNoOp() public {
        uint256 potBefore = game.getDay(game.today()).pot;
        uint256 heldBefore = game.gammaHeld();
        game.donate(0);
        assertEq(game.getDay(game.today()).pot, potBefore);
        assertEq(game.gammaHeld(), heldBefore);
    }

    function test_failedConversionRestoresPendingImdAndCanBeRetried() public {
        swapExactOutBuy(bob, 50_000e18);
        uint256 pendingBefore = game.pendingImd();
        uint256 gammaBefore = gamma.balanceOf(address(game));
        uint256 potBefore = game.getDay(game.today()).pot;
        assertGt(pendingBefore, 0);

        vm.expectRevert(GammaGame.SlippageExceeded.selector);
        game.convertPendingImd(type(uint256).max);
        assertEq(game.pendingImd(), pendingBefore);
        assertEq(imd.balanceOf(address(game)), pendingBefore);
        assertEq(gamma.balanceOf(address(game)), gammaBefore);
        assertEq(game.getDay(game.today()).pot, potBefore);

        vm.prank(carol);
        game.convertPendingImd(0);
        uint256 out = gamma.balanceOf(address(game)) - gammaBefore;
        assertGt(out, 0);
        assertEq(game.pendingImd(), 0);
        assertEq(imd.balanceOf(address(game)), 0);
        assertEq(game.getDay(game.today()).pot - potBefore, out);
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)));
        // With nothing pending even an impossible minimum has no effect.
        game.convertPendingImd(type(uint256).max);
        assertEq(gamma.balanceOf(address(game)), gammaBefore + out);
    }

    function test_claimArrayWithForeignBatchRevertsEveryEarlierClaim() public {
        uint256 a = buy(alice, 3, 100);
        uint256 b = buy(bob, 3, 100);
        toNextDay();
        settleAll();
        uint256 heldBefore = game.gammaHeld();
        uint256 unclaimedBefore = game.totalUnclaimed();
        uint256 indexBefore = game.bonusIndex();
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        vm.prank(alice);
        vm.expectRevert(GammaGame.NotOwner.selector);
        game.claim(ids);
        assertFalse(game.getBatch(a).claimed);
        assertFalse(game.getBatch(b).claimed);
        assertEq(game.totalUnclaimed(), unclaimedBefore);
        assertEq(game.bonusIndex(), indexBefore);
        assertEq(game.gammaHeld(), heldBefore);
        assertEq(gamma.balanceOf(alice), 0);
    }

    function test_outOfRangeClaimRevertsAndEmptyClaimsAreNoOps() public {
        uint256 id = buy(alice, 3, 100);
        toNextDay();
        settleAll();
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = game.batchCount();
        vm.prank(alice);
        vm.expectRevert(stdError.indexOOBError);
        game.claim(ids);
        assertFalse(game.getBatch(id).claimed);
        uint256 unclaimed = game.totalUnclaimed();
        vm.prank(alice);
        assertEq(game.claim(new uint256[](0)), 0);
        assertEq(game.totalUnclaimed(), unclaimed);
    }

    function test_duplicateBatchIdsCannotMultiplyPayoutOrBonus() public {
        uint256 id = buy(alice, 3, 100);
        buy(bob, 3, 100);
        toNextDay();
        settleAll();
        uint256 beforeState = vm.snapshotState();
        vm.prank(alice);
        uint256 once = game.claim(ids1(id));
        uint256 unclaimed = game.totalUnclaimed();
        uint256 held = game.gammaHeld();
        uint256 index = game.bonusIndex();
        uint256 burned = game.totalBurned();
        vm.revertToState(beforeState);
        uint256[] memory ids = new uint256[](3);
        ids[0] = id;
        ids[1] = id;
        ids[2] = id;
        vm.prank(alice);
        uint256 repeated = game.claim(ids);
        assertGt(once, 0);
        assertEq(repeated, once);
        assertEq(game.totalUnclaimed(), unclaimed);
        assertEq(game.gammaHeld(), held);
        assertEq(game.bonusIndex(), index);
        assertEq(game.totalBurned(), burned);
    }

    function test_initializeRollbackAllowsCorrectKeyAfterMistake() public {
        GammaGame fresh = new GammaGame(manager, imd, beacon, address(this));
        PoolKey memory k = key;
        uint160 flags = uint160(address(hook)) & ((1 << 14) - 1);
        address freshHook = address(uint160(0x7777 << 144) | flags);
        deployCodeTo("GammaHook.sol:GammaHook", abi.encode(address(manager), address(imd), address(fresh)), freshHook);
        k.hooks = IHooks(freshHook);
        manager.initialize(k, SQRT_PRICE_1_1);
        deal(address(gamma), address(fresh), fresh.RESERVE() + 123);

        PoolKey memory wrong = abi.decode(abi.encode(k), (PoolKey));
        wrong.tickSpacing += 1;
        vm.expectRevert(GammaGame.BadPool.selector);
        fresh.initialize(wrong);
        assertEq(fresh.genesis(), 0);
        assertEq(address(fresh.gamma()), address(0));
        assertEq(fresh.hook(), address(0));
        assertEq(fresh.gammaHeld(), 0);
        assertEq(fresh.getDay(0).pot, 0);

        fresh.initialize(k);
        assertEq(fresh.genesis(), block.timestamp);
        assertEq(fresh.hook(), freshHook);
        assertEq(fresh.gammaHeld(), fresh.RESERVE() + 123);
        assertEq(fresh.getDay(0).pot, 123, "initial surplus belongs to Harvest");
        vm.expectRevert(GammaGame.AlreadyInitialized.selector);
        fresh.initialize(k);
    }

    function test_initializeRejectsMissingImdOrHookBeforeFunding() public {
        GammaGame fresh = new GammaGame(manager, imd, beacon, address(this));
        PoolKey memory k = key;
        k.currency0 = Currency.wrap(address(gamma));
        k.currency1 = Currency.wrap(address(gamma));
        vm.expectRevert(GammaGame.BadPool.selector);
        fresh.initialize(k);
        k = key;
        k.hooks = IHooks(address(0));
        vm.expectRevert(GammaGame.BadPool.selector);
        fresh.initialize(k);
        assertEq(fresh.genesis(), 0);
    }
}
