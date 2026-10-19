// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GammaFixture, MockBeacon} from "./utils/GammaFixture.sol";
import {GammaGame} from "src/GammaGame.sol";
import {GammaToken} from "src/GammaToken.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev Drives the game through random sequences and checks, after every call, that nothing finished ever changes:
/// a drawn batch keeps its survivors, a claimed batch stays claimed, a finalized epoch or Harvest keeps its numbers,
/// and the global indexes and counters only move forward. Claims made on a fully settled game must pay exactly what
/// `userBatches` promised. Expected failures (foreign batch, buying into a proven epoch) are asserted as reverts.
contract GammaStateMachineHandler is Test {
    GammaGame public immutable game;
    MockBeacon internal immutable beacon;
    GammaToken internal immutable gamma;
    MockERC20 internal immutable imd;
    address[3] public actors;
    GammaGame.BeaconProof[] internal none;

    uint256 public stray;
    uint256 public exactClaims;
    uint256 public knownEpochRejections;
    uint256 public foreignRejections;

    // frozen-state ghosts
    mapping(uint256 => bool) internal _seenDrawn;
    mapping(uint256 => uint16) internal _survivors;
    mapping(uint256 => bool) internal _seenClaimed;
    mapping(uint256 => bytes32) internal _dayHash;
    mapping(uint256 => bytes32) internal _epochHash;
    mapping(address => uint256) internal _selfIndex;
    uint256 internal _bonusIndex;
    uint256 internal _burned;
    uint256 internal _cursor;
    uint256 internal _activeCursor;
    uint256 internal _batchCount;

    constructor(GammaGame game_, MockBeacon beacon_, GammaToken gamma_, MockERC20 imd_, address[3] memory actors_) {
        game = game_;
        beacon = beacon_;
        gamma = gamma_;
        imd = imd_;
        actors = actors_;
        _check();
    }

    // ------------------------------------------------------------------ actions

    function buy(uint256 who, uint8 machineSeed, uint256 amount) external {
        address actor = actors[who % 3];
        uint8 machine = machineSeed % 4;
        uint256 max = 40;
        if (block.timestamp < game.genesis() + game.GUARD_PERIOD()) {
            (uint32[4] memory used,,,,,) = game.getEpoch(game.currentEpoch());
            uint256 capacity = game.GUARD_ENERGIES_PER_MACHINE() - used[machine];
            if (max > capacity) max = capacity;
        }
        if (max == 0) return;
        amount = bound(amount, 1, max);
        bool known = beacon.randomness(game.roundForEpoch(game.currentEpoch())) != bytes32(0);
        vm.prank(actor);
        if (known) vm.expectRevert(GammaGame.EpochSeedKnown.selector);
        game.buyEnergies(machine, amount, amount * 2_000e18, none);
        _check();
    }

    /// @dev The current epoch's drand round appears on-chain early (a lagging clock): no purchase may enter it,
    /// and the rejection moves nothing.
    function buyIntoKnownEpoch(uint256 who, uint8 machineSeed) external {
        address actor = actors[who % 3];
        uint64 round = game.roundForEpoch(game.currentEpoch());
        if (beacon.randomness(round) == bytes32(0)) beacon.set(round, keccak256(abi.encode("early", round)));
        uint256 imdBefore = imd.balanceOf(actor);
        uint256 countBefore = game.batchCount();
        vm.prank(actor);
        vm.expectRevert(GammaGame.EpochSeedKnown.selector);
        game.buyEnergies(machineSeed % 4, 1, 2_000e18, none);
        assertEq(imd.balanceOf(actor), imdBefore);
        assertEq(game.batchCount(), countBefore);
        ++knownEpochRejections;
        _check();
    }

    function advance(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 1, 30 hours));
        vm.roll(vm.getBlockNumber() + 1);
        _check();
    }

    function settle(uint256 unitsSeed, bool prove) external {
        if (prove) _proveClosed();
        game.settle(bound(unitsSeed, 0, 64), none);
        _check();
    }

    function donate(uint256 amount, bool raw) external {
        amount = bound(amount, 0, gamma.balanceOf(address(this)));
        if (raw) {
            gamma.transfer(address(game), amount);
            stray += amount;
        } else {
            gamma.approve(address(game), amount);
            game.donate(amount);
        }
        _check();
    }

    function sweep() external {
        uint256 potBefore = game.getDay(game.today()).pot;
        uint256 swept = game.sweep();
        assertEq(swept, stray, "sweep credited something other than the stray balance");
        assertEq(game.getDay(game.today()).pot - potBefore, swept);
        stray = 0;
        _check();
    }

    /// @dev On a fully settled game the claim must pay exactly what the view shows for the chosen batches.
    function claimExact(uint256 who, uint256 mask, bool maturedOnly) external {
        address actor = actors[who % 3];
        _proveClosed();
        for (uint256 i; i < 8 && game.cursor() < game.currentEpoch(); ++i) {
            game.settle(256, none);
        }
        // A Harvest exactly at the current epoch may still be pending if the cursor is at it.
        if (game.cursor() != game.currentEpoch()) return;
        uint256 e = game.cursor();
        if (e != 0 && e % 144 == 0 && !game.getDay(e / 144 - 1).finalized) return;

        GammaGame.BatchView[] memory v = game.userBatches(actor, 0, game.userBatchCount(actor));
        uint256 n;
        for (uint256 i; i < v.length && i < 256; ++i) {
            if ((mask >> i) & 1 == 1) ++n;
        }
        uint256[] memory ids = new uint256[](n);
        uint256 expected;
        uint256 k;
        for (uint256 i; i < v.length && i < 256; ++i) {
            if ((mask >> i) & 1 == 0) continue;
            ids[k++] = v[i].id;
            if (v[i].claimed || !v[i].harvested) continue;
            if (maturedOnly && v[i].feeBps > 1_000) continue;
            expected += v[i].winnings - v[i].winnings * v[i].feeBps / 10_000 + v[i].bonus;
        }
        uint256 before = gamma.balanceOf(actor);
        vm.prank(actor);
        uint256 paid = maturedOnly ? game.claimMatured(ids) : game.claim(ids);
        assertEq(paid, expected, "claim paid something other than the view promised");
        assertEq(gamma.balanceOf(actor) - before, paid);
        if (paid > 0) ++exactClaims;
        _check();
    }

    /// @dev Claims without settling first: settlement bundled into the claim may harvest on the way.
    function claimLagging(uint256 who) external {
        address actor = actors[who % 3];
        uint256 count = game.userBatchCount(actor);
        GammaGame.BatchView[] memory v = game.userBatches(actor, 0, count);
        uint256[] memory ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = v[i].id;
        }
        uint256 before = gamma.balanceOf(actor);
        vm.prank(actor);
        uint256 paid = game.claim(ids);
        assertEq(gamma.balanceOf(actor) - before, paid);
        _check();
    }

    function foreignClaim(uint256 who, uint256 idSeed) external {
        uint256 count = game.batchCount();
        if (count == 0) return;
        uint256 id = bound(idSeed, 0, count - 1);
        address owner = game.getBatch(id).owner;
        address actor = actors[who % 3];
        if (actor == owner) actor = actors[(who % 3 + 1) % 3];
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(actor);
        vm.expectRevert(GammaGame.NotOwner.selector);
        game.claim(ids);
        ++foreignRejections;
        _check();
    }

    // ------------------------------------------------------------------ helpers

    function finish() external {
        vm.warp(game.dayEnd(game.today()) + 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        _proveClosed();
        for (uint256 i; i < 16 && game.cursor() < game.currentEpoch(); ++i) {
            game.settle(256, none);
        }
        assertEq(game.cursor(), game.currentEpoch(), "settlement cannot catch up");
        for (uint256 i; i < 3; ++i) {
            address actor = actors[i];
            uint256 count = game.userBatchCount(actor);
            GammaGame.BatchView[] memory v = game.userBatches(actor, 0, count);
            uint256[] memory ids = new uint256[](count);
            uint256 expected;
            for (uint256 j; j < count; ++j) {
                ids[j] = v[j].id;
                if (v[j].claimed) continue;
                assertTrue(v[j].harvested, "a batch is still unharvested a day after its Harvest");
                assertEq(v[j].feeBps, 1_000);
                expected += v[j].winnings - v[j].winnings / 10 + v[j].bonus;
            }
            vm.prank(actor);
            assertEq(game.claimMatured(ids), expected, "final claim paid something other than the view promised");
        }
        assertEq(game.totalUnclaimed(), 0, "matured winnings could not all exit");
        _check();
    }

    function _proveClosed() internal {
        for (uint256 i = game.activeCursor(); i < game.activeEpochCount(); ++i) {
            uint256 e = game.activeEpochs(i);
            if (e >= game.currentEpoch()) break;
            uint64 round = game.roundForEpoch(e);
            if (beacon.randomness(round) == bytes32(0)) beacon.set(round, keccak256(abi.encode("drand", round)));
        }
    }

    function _check() internal {
        uint256 count = game.batchCount();
        assertGe(count, _batchCount, "batches disappeared");
        _batchCount = count;
        for (uint256 i; i < count; ++i) {
            GammaGame.Batch memory b = game.getBatch(i);
            if (_seenDrawn[i]) {
                assertTrue(b.drawn, "a drawn batch was undrawn");
                assertEq(b.survivors, _survivors[i], "a drawn batch was redrawn");
            } else if (b.drawn) {
                _seenDrawn[i] = true;
                _survivors[i] = b.survivors;
            }
            if (_seenClaimed[i]) assertTrue(b.claimed, "a claimed batch reopened");
            else if (b.claimed) _seenClaimed[i] = true;
        }
        for (uint256 d; d <= game.today(); ++d) {
            GammaGame.Day memory day = game.getDay(d);
            if (!day.finalized) {
                assertEq(_dayHash[d], bytes32(0), "a Harvest reopened");
                continue;
            }
            bytes32 h = keccak256(abi.encode(day));
            if (_dayHash[d] == bytes32(0)) _dayHash[d] = h;
            else assertEq(h, _dayHash[d], "a finalized Harvest changed");
        }
        for (uint256 i; i < game.activeEpochCount(); ++i) {
            uint256 e = game.activeEpochs(i);
            (uint32[4] memory en, uint32[4] memory sv, uint256[4] memory pps, uint8[4] memory deal, bool fin,) =
                game.getEpoch(e);
            if (!fin) {
                assertEq(_epochHash[e], bytes32(0), "an epoch reopened");
                continue;
            }
            uint256 tenths;
            for (uint256 m; m < 4; ++m) {
                tenths += deal[m];
            }
            assertEq(tenths, 10, "Shares deal does not add up to 100%");
            bytes32 h = keccak256(abi.encode(en, sv, pps, deal));
            if (_epochHash[e] == bytes32(0)) _epochHash[e] = h;
            else assertEq(h, _epochHash[e], "a finalized epoch changed");
        }
        assertGe(game.bonusIndex(), _bonusIndex, "bonus index decreased");
        _bonusIndex = game.bonusIndex();
        assertGe(game.totalBurned(), _burned, "burn counter decreased");
        _burned = game.totalBurned();
        assertGe(game.cursor(), _cursor, "cursor decreased");
        _cursor = game.cursor();
        assertGe(game.activeCursor(), _activeCursor, "active cursor decreased");
        _activeCursor = game.activeCursor();
        for (uint256 i; i < 3; ++i) {
            uint256 s = game.selfBonusIndex(actors[i]);
            assertGe(s, _selfIndex[actors[i]], "self index decreased");
            assertLe(s, game.bonusIndex(), "self index above the global index");
            _selfIndex[actors[i]] = s;
        }
        assertEq(gamma.balanceOf(address(game)), game.gammaHeld() + stray, "custody mirror drifted");
        assertEq(imd.balanceOf(address(game)), 0, "the game kept IMD");
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract GammaStateMachineInvariantTest is GammaFixture {
    GammaStateMachineHandler internal h;

    function setUp() public override {
        super.setUp();
        buy(alice, 0, 60);
        buy(bob, 2, 60);
        buy(carol, 3, 60);
        toNextDay();
        settleAll();
        h = new GammaStateMachineHandler(game, beacon, gamma, imd, [alice, bob, carol]);
        gamma.transfer(address(h), 1_000_000e18);
        bytes4[] memory s = new bytes4[](9);
        s[0] = h.buy.selector;
        s[1] = h.buyIntoKnownEpoch.selector;
        s[2] = h.advance.selector;
        s[3] = h.settle.selector;
        s[4] = h.donate.selector;
        s[5] = h.sweep.selector;
        s[6] = h.claimExact.selector;
        s[7] = h.claimLagging.selector;
        s[8] = h.foreignClaim.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: s}));
    }

    function invariant_custodyMatchesMirrorPlusStray() public view {
        assertEq(gamma.balanceOf(address(game)), game.gammaHeld() + h.stray());
    }

    function invariant_reserveNeverBelowUnreleased() public view {
        // What has not been released yet is still held, on top of the harvested debt.
        assertGe(game.gammaHeld(), game.RESERVE() - game.released(game.cursor()) + game.totalUnclaimed());
    }

    function invariant_supplyFixed() public view {
        assertEq(gamma.totalSupply(), 1_000_000_000e18);
        assertEq(gamma.balanceOf(game.DEAD()), game.totalBurned());
    }

    function afterInvariant() public {
        h.finish();
        invariant_custodyMatchesMirrorPlusStray();
        invariant_reserveNeverBelowUnreleased();
    }
}

