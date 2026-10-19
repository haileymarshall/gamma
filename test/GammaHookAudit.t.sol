// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GammaFixture} from "./utils/GammaFixture.sol";
import {GammaGame} from "src/GammaGame.sol";
import {GammaHook} from "src/GammaHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

abstract contract GammaHookAuditFixture is GammaFixture {
    using TransientStateLibrary for IPoolManager;

    function _swap(address who, bool sell, int256 specified, uint160 limit) internal returns (BalanceDelta result) {
        vm.startPrank(who);
        (sell ? ERC20(address(gamma)) : ERC20(address(imd))).approve(address(swapRouter), type(uint256).max);
        result = swapRouter.swap(
            key, SwapParams(sell == gammaIs0, specified, limit), PoolSwapTest.TestSettings(false, false), ""
        );
        vm.stopPrank();
        _assertSettled();
    }

    function _limit(bool sell) internal view returns (uint160) {
        return sell == gammaIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _expectHookError(bytes4 errorSelector, bytes4 callback) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                callback,
                abi.encodeWithSelector(errorSelector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _assertSettled() internal view {
        IPoolManager pm = IPoolManager(address(manager));
        assertEq(pm.currencyDelta(address(hook), key.currency0), 0);
        assertEq(pm.currencyDelta(address(hook), key.currency1), 0);
        assertEq(pm.currencyDelta(address(swapRouter), key.currency0), 0);
        assertEq(pm.currencyDelta(address(swapRouter), key.currency1), 0);
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertFalse(pm.isUnlocked());
        assertEq(manager.balanceOf(address(hook), uint160(address(gamma))), hook.pendingFees());
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(gamma.balanceOf(address(hook)), 0);
    }
}

abstract contract GammaHookAuditTest is GammaHookAuditFixture {
    function setUp() public override {
        super.setUp();
        gamma.transfer(alice, 50_000_000e18);
    }

    // d8ec1fd7: compare both sell shapes from precisely the same pool state.
    function test_exactOutputSellPaysSameLaunchFeeAsExactInput() public {
        vm.warp(hook.launchedAt());
        uint256 snapshot = vm.snapshotState();
        uint256 imdBefore = imd.balanceOf(alice);
        _swap(alice, true, -int256(1_000_000e18), _limit(true));
        uint256 imdOut = imd.balanceOf(alice) - imdBefore;
        assertEq(game.getDay(0).pot, 990_000e18);
        assertTrue(vm.revertToState(snapshot));

        uint256 beforeGamma = gamma.balanceOf(alice);
        _swap(alice, true, int256(imdOut), _limit(true));
        uint256 paid = beforeGamma - gamma.balanceOf(alice);
        uint256 fee = game.getDay(0).pot;
        assertApproxEqAbs(fee * 10_000 / paid, 9_900, 1);
        assertApproxEqAbs(paid, 1_000_000e18, 200);
        assertEq(gamma.balanceOf(address(game)) - game.RESERVE(), fee);
    }

    function testFuzz_exactOutputSellPaysScheduledFraction(uint96 outputSeed, uint16 minutesSeed) public {
        uint256 output = bound(outputSeed, 1e6, 1_000e18);
        vm.warp(hook.launchedAt() + bound(minutesSeed, 0, 200) * 60);
        uint256 rate = hook.feeBps();
        uint256 pot = game.getDay(game.today()).pot;
        uint256 beforeGamma = gamma.balanceOf(alice);
        uint256 beforeImd = imd.balanceOf(alice);
        _swap(alice, true, int256(output), _limit(true));
        uint256 paid = beforeGamma - gamma.balanceOf(alice);
        uint256 fee = game.getDay(game.today()).pot - pot;
        assertEq(imd.balanceOf(alice) - beforeImd, output);
        assertApproxEqAbs(fee, paid * rate / 10_000, 1);
        assertEq(fee, (paid - fee) * rate / (10_000 - rate));
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)));
    }

    // 7d917333: an unfilled exact-input sell must not transfer the fee on the unspent offer.
    function test_partialFillSellRevertsAtomically() public {
        uint256 beforeGamma = gamma.balanceOf(alice);
        uint256 beforeGame = gamma.balanceOf(address(game));
        uint256 beforeManager = gamma.balanceOf(address(manager));
        uint256 beforePot = game.getDay(game.today()).pot;
        uint160 limit = gammaIs0 ? SQRT_PRICE_1_1 - SQRT_PRICE_1_1 / 10_000 : SQRT_PRICE_1_1 + SQRT_PRICE_1_1 / 10_000;
        vm.startPrank(alice);
        gamma.approve(address(swapRouter), type(uint256).max);
        _expectHookError(GammaHook.PartialFillSellNotSupported.selector, IHooks.afterSwap.selector);
        swapRouter.swap(
            key, SwapParams(gammaIs0, -int256(10_000_000e18), limit), PoolSwapTest.TestSettings(false, false), ""
        );
        vm.stopPrank();
        assertEq(gamma.balanceOf(alice), beforeGamma);
        assertEq(gamma.balanceOf(address(game)), beforeGame);
        assertEq(gamma.balanceOf(address(manager)), beforeManager);
        assertEq(game.getDay(game.today()).pot, beforePot);
        (uint160 price,,,) = StateLibrary.getSlot0(manager, key.toId());
        assertEq(price, SQRT_PRICE_1_1);
        _assertSettled();
    }

    function test_exactInputSellWithReachableLimitStillWorks() public {
        uint160 limit = gammaIs0 ? SQRT_PRICE_1_1 - SQRT_PRICE_1_1 / 100 : SQRT_PRICE_1_1 + SQRT_PRICE_1_1 / 100;
        uint256 pot = game.getDay(game.today()).pot;
        _swap(alice, true, -int256(1_000e18), limit);
        assertEq(game.getDay(game.today()).pot - pot, 30e18);
    }

    function test_exactOutputPartialSellChargesOnlyRealisedInput() public {
        uint160 limit = gammaIs0 ? SQRT_PRICE_1_1 - SQRT_PRICE_1_1 / 10_000 : SQRT_PRICE_1_1 + SQRT_PRICE_1_1 / 10_000;
        uint256 pot = game.getDay(game.today()).pot;
        uint256 beforeGamma = gamma.balanceOf(alice);
        uint256 beforeImd = imd.balanceOf(alice);
        _swap(alice, true, int256(10_000_000e18), limit);
        uint256 output = imd.balanceOf(alice) - beforeImd;
        uint256 paid = beforeGamma - gamma.balanceOf(alice);
        assertGt(output, 0);
        assertLt(output, 10_000_000e18);
        assertApproxEqAbs(game.getDay(game.today()).pot - pot, paid * 300 / 10_000, 1);
    }

    // 086a052e: the fee exceeds the manager's GAMMA before settlement, but the sell itself is solvent.
    function test_largeSellDefersThenRedeemsEntireFee() public {
        _drainGammaByBuying();
        uint256 beforeGame = gamma.balanceOf(address(game));
        uint256 pot = game.getDay(game.today()).pot;
        _swap(alice, true, -int256(40_000_000e18), _limit(true));
        uint256 fee = 1_200_000e18;
        assertEq(hook.pendingFees(), fee);
        assertEq(gamma.balanceOf(address(game)), beforeGame);
        assertEq(game.getDay(game.today()).pot, pot, "unreceived claims cannot spend the Reserve");

        vm.prank(carol);
        assertEq(hook.redeemFees(), fee);
        assertEq(hook.pendingFees(), 0);
        assertEq(gamma.balanceOf(address(game)), beforeGame + fee);
        assertEq(game.getDay(game.today()).pot, pot + fee);
        assertEq(gamma.balanceOf(carol), 0, "redeemer cannot redirect the fee");
        assertEq(hook.redeemFees(), 0, "no double redemption");
        _assertSettled();
    }

    function test_largeExactOutputSellAlsoDefersFee() public {
        _drainGammaByBuying();
        vm.warp(hook.launchedAt());
        uint256 before = gamma.balanceOf(alice);
        _swap(alice, true, int256(5_000_000_000e18), _limit(true));
        uint256 fee = hook.pendingFees();
        assertGt(fee, 0);
        assertApproxEqAbs(fee, (before - gamma.balanceOf(alice)) * 9_900 / 10_000, 1);
        assertEq(hook.redeemFees(), fee);
        _assertSettled();
    }

    function test_redemptionCanPayPartThenFinish() public {
        _drainGammaByBuying();
        _swap(alice, true, -int256(40_000_000e18), _limit(true));
        uint256 fee = hook.pendingFees();
        // Model another unsettled manager operation leaving only part of the fee liquid.
        // Balances are restored before checking the next redemption; no supply is minted.
        uint256 balance = gamma.balanceOf(address(manager));
        vm.prank(address(manager));
        gamma.transfer(address(this), balance - fee / 2);
        assertEq(hook.redeemFees(), fee / 2);
        assertEq(hook.pendingFees(), fee - fee / 2);
        assertEq(hook.redeemFees(), 0);
        gamma.transfer(address(manager), balance - fee / 2);
        assertEq(hook.redeemFees(), fee - fee / 2);
        _assertSettled();
    }

    function test_deferredFeeCreditsHarvestWhenDelivered() public {
        _drainGammaByBuying();
        _swap(alice, true, -int256(40_000_000e18), _limit(true));
        uint256 fee = hook.pendingFees();
        toNextDay();
        uint256 pot = game.getDay(game.today()).pot;
        hook.redeemFees();
        assertEq(game.getDay(game.today()).pot, pot + fee);
    }

    function testFuzz_multipleFeesRemainFullyBacked(uint96 amountSeed, uint8 minutesSeed, bool redeemBetween) public {
        _drainGammaByBuying();
        vm.warp(hook.launchedAt() + bound(minutesSeed, 0, 96) * 60);
        uint256 amount = bound(amountSeed, 1_000_000e18, 15_000_000e18);
        uint256 rate = hook.feeBps();
        uint256 beforeGame = gamma.balanceOf(address(game));
        uint256 beforePot = game.getDay(game.today()).pot;
        uint256 totalFees;
        for (uint256 i; i < 3; ++i) {
            _swap(alice, true, -int256(amount), _limit(true));
            totalFees += amount * rate / 10_000;
            if (redeemBetween) hook.redeemFees();
            assertEq(gamma.balanceOf(address(game)) - beforeGame + hook.pendingFees(), totalFees);
            assertGe(gamma.balanceOf(address(manager)), hook.pendingFees());
            _assertSettled();
        }
        hook.redeemFees();
        assertEq(hook.pendingFees(), 0);
        assertEq(gamma.balanceOf(address(game)) - beforeGame, totalFees);
        assertEq(game.getDay(game.today()).pot - beforePot, totalFees);
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)));
        _assertSettled();
    }

    function test_allEnabledCallbacksAndRedemptionRefuseForgedCallers() public {
        SwapParams memory params = SwapParams(gammaIs0, -int256(1e18), _limit(true));
        vm.expectRevert(GammaHook.NotPoolManager.selector);
        hook.beforeInitialize(alice, key, SQRT_PRICE_1_1);
        vm.expectRevert(GammaHook.NotPoolManager.selector);
        hook.afterInitialize(alice, key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(GammaHook.NotPoolManager.selector);
        hook.beforeSwap(alice, key, params, "");
        vm.expectRevert(GammaHook.NotPoolManager.selector);
        hook.afterSwap(alice, key, params, BalanceDeltaLibrary.ZERO_DELTA, "");
        vm.expectRevert(GammaHook.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_hookDataCannotSpoofGameExemption() public {
        vm.startPrank(alice);
        imd.approve(address(swapRouter), type(uint256).max);
        _expectHookError(GammaHook.ExactOutputBuyNotSupported.selector, IHooks.beforeSwap.selector);
        swapRouter.swap(
            key,
            SwapParams(!gammaIs0, int256(100e18), _limit(false)),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(game))
        );
        vm.stopPrank();
    }

    function test_feeDeltasRejectOverflowInsteadOfWrapping() public {
        vm.warp(hook.launchedAt());
        SwapParams memory params = SwapParams(gammaIs0, -(int256(1) << 128), _limit(true));
        vm.prank(address(manager));
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        hook.beforeSwap(alice, key, params, "");

        params.amountSpecified = 1;
        BalanceDelta delta = gammaIs0 ? toBalanceDelta(-type(int128).max, 1) : toBalanceDelta(1, -type(int128).max);
        vm.prank(address(manager));
        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        hook.afterSwap(alice, key, params, delta, "");
    }

    function test_gameIsExemptForAllFourSwapShapes() public {
        for (uint256 i; i < 4; ++i) {
            SwapParams memory params = SwapParams(i % 2 == 0, i < 2 ? -int256(1e18) : int256(1e18), _limit(true));
            vm.prank(address(manager));
            (bytes4 beforeSelector, BeforeSwapDelta beforeDelta, uint24 lpFee) =
                hook.beforeSwap(address(game), key, params, "");
            assertEq(beforeSelector, IHooks.beforeSwap.selector);
            assertEq(BeforeSwapDelta.unwrap(beforeDelta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
            assertEq(lpFee, 0);
            vm.prank(address(manager));
            (bytes4 afterSelector, int128 fee) =
                hook.afterSwap(address(game), key, params, toBalanceDelta(-1e18, 1e18), "");
            assertEq(afterSelector, IHooks.afterSwap.selector);
            assertEq(fee, 0);
        }
    }

    function test_smallestSellRoundsFeeDownWithoutReportingIt() public {
        uint256 pot = game.getDay(game.today()).pot;
        uint256 beforeGamma = gamma.balanceOf(alice);
        _swap(alice, true, -int256(1), _limit(true));
        assertEq(beforeGamma - gamma.balanceOf(alice), 1);
        assertEq(game.getDay(game.today()).pot, pot);
        assertEq(hook.pendingFees(), 0);
    }

    function _drainGammaByBuying() internal {
        imd.mint(bob, 1e29);
        _swap(bob, false, -int256(1e29), _limit(false));
        assertLt(gamma.balanceOf(address(manager)), 1_200_000e18);
    }
}

contract GammaHookGamma0AuditTest is GammaHookAuditTest {
    function deployImd() internal override returns (MockERC20) {
        address at = address(type(uint160).max);
        deployCodeTo(
            "lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20",
            abi.encode("IMD", "IMD", uint8(18)),
            at
        );
        return MockERC20(at);
    }
}

contract GammaHookGamma1AuditTest is GammaHookAuditTest {
    function deployImd() internal override returns (MockERC20) {
        address at = address(0x1000);
        deployCodeTo(
            "lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20",
            abi.encode("IMD", "IMD", uint8(18)),
            at
        );
        return MockERC20(at);
    }
}

contract GammaHookBeforeGenesisTest is GammaHookAuditFixture {
    function initializeGame() internal override {}

    // 9f20a96d: both buys and sells trade before initialize, at 99%, without weakening game accounting.
    function test_preGenesisFeesAreFirstHarvestSurplus() public {
        gamma.transfer(alice, 1_000e18);
        vm.warp(block.timestamp + 3 days);
        assertEq(game.genesis(), 0);
        assertEq(hook.feeBps(), 9_900);
        _swap(bob, false, -int256(1_000e18), _limit(false));
        uint256 buyFee = gamma.balanceOf(address(game)) - game.RESERVE();
        uint256 bought = gamma.balanceOf(bob);
        assertEq(buyFee, (buyFee + bought) * 9_900 / 10_000);
        _swap(alice, true, -int256(1_000e18), _limit(true));
        uint256 fees = gamma.balanceOf(address(game)) - game.RESERVE();
        assertEq(fees - buyFee, 990e18);
        assertEq(game.gammaHeld(), 0);
        assertEq(game.getDay(0).pot, 0);
        game.initialize(key);
        assertEq(game.getDay(0).pot, fees);
        assertEq(game.gammaHeld(), game.RESERVE() + fees);
        assertEq(hook.feeBps(), 9_900);
        vm.warp(game.genesis() + 60);
        assertEq(hook.feeBps(), 9_800);
        assertEq(game.sweep(), 0, "pre-genesis fees cannot be credited twice");
    }

    function test_preGenesisDeferredFeesCanBeRedeemedBeforeInitialize() public {
        _deferBeforeGenesis();
        uint256 pending = hook.pendingFees();
        uint256 before = gamma.balanceOf(address(game));
        assertEq(hook.redeemFees(), pending);
        assertEq(gamma.balanceOf(address(game)), before + pending);
        game.initialize(key);
        assertEq(game.getDay(0).pot, before + pending - game.RESERVE());
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)));
        _assertSettled();
    }

    function test_preGenesisDeferredFeesCanBeRedeemedAfterInitialize() public {
        _deferBeforeGenesis();
        uint256 pending = hook.pendingFees();
        game.initialize(key);
        uint256 pot = game.getDay(0).pot;
        assertEq(hook.redeemFees(), pending);
        assertEq(game.getDay(0).pot, pot + pending);
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)));
        _assertSettled();
    }

    function _deferBeforeGenesis() internal {
        gamma.transfer(alice, 40_000_000e18);
        imd.mint(bob, 1e29);
        _swap(bob, false, -int256(1e29), _limit(false));
        _swap(alice, true, -int256(40_000_000e18), _limit(true));
        assertEq(hook.pendingFees(), 39_600_000e18);
    }
}
