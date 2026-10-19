// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GammaFixture, MockBeacon} from "./utils/GammaFixture.sol";
import {GammaGame} from "src/GammaGame.sol";
import {GammaToken} from "src/GammaToken.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract GammaHandler is Test {
    GammaGame game;
    MockBeacon beacon;
    GammaToken gamma;
    MockERC20 imd;
    PoolSwapTest router;
    PoolKey key;
    bool gammaIs0;
    address[] players;
    GammaGame.BeaconProof[] none;

    uint256 public paidOut;
    uint256 public energiesBought;

    constructor(
        GammaGame game_,
        MockBeacon beacon_,
        GammaToken gamma_,
        MockERC20 imd_,
        PoolSwapTest router_,
        PoolKey memory key_,
        address[] memory players_
    ) {
        game = game_;
        beacon = beacon_;
        gamma = gamma_;
        imd = imd_;
        router = router_;
        key = key_;
        gammaIs0 = address(gamma) < address(imd);
        players = players_;
    }

    function buy(uint256 who, uint8 machine, uint256 energies) external {
        address p = players[who % players.length];
        energies = bound(energies, 1, 500);
        vm.prank(p);
        try game.buyEnergies(machine % 4, energies, energies * 2_000e18, none) {
            energiesBought += energies;
        } catch {}
    }

    function claim(uint256 who, uint256 matured) external {
        address p = players[who % players.length];
        GammaGame.BatchView[] memory v = game.userBatches(p, 0, 20);
        if (v.length == 0) return;
        uint256[] memory ids = new uint256[](v.length);
        for (uint256 i; i < v.length; ++i) {
            ids[i] = v[i].id;
        }
        vm.prank(p);
        paidOut += matured % 2 == 0 ? game.claim(ids) : game.claimMatured(ids);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 minutes, 30 hours));
        // Blocks pass with time, so a committed fallback seed can be read (settlement needs a later block).
        vm.roll(block.number + 1);
    }

    function proveAll() external {
        uint256 n = game.currentEpoch();
        for (uint256 i = game.activeCursor(); i < game.activeEpochCount(); ++i) {
            uint256 e = game.activeEpochs(i);
            if (e >= n) break;
            uint64 r = game.roundForEpoch(e);
            if (beacon.randomness(r) == bytes32(0)) beacon.set(r, keccak256(abi.encode(r)));
        }
        game.settle(256, none);
    }

    function trade(uint256 who, uint256 amount, bool sell) external {
        address p = players[who % players.length];
        amount = bound(amount, 1e18, 200_000e18);
        MockERC20 tIn = sell ? MockERC20(address(gamma)) : imd;
        if (tIn.balanceOf(p) < amount) return;
        vm.startPrank(p);
        tIn.approve(address(router), type(uint256).max);
        bool zeroForOne = sell == gammaIs0;
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }
}

contract GammaInvariantTest is GammaFixture {
    GammaHandler handler;

    function setUp() public override {
        super.setUp();
        address[] memory ps = new address[](3);
        ps[0] = alice;
        ps[1] = bob;
        ps[2] = carol;
        handler = new GammaHandler(game, beacon, gamma, imd, swapRouter, key, ps);
        targetContract(address(handler));
        excludeSender(address(game));
    }

    /// @dev The game always holds at least what it still owes: the unreleased Reserve, every open pot and
    /// every harvested winning nobody has claimed.
    function invariant_solvent() public view {
        uint256 owed = game.RESERVE() - game.released(game.cursor()) + game.totalUnclaimed();
        uint256 lastDay = game.today() + 1;
        for (uint256 d; d <= lastDay; ++d) {
            GammaGame.Day memory day = game.getDay(d);
            if (!day.finalized) owed += day.pot + day.sharesPaid;
        }
        assertGe(gamma.balanceOf(address(game)), owed);
    }

    function invariant_supplyNeverGrows() public view {
        assertEq(gamma.totalSupply(), 1_000_000_000e18);
        assertGe(gamma.balanceOf(game.DEAD()), handler.energiesBought() * 1_000e18);
    }

    function invariant_cursorNeverAhead() public view {
        assertLe(game.cursor(), game.currentEpoch());
    }

    /// @dev The game's accounted GAMMA is exactly what it holds: every purchase, claim, hook fee, donation and
    /// conversion keeps the mirror in step with the balance, so a hook fee can never be credited unbacked.
    function invariant_gammaHeldMatchesBalance() public view {
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)));
    }
}
