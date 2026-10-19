// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GammaFixture} from "./utils/GammaFixture.sol";
import {GammaGame} from "src/GammaGame.sol";
import {GammaHook} from "src/GammaHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Tests for the fixes made in the revision round (see ADAPTATION.md, changes 4-7).
contract GammaRevisionTest is GammaFixture {
    // ---- 59bd4b18: no purchase into an epoch whose seed is already on-chain
    function test_buyIntoProvenEpochReverts() public {
        uint256 e = game.currentEpoch();
        beacon.set(game.roundForEpoch(e), keccak256("early"));
        vm.prank(alice);
        vm.expectRevert(GammaGame.EpochSeedKnown.selector);
        game.buyEnergies(3, 100, 200_000e18, noProofs);
    }

    // ---- 250bf221: conversion only near a price fixed in an earlier block
    function _pending() internal {
        for (uint256 i; i < 5; ++i) {
            swapExactOutBuy(bob, 2_000_000e18);
            swapExactIn(bob, true, gamma.balanceOf(bob));
        }
        assertGt(game.pendingImd(), 0);
    }

    function test_convertWaitsForEarlierBlockPrice() public {
        _pending();
        uint256 p = game.pendingImd();
        game.convertPendingImd(0); // all observations are from this block
        assertEq(game.pendingImd(), p);
        vm.roll(block.number + 1);
        game.convertPendingImd(0);
        assertEq(game.pendingImd(), 0);
        assertEq(imd.balanceOf(address(game)), 0);
    }

    function test_convertAfterPumpDoesNotSwapAtPumpedPrice() public {
        _pending();
        vm.roll(block.number + 1);
        uint256 p = game.pendingImd();
        imd.mint(carol, 60_000_000e18);
        swapExactIn(carol, false, 60_000_000e18); // pump GAMMA in the same block
        uint256 held = game.gammaHeld();
        game.convertPendingImd(0);
        assertEq(game.pendingImd(), p, "nothing converted at the pumped price");
        assertEq(game.gammaHeld(), held);
    }

    // ---- deb689d5: unconsumed IMD stays pending
    function test_convertWithNoLiquidityKeepsImdPending() public {
        swapExactOutBuy(bob, 50_000e18);
        uint256 p = game.pendingImd();
        vm.roll(block.number + 1);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: -100_000_000e18,
                salt: 0
            }),
            ""
        );
        game.convertPendingImd(0);
        assertEq(game.pendingImd(), p);
        assertEq(imd.balanceOf(address(game)), p);
    }
}

/// @notice 7751928: the hook's anti-snipe fee decay starts at the game's genesis, not at pool creation.
contract GammaRevisionFeeClockTest is GammaFixture {
    function test_feeHeldAtStartUntilGameGenesis() public {
        GammaGame game2 = new GammaGame(IPoolManager(address(manager)), ERC20(address(imd)), beacon, address(this));
        address hookAddr = address(uint160(0x5555 << 144) | uint160(address(hook)) & 0x3fff);
        deployCodeTo("GammaHook.sol:GammaHook", abi.encode(address(manager), address(imd), address(game2)), hookAddr);
        key.hooks = GammaHook(hookAddr);
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.warp(block.timestamp + 3 hours);
        assertEq(GammaHook(hookAddr).feeBps(), GammaHook(hookAddr).START_FEE_BPS(), "no decay before genesis");
        assertEq(hook.feeBps(), hook.FLOOR_FEE_BPS(), "initialized game: decayed");
    }
}