/// @dev Edge inputs that the other suites do not pin.
contract GammaEdgeCasesTest is GammaFixture {
    function test_zeroHookFeeIsANoOp() public {
        uint256 potBefore = game.getDay(game.today()).pot;
        uint256 heldBefore = game.gammaHeld();
        vm.recordLogs();
        vm.prank(address(hook));
        game.onHookFee(Currency.wrap(address(gamma)), 0);
        assertEq(vm.getRecordedLogs().length, 0, "a zero fee emitted an event");
        assertEq(game.getDay(game.today()).pot, potBefore);
        assertEq(game.gammaHeld(), heldBefore);
    }

    function test_feeReportFromConfiguratorOrPoolManagerIsRejected() public {
        gamma.transfer(address(game), 1e18);
        vm.expectRevert(GammaGame.NotHook.selector);
        game.onHookFee(Currency.wrap(address(gamma)), 1e18);
        vm.prank(address(manager));
        vm.expectRevert(GammaGame.NotHook.selector);
        game.onHookFee(Currency.wrap(address(gamma)), 1e18);
    }

    function test_hookCannotCreditTheSameTokensTwice() public {
        gamma.transfer(address(game), 5e18);
        vm.prank(address(hook));
        game.onHookFee(Currency.wrap(address(gamma)), 5e18);
        vm.prank(address(hook));
        vm.expectRevert(GammaGame.FeeNotReceived.selector);
        game.onHookFee(Currency.wrap(address(gamma)), 1);
    }

    function test_sweepWithNothingStrayReturnsZeroAndChangesNothing() public {
        uint256 potBefore = game.getDay(game.today()).pot;
        vm.recordLogs();
        assertEq(game.sweep(), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(game.getDay(game.today()).pot, potBefore);
    }

    function test_strayTransferSweptOnceOnly() public {
        gamma.transfer(address(game), 7e18);
        assertEq(game.sweep(), 7e18);
        assertEq(game.sweep(), 0);
        assertEq(gamma.balanceOf(address(game)), game.gammaHeld());
    }

    function test_settleWithZeroUnitsMovesNothing() public {
        buy(alice, 0, 10);
        vm.warp(block.timestamp + 2 days);
        seedAll();
        uint256 c = game.cursor();
        game.settle(0, noProofs);
        assertEq(game.cursor(), c);
        assertEq(game.getBatch(0).drawn, false);
    }

    function test_zeroImdLimitCannotBuyAndKeepsNoTokens() public {
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        game.buyEnergies(0, 1, 0, noProofs);
        assertEq(imd.balanceOf(alice), imdBefore);
        assertEq(game.batchCount(), 0);
    }

    function test_machineAndAmountEdgesAreRejected() public {
        vm.startPrank(alice);
        vm.expectRevert(GammaGame.BadMachine.selector);
        game.buyEnergies(4, 1, 2_000e18, noProofs);
        vm.expectRevert(GammaGame.BadMachine.selector);
        game.buyEnergies(type(uint8).max, 1, 2_000e18, noProofs);
        vm.expectRevert(GammaGame.BadAmount.selector);
        game.buyEnergies(0, 0, 2_000e18, noProofs);
        vm.expectRevert(GammaGame.BadAmount.selector);
        game.buyEnergies(0, 501, 501 * 2_000e18, noProofs);
        vm.expectRevert(GammaGame.BadAmount.selector);
        game.buyEnergies(0, type(uint256).max, type(uint256).max, noProofs);
        vm.stopPrank();
        // The largest batch is accepted.
        uint256 id = buy(alice, 3, 500);
        assertEq(game.getBatch(id).energies, 500);
    }

    function test_claimedBatchCollectsNoLaterBonus() public {
        uint256 a = buy(alice, 0, 100);
        uint256 b = buy(bob, 0, 100);
        toNextDay();
        settleAll();
        vm.prank(alice);
        uint256 first = game.claim(ids1(a));
        assertGt(first, 0);
        // Bob's claim raises the bonus index; alice's claimed batch must not draw on it.
        vm.prank(bob);
        game.claim(ids1(b));
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        assertEq(game.claim(ids1(a)), 0);
        vm.prank(alice);
        assertEq(game.claimMatured(ids1(a)), 0);
    }

    function test_claimMaturedBeforeHarvestPaysNothing() public {
        uint256 a = buy(alice, 1, 50);
        vm.warp(block.timestamp + 20 minutes);
        seedAll();
        vm.prank(alice);
        assertEq(game.claimMatured(ids1(a)), 0);
        assertFalse(game.getBatch(a).claimed);
    }

    function test_noSettlementWithoutBeaconEvenAfterManyDays() public {
        uint256 a = buy(alice, 0, 10);
        vm.warp(block.timestamp + 10 days);
        vm.roll(block.number + 100_000);
        game.settle(256, noProofs);
        assertFalse(game.getBatch(a).drawn);
        assertEq(game.cursor(), game.getBatch(a).epoch);
        assertEq(game.pendingRound(), game.roundForEpoch(game.getBatch(a).epoch));
        // Purchases keep working while settlement waits.
        buy(bob, 0, 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_survivorEdgesOfFailRate(bytes32 seed, uint256 batchId, uint256 energies) public view {
        energies = bound(energies, 0, 500);
        assertEq(game.drawSurvivors(seed, batchId, energies, 0), energies, "0% fail kills an energy");
        assertEq(game.drawSurvivors(seed, batchId, energies, 10_000), 0, "100% fail spares an energy");
        assertEq(game.drawSurvivors(seed, batchId, 0, game.failBps(0)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_failRateIsClampedToAir(uint256 machine) public view {
        machine = bound(machine, 3, type(uint256).max);
        assertEq(game.failBps(machine), 9_000);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_claimFeeEndpoints(uint256 d, uint256 dt) public {
        d = bound(d, 0, 10_000);
        uint256 end = game.dayEnd(d);
        dt = bound(dt, 0, 3 days);
        vm.warp(end + dt);
        uint256 fee = game.claimFeeBps(d);
        if (dt == 0) assertEq(fee, 8_000);
        if (dt >= 1 days) assertEq(fee, 1_000);
        assertLe(fee, 8_000);
        assertGe(fee, 1_000);
    }
}
