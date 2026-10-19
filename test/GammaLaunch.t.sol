// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {GammaFixture} from "./utils/GammaFixture.sol";
import {GammaGame} from "src/GammaGame.sol";
import {DrandBeacon} from "src/DrandBeacon.sol";
import {IGammaBeacon} from "src/interfaces/IGammaBeacon.sol";
import {IGammaGame} from "src/interfaces/IGammaGame.sol";

/// @dev A hook-shaped contract a configurator controls: it answers the game's binding checks correctly but
/// reports fees it never paid.
contract LyingHook {
    IGammaGame public game;
    bytes32 public poolId;

    constructor(IGammaGame game_) {
        game = game_;
    }

    function setPoolId(bytes32 poolId_) external {
        poolId = poolId_;
    }

    function report(Currency currency, uint256 amount) external {
        game.onHookFee(currency, amount);
    }
}

/// @dev Settles, reads its own result and reverts with it: the probe a grinder runs every block for free.
contract Grinder {
    error Outcome(uint256 survivors, uint8[4] deal);

    function attempt(GammaGame game, uint256 batchId, uint256 epoch) external {
        GammaGame.BeaconProof[] memory none;
        game.settle(256, none);
        GammaGame.Batch memory b = game.getBatch(batchId);
        (,,, uint8[4] memory deal,,) = game.getEpoch(epoch);
        revert Outcome(b.survivors, deal);
    }
}

