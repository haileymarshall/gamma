// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GammaFixture} from "./utils/GammaFixture.sol";
import {GammaHook} from "src/GammaHook.sol";
import {IGammaGame} from "src/interfaces/IGammaGame.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract GammaHookBoundariesTest is GammaFixture {
    function freshHook() internal returns (GammaHook fresh) {
        address at = address(uint160(0x6666 << 144) | (uint160(address(hook)) & Hooks.ALL_HOOK_MASK));
        deployCodeTo("GammaHook.sol:GammaHook", abi.encode(manager, address(imd), game), at);
        fresh = GammaHook(at);
    }

    function expectHookError(GammaHook target, bytes4 callback, bytes4 reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(target),
                callback,
                abi.encodeWithSelector(reason),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_specifiedConstructorAddressesArePreserved() public {
        // Offline constructor check only: no assertion about code deployed on the live chain.
        address poolManager = address(bytes20(hex"8366a39cc670b4001a1121b8f6a443a643e40951"));
        address pair = address(bytes20(hex"5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127"));
        address recipient = address(bytes20(hex"b333a22c2c3dd0fe29fd1bf184c5ff2282148535"));
        address at = address(uint160(0x7777 << 144) | (uint160(address(hook)) & Hooks.ALL_HOOK_MASK));
        deployCodeTo("GammaHook.sol:GammaHook", abi.encode(IPoolManager(poolManager), pair, IGammaGame(recipient)), at);
        GammaHook configured = GammaHook(at);
        assertEq(address(configured.poolManager()), poolManager);
        assertEq(configured.imd(), pair);
        assertEq(address(configured.game()), recipient);
        // Being the deployer or recipient does not confer callback authority.
        vm.expectRevert(GammaHook.NotPoolManager.selector);
        configured.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.prank(recipient);
        vm.expectRevert(GammaHook.NotPoolManager.selector);
        configured.unlockCallback("");
    }

    function test_nonImdPairFailsWithoutConsumingInitialization() public {
        GammaHook fresh = freshHook();
        MockERC20 other = new MockERC20("Other", "OTHER", 18);
        PoolKey memory bad = key;
        (address a, address b) =
            address(gamma) < address(other) ? (address(gamma), address(other)) : (address(other), address(gamma));
        bad.currency0 = Currency.wrap(a);
        bad.currency1 = Currency.wrap(b);
        bad.hooks = fresh;
        expectHookError(fresh, IHooks.beforeInitialize.selector, GammaHook.NotImdPair.selector);
        manager.initialize(bad, SQRT_PRICE_1_1);
        assertEq(fresh.launchedAt(), 0);
        assertEq(fresh.poolId(), bytes32(0));
        assertEq(Currency.unwrap(fresh.gamma()), address(0));

        PoolKey memory good = key;
        good.hooks = fresh;
        manager.initialize(good, SQRT_PRICE_1_1);
        assertEq(fresh.poolId(), keccak256(abi.encode(good)));
        assertEq(Currency.unwrap(fresh.gamma()), address(gamma));
        assertEq(fresh.launchedAt(), vm.getBlockTimestamp());
    }

    function test_sameTokensAtDifferentFeeCannotRebindHook() public {
        PoolKey memory second = key;
        second.fee = 3_000;
        bytes32 id = hook.poolId();
        uint256 launched = hook.launchedAt();
        expectHookError(hook, IHooks.beforeInitialize.selector, GammaHook.PoolAlreadySet.selector);
        manager.initialize(second, SQRT_PRICE_1_1);
        assertEq(hook.poolId(), id);
        assertEq(hook.launchedAt(), launched);
        assertEq(Currency.unwrap(hook.gamma()), address(gamma));
    }

    function test_poolCreatedAfterGenesisStartsItsOwnDecayClock() public {
        // Isolate the hook's clock branch using a game whose genesis is already in the past.
        // This second pool is not wired into the game and is never used for fee callbacks.
        GammaHook fresh = freshHook();
        assertGt(game.genesis(), 0);
        assertEq(fresh.feeBps(), 9_900, "uninitialized hook decayed");
        vm.warp(uint256(game.genesis()) + 10 days);
        PoolKey memory later = key;
        later.hooks = fresh;
        manager.initialize(later, SQRT_PRICE_1_1);
        uint256 start = fresh.launchedAt();
        assertEq(fresh.feeBps(), 9_900);
        vm.warp(start + 59);
        assertEq(fresh.feeBps(), 9_900);
        vm.warp(start + 60);
        assertEq(fresh.feeBps(), 9_800);
        vm.warp(start + 95 minutes + 59);
        assertEq(fresh.feeBps(), 400);
        vm.warp(start + 96 minutes);
        assertEq(fresh.feeBps(), 300);
    }

    function test_everyMinuteBoundaryAndPermanentFloor() public {
        uint256 start = hook.launchedAt();
        uint256 expected = 9_900;
        for (uint256 minute; minute < 96; ++minute) {
            vm.warp(start + minute * 60);
            assertEq(hook.feeBps(), expected);
            vm.warp(start + minute * 60 + 59);
            assertEq(hook.feeBps(), expected, "decay occurred inside a minute");
            expected -= 100;
        }
        vm.warp(start + 96 minutes);
        assertEq(hook.feeBps(), 300);
        vm.warp(type(uint64).max);
        assertEq(hook.feeBps(), 300);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeNeverRisesAndStaysAtFloor(uint64 firstSeed, uint64 secondSeed) public {
        uint256 first = bound(firstSeed, 0, 200 minutes);
        uint256 second = bound(secondSeed, first, type(uint64).max - uint256(hook.launchedAt()));
        vm.warp(uint256(hook.launchedAt()) + first);
        uint256 before = hook.feeBps();
        vm.warp(uint256(hook.launchedAt()) + second);
        uint256 after_ = hook.feeBps();
        assertLe(after_, before);
        assertGe(after_, 300);
        assertLe(before, 9_900);
        if (second >= 96 minutes) assertEq(after_, 300);
    }

    /// @dev Compare against an otherwise identical pool with no hook. This independently measures
    /// realised output, including v4's rounding, price limits and the launch's 1.25% LP fee.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_partialBuyTaxesOnlyRealisedGamma(uint96 inputSeed, uint8 minuteSeed) public {
        PoolKey memory control = key;
        control.hooks = IHooks(address(0));
        manager.initialize(control, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity(
            control,
            ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 100_000_000e18, 0
            ),
            ""
        );
        uint256 input = bound(inputSeed, 1_000_000e18, 10_000_000e18);
        uint256 minute = bound(minuteSeed, 0, 120);
        vm.warp(uint256(hook.launchedAt()) + minute * 60);
        bool zeroForOne = !gammaIs0;
        uint160 limit = zeroForOne ? SQRT_PRICE_1_1 - SQRT_PRICE_1_1 / 10_000 : SQRT_PRICE_1_1 + SQRT_PRICE_1_1 / 10_000;
        SwapParams memory params = SwapParams(zeroForOne, -int256(input), limit);
        uint256 beforeGame = gamma.balanceOf(address(game));
        uint256 beforePot = game.getDay(game.today()).pot;
        vm.startPrank(bob);
        imd.approve(address(swapRouter), type(uint256).max);
        BalanceDelta untaxed = swapRouter.swap(control, params, PoolSwapTest.TestSettings(false, false), "");
        BalanceDelta taxed = swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        int128 plainImd = gammaIs0 ? untaxed.amount1() : untaxed.amount0();
        int128 taxedImd = gammaIs0 ? taxed.amount1() : taxed.amount0();
        uint256 gross = uint256(int256(gammaIs0 ? untaxed.amount0() : untaxed.amount1()));
        uint256 net = uint256(int256(gammaIs0 ? taxed.amount0() : taxed.amount1()));
        uint256 fee = gamma.balanceOf(address(game)) - beforeGame;
        assertGt(gross, 0);
        assertGt(-int256(plainImd), 0);
        assertLt(uint256(-int256(plainImd)), input, "must exercise a partial fill");
        assertEq(plainImd, taxedImd, "buy fee touched IMD input");
        assertEq(net + fee, gross, "fee exceeded realised output");
        assertEq(fee, gross * hook.feeBps() / 10_000);
        assertEq(game.getDay(game.today()).pot, beforePot + fee);
        assertEq(hook.pendingFees(), 0);
        assertEq(imd.balanceOf(address(game)), 0);
    }
}
