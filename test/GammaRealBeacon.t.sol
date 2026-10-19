// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GammaFixture} from "./utils/GammaFixture.sol";
import {GammaGame} from "src/GammaGame.sol";
import {GammaToken} from "src/GammaToken.sol";
import {DrandBeacon} from "src/DrandBeacon.sol";
import {IGammaBeacon} from "src/interfaces/IGammaBeacon.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Factory-shaped, single-call deployment using the exact dependency addresses in the brief.
contract GammaDeploymentHarness {
    function deploy(address configurator) external returns (DrandBeacon beacon, GammaGame game) {
        beacon = new DrandBeacon();
        game = new GammaGame(
            IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951),
            ERC20(0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127),
            IGammaBeacon(address(beacon)),
            configurator
        );
    }
}

contract GammaFactoryDeploymentTest is Test {
    function test_factoryUsesExplicitConfiguratorAndEarlierBeacon() public {
        GammaDeploymentHarness factory = new GammaDeploymentHarness();
        // A test actor represents the caller-provided $owner; no production owner is invented here.
        address configurator = makeAddr("launch configurator");
        (DrandBeacon beacon, GammaGame game) = factory.deploy(configurator);
        assertEq(address(game.poolManager()), 0x8366a39CC670B4001A1121B8F6A443A643e40951);
        assertEq(address(game.imd()), 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
        assertEq(address(game.beacon()), address(beacon));
        assertEq(game.configurator(), configurator);
        assertTrue(game.configurator() != address(factory));
        assertTrue(game.configurator() != address(this));
        assertEq(game.genesis(), 0);
        assertEq(address(game.gamma()), address(0));
        assertEq(game.hook(), address(0));
        PoolKey memory empty;
        vm.prank(address(factory));
        vm.expectRevert(GammaGame.NotConfigurator.selector);
        game.initialize(empty);
        // The authorized actor gets as far as validating its pool, without needing external code.
        vm.prank(configurator);
        vm.expectRevert(GammaGame.BadPool.selector);
        game.initialize(empty);
    }
}

/// @notice Full offline integration: real BN254 verification, real v4 swaps, real game settlement.
/// The signature is the checked-in evmnet vector also used by DrandBeacon.t.sol.
contract GammaRealBeaconTest is GammaFixture {
    uint64 internal constant ROUND = 21_600_000;
    bytes internal constant SIGNATURE =
        hex"082d388f72a25dd3f8c84e81e52b0e08947a446276ce12fbcb7b0e9ec4ae16a80cf2e660d385c5b3f7c407fe69bb67c00c5333c6169a3c5b2863e29f6100b9c9";

    GammaGame internal realGame;
    DrandBeacon internal realBeacon;
    GammaToken internal realGamma;

    function setUp() public override {
        super.setUp();
        realBeacon = new DrandBeacon();
        // Align epoch 0's required round with the real signature vector, including the six-second delay.
        uint256 roundTime = uint256(realBeacon.GENESIS()) + (uint256(ROUND) - 1) * realBeacon.PERIOD();
        vm.warp(roundTime - 10 minutes - 6);
        realGame = new GammaGame(manager, imd, IGammaBeacon(address(realBeacon)), address(this));
        realGamma = new GammaToken(address(this));

        uint160 flags = uint160(address(hook)) & ((1 << 14) - 1);
        address realHook = address(uint160(0x8888 << 144) | flags);
        deployCodeTo("GammaHook.sol:GammaHook", abi.encode(address(manager), address(imd), address(realGame)), realHook);
        bool realGammaIs0 = address(realGamma) < address(imd);
        PoolKey memory realKey = PoolKey({
            currency0: Currency.wrap(realGammaIs0 ? address(realGamma) : address(imd)),
            currency1: Currency.wrap(realGammaIs0 ? address(imd) : address(realGamma)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(realHook)
        });
        manager.initialize(realKey, SQRT_PRICE_1_1);
        realGamma.transfer(address(realGame), realGame.RESERVE());
        realGamma.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            realKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 100_000_000e18,
                salt: 0
            }),
            ""
        );
        realGame.initialize(realKey);
        vm.prank(alice);
        imd.approve(address(realGame), type(uint256).max);
        vm.prank(alice);
        realGame.buyEnergies(3, 100, 200_000e18, noProofs);
        assertEq(realGame.roundForEpoch(0), ROUND);
    }

    function test_realProofUnblocksSettlementAndMaturedClaim() public {
        vm.warp(realGame.epochEnd(0) + 6);
        realGame.settle(256, noProofs);
        assertEq(realGame.cursor(), 0);
        assertEq(realGame.pendingRound(), ROUND);
        assertFalse(realGame.getBatch(0).drawn);

        GammaGame.BeaconProof[] memory proofs = new GammaGame.BeaconProof[](1);
        proofs[0] = GammaGame.BeaconProof(ROUND, SIGNATURE);
        vm.prank(bob); // Neither a configurator nor a backend signer is required.
        realGame.settle(256, proofs);
        assertEq(realBeacon.randomness(ROUND), sha256(SIGNATURE));
        assertEq(realGame.epochSeed(0), keccak256(abi.encode(sha256(SIGNATURE), uint256(0))));
        assertTrue(realGame.getBatch(0).drawn);
        assertEq(realGame.cursor(), 1);

        vm.warp(realGame.dayEnd(0) + 1 days);
        realGame.settle(256, noProofs);
        assertTrue(realGame.getDay(0).finalized);
        GammaGame.BatchView memory batch = realGame.userBatches(alice, 0, 1)[0];
        assertGt(batch.winnings, 0);
        vm.prank(alice);
        uint256 paid = realGame.claimMatured(ids1(0));
        assertEq(paid, batch.winnings - batch.winnings / 10);
        assertEq(realGamma.balanceOf(alice), paid);
        assertEq(realGame.totalUnclaimed(), 0);
        assertEq(realGame.gammaHeld(), realGamma.balanceOf(address(realGame)));
    }

    function test_invalidRealProofIsIgnoredWithoutDrawingBatch() public {
        vm.warp(realGame.epochEnd(0) + 6);
        GammaGame.BeaconProof[] memory proofs = new GammaGame.BeaconProof[](1);
        proofs[0] = GammaGame.BeaconProof(ROUND, hex"1234");
        realGame.settle(256, proofs);
        assertFalse(realGame.getBatch(0).drawn);
        assertEq(realBeacon.randomness(ROUND), bytes32(0));
        assertEq(realGame.cursor(), 0);
        assertEq(realGame.totalUnclaimed(), 0);
        assertEq(realGame.gammaHeld(), realGame.RESERVE());
        proofs[0].signature = SIGNATURE;
        realGame.settle(256, proofs);
        assertTrue(realGame.getBatch(0).drawn);
    }
}