/// @notice The changes made for the launch (see ADAPTATION.md): a pool key is checked against the hook it names,
/// hook fees are only credited when the tokens arrived, and the fallback seed is committed before it is read.
contract GammaLaunchTest is GammaFixture {
    // ------------------------------------------------------------------ initialize checks the wiring

    function _fundedGame() internal returns (GammaGame g2) {
        g2 = new GammaGame(manager, imd, beacon, address(this));
        deal(address(gamma), address(g2), g2.RESERVE());
    }

    function test_initializeRejectsKeyOfAnotherPool() public {
        GammaGame g2 = _fundedGame();
        PoolKey memory wrong = key;
        wrong.fee = 500; // the pool was initialized at 12_500: this key names a pool that does not exist
        vm.expectRevert(GammaGame.BadPool.selector);
        g2.initialize(wrong);
    }

    function test_initializeRejectsHookBoundToAnotherGame() public {
        GammaGame g2 = _fundedGame();
        PoolKey memory k = key; // the real hook, which is bound to `game`, not to g2
        vm.expectRevert(GammaGame.BadPool.selector);
        g2.initialize(k);
    }

    function test_initializeRejectsHookWithoutCode() public {
        GammaGame g2 = _fundedGame();
        PoolKey memory k = key;
        k.hooks = IHooks(address(uint160(0x5555 << 144) | 0x20)); // mined flags, no contract behind it
        vm.expectRevert();
        g2.initialize(k);
    }

    function test_initializeRecordsHeldGamma() public view {
        assertEq(game.gammaHeld(), game.RESERVE());
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)));
    }

    // ------------------------------------------------------------------ hook fees must be backed

    function _lyingHookGame() internal returns (GammaGame g2, LyingHook lying, PoolKey memory k) {
        g2 = _fundedGame();
        k = key;
        // The configurator picks a pool whose hook it controls; the hook passes every binding check.
        lying = new LyingHook(IGammaGame(address(g2)));
        k.hooks = IHooks(address(lying));
        lying.setPoolId(keccak256(abi.encode(k)));
        g2.initialize(k);
    }

    function test_unbackedGammaFeeIsRejected() public {
        (GammaGame g2, LyingHook lying,) = _lyingHookGame();
        vm.expectRevert(GammaGame.FeeNotReceived.selector);
        lying.report(Currency.wrap(address(gamma)), 700_000_000e18);
        vm.expectRevert(GammaGame.FeeNotReceived.selector);
        lying.report(Currency.wrap(address(gamma)), 1);
        assertEq(g2.getDay(0).pot, 0);
    }

    function test_backedGammaFeeIsCredited() public {
        (GammaGame g2, LyingHook lying,) = _lyingHookGame();
        gamma.transfer(address(g2), 1_000e18);
        lying.report(Currency.wrap(address(gamma)), 1_000e18);
        assertEq(g2.getDay(0).pot, 1_000e18);
        assertEq(g2.gammaHeld(), gamma.balanceOf(address(g2)));
        // The same tokens cannot be reported twice.
        vm.expectRevert(GammaGame.FeeNotReceived.selector);
        lying.report(Currency.wrap(address(gamma)), 1);
    }

    function test_imdFeeMustBeBacked() public {
        (GammaGame g2, LyingHook lying,) = _lyingHookGame();
        vm.expectRevert(GammaGame.FeeNotReceived.selector);
        lying.report(Currency.wrap(address(imd)), 5e18);
        imd.mint(address(g2), 5e18);
        lying.report(Currency.wrap(address(imd)), 5e18);
        assertEq(g2.pendingImd(), 5e18);
        vm.expectRevert(GammaGame.FeeNotReceived.selector);
        lying.report(Currency.wrap(address(imd)), 1);
    }

    function test_configuratorCannotDrainReserveThroughItsHook() public {
        (GammaGame g2, LyingHook lying,) = _lyingHookGame();
        // Even if the lie were accepted, nothing in the Reserve moves: the pot stays what day 0 really emitted.
        try lying.report(Currency.wrap(address(gamma)), 700_000_000e18) {} catch {}
        vm.warp(g2.dayEnd(0) + 2 days);
        vm.roll(block.number + 1);
        for (uint256 i; i < 50 && g2.cursor() < g2.currentEpoch(); ++i) {
            g2.settle(256, noProofs);
            vm.roll(block.number + 1);
        }
        GammaGame.Day memory day0 = g2.getDay(0);
        assertLe(day0.pot, g2.released(144), "the pot holds at most the day's emission");
        assertEq(gamma.balanceOf(address(g2)), g2.RESERVE(), "the Reserve is intact");
    }

    function test_hookFeesStillFlowWithTheRealHook() public {
        uint256 d = game.today();
        uint256 potBefore = game.getDay(d).pot;
        uint256 heldBefore = game.gammaHeld();
        swapExactIn(bob, false, 100_000e18);
        uint256 fee = game.getDay(d).pot - potBefore;
        assertGt(fee, 0);
        assertEq(game.gammaHeld() - heldBefore, fee);
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)));
    }

    function test_heldGammaFollowsEveryFlow() public {
        uint256 id = buy(alice, 1, 300);
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)), "purchase: in and burned");
        gamma.approve(address(game), 5_000e18);
        game.donate(5_000e18);
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)), "donation");
        swapExactOutBuy(bob, 50_000e18);
        game.convertPendingImd(0);
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)), "IMD fee converted");
        toNextDay();
        settleAll();
        warpDays(1);
        vm.prank(alice);
        game.claim(ids1(id));
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)), "claim: payout and burn");
    }

    // ------------------------------------------------------------------ fallback seed: commit, then read

    function test_fallbackSeedCannotBeGroundPerBlock() public {
        uint256 e = game.currentEpoch();
        uint256 id = buy(alice, 3, 16); // Air: 90% fail
        vm.warp(game.epochEnd(e) + 2 hours); // nobody proved the drand round for two hours
        vm.roll(999);
        game.settle(256, noProofs); // commits to block 999
        assertEq(game.fallbackBlock(e), 999);
        assertEq(game.cursor(), e);
        assertEq(game.pendingRound(), 0, "the commitment is binding: drand no longer counts");
        vm.setBlockhash(999, keccak256("the committed block"));

        Grinder g = new Grinder();
        uint256 first = type(uint256).max;
        for (uint256 i; i < 40; ++i) {
            uint256 n = 1000 + i;
            vm.roll(n);
            if (n - 1 != 999) vm.setBlockhash(n - 1, keccak256(abi.encode("block", n)));
            try g.attempt(game, id, e) {}
            catch (bytes memory reason) {
                (uint256 s,) = abi.decode(_strip(reason), (uint256, uint8[4]));
                if (first == type(uint256).max) first = s;
                assertEq(s, first, "settlement outcome changes with the block the caller picks");
            }
        }
        assertLt(first, type(uint256).max, "the probe ran");

        // A real settlement stores the seed; it matches what every probe saw.
        game.settle(256, noProofs);
        assertEq(game.getBatch(id).survivors, first);
        assertEq(game.fallbackSeed(e), keccak256(abi.encode(keccak256("the committed block"), e, "fallback")));
        assertGt(game.cursor(), e);
    }

    function test_fallbackSeedIsOneSeedForTheWholeEpoch() public {
        uint256 e = game.currentEpoch();
        uint256 a = buy(alice, 0, 100);
        uint256 b = buy(bob, 0, 100);
        vm.warp(game.epochEnd(e) + 2 hours);
        vm.roll(1000);
        game.settle(1, noProofs); // commit
        vm.roll(1001);
        vm.setBlockhash(1000, keccak256("h"));
        game.settle(1, noProofs); // reads the hash, stores the seed, draws the first batch
        bytes32 seed = game.fallbackSeed(e);
        assertTrue(game.getBatch(a).drawn);
        assertFalse(game.getBatch(b).drawn);

        vm.roll(1001 + 300); // the hash of block 1000 is gone
        assertEq(blockhash(1000), bytes32(0));
        game.settle(256, noProofs);
        assertTrue(game.getBatch(b).drawn);
        assertEq(game.fallbackSeed(e), seed, "second batch drawn under the same seed");
        assertEq(game.getBatch(b).survivors, game.drawSurvivors(seed, b, 100, game.failBps(0)));
    }

    /// Revision finding a48fbd6d / f9624bc3: an expired fallback is renewed only a day later, never by drand.
    function test_expiredFallbackRecommitsOnlyAfterDelay() public {
        uint256 e = game.currentEpoch();
        buy(alice, 2, 10);
        vm.warp(game.epochEnd(e) + 2 hours);
        vm.roll(1000);
        game.settle(256, noProofs);
        assertEq(game.fallbackBlock(e), 1000);
        vm.roll(1300); // nobody read it for 256 blocks
        beacon.set(game.roundForEpoch(e), keccak256("drand"));
        game.settle(256, noProofs);
        assertEq(game.fallbackBlock(e), 1000, "commitment is binding");
        assertEq(game.cursor(), e, "drand is not a second option once committed");
        assertEq(game.epochSeed(e), bytes32(0));
        vm.warp(block.timestamp + game.FALLBACK_RECOMMIT_DELAY());
        game.settle(256, noProofs);
        assertEq(game.fallbackBlock(e), 1300, "renewed after the delay");
        vm.roll(1301);
        vm.setBlockhash(1300, keccak256("h"));
        game.settle(256, noProofs);
        assertGt(game.cursor(), e);
        assertEq(game.epochSeed(e), keccak256(abi.encode(keccak256("h"), e, "fallback")));
    }

    /// Revision finding f9624bc3: once committed, proving the drand round does not change the epoch's seed.
    function test_proofAfterCommitmentDoesNotChooseSeed() public {
        uint256 e = game.currentEpoch();
        buy(alice, 2, 10);
        vm.warp(game.epochEnd(e) + 2 hours);
        vm.roll(1000);
        game.settle(256, noProofs);
        assertEq(game.pendingRound(), 0, "no proof is asked for once committed");
        beacon.set(game.roundForEpoch(e), keccak256("late"));
        vm.roll(1001);
        vm.setBlockhash(1000, keccak256("h"));
        game.settle(256, noProofs);
        assertGt(game.cursor(), e);
        assertEq(game.epochSeed(e), keccak256(abi.encode(keccak256("h"), e, "fallback")));
    }

    function test_proofBeforeFallbackStillWins() public {
        uint256 e = game.currentEpoch();
        buy(alice, 2, 10);
        vm.warp(game.epochEnd(e) + 2 hours);
        beacon.set(game.roundForEpoch(e), keccak256("in time"));
        game.settle(256, noProofs);
        assertGt(game.cursor(), e);
        assertEq(game.fallbackBlock(e), 0);
        assertEq(game.epochSeed(e), keccak256(abi.encode(keccak256("in time"), e)));
    }

    function _strip(bytes memory r) internal pure returns (bytes memory out) {
        out = new bytes(r.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = r[i + 4];
        }
    }
}

/// @notice Rehearses what the launch factory does: both contracts are created on an empty chain, in one call,
/// with the brief's constructor arguments, and nothing else is needed for them to exist.
contract GammaLaunchDeployTest is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant OWNER = 0x4De63474F3715C407DaFAa1429FA664559814401;

    function test_constructorsNeedNoOtherContract() public {
        vm.chainId(4663);
        assertEq(POOL_MANAGER.code.length, 0);
        assertEq(IMD.code.length, 0);
        DrandBeacon beacon = new DrandBeacon();
        GammaGame game = new GammaGame(IPoolManager(POOL_MANAGER), ERC20(IMD), IGammaBeacon(address(beacon)), OWNER);

        assertEq(address(game.poolManager()), POOL_MANAGER);
        assertEq(address(game.imd()), IMD);
        assertEq(address(game.beacon()), address(beacon));
        assertEq(game.configurator(), OWNER, "the configurator is the owner the launch names, never the factory");
        assertEq(game.genesis(), 0);
        assertEq(beacon.genesis(), 1727521075);
        assertEq(beacon.period(), 3);

        _checkRuntime(address(beacon).code);
        _checkRuntime(address(game).code);
    }

    function _checkRuntime(bytes memory code) internal pure {
        assertGt(code.length, 0, "missing runtime");
        assertLe(code.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }
    }
}
