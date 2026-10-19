// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GammaFixture} from "./utils/GammaFixture.sol";
import {GammaGame} from "src/GammaGame.sol";
import {GammaHook} from "src/GammaHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract GammaHookTest is GammaFixture {
    function setUp() public override {
        super.setUp();
        gamma.transfer(alice, 10_000_000e18);
    }

    function test_feeSchedule() public {
        uint256 launched = hook.launchedAt();
        vm.warp(launched);
        assertEq(hook.feeBps(), 9_900);
        vm.warp(launched + 59);
        assertEq(hook.feeBps(), 9_900);
        vm.warp(launched + 60);
        assertEq(hook.feeBps(), 9_800);
        vm.warp(launched + 30 minutes);
        assertEq(hook.feeBps(), 6_900);
        vm.warp(launched + 95 minutes);
        assertEq(hook.feeBps(), 400);
        vm.warp(launched + 96 minutes);
        assertEq(hook.feeBps(), 300);
        vm.warp(launched + 1000 days);
        assertEq(hook.feeBps(), 300);
    }

    function test_sniperFeeFundsFirstHarvest() public {
        vm.warp(hook.launchedAt()); // first minute
        uint256 d = game.today();
        uint256 potBefore = game.getDay(d).pot;
        uint256 gammaBefore = gamma.balanceOf(bob);

        swapExactIn(bob, false, 10_000e18); // buy with 10k IMD

        uint256 received = gamma.balanceOf(bob) - gammaBefore;
        uint256 fee = game.getDay(d).pot - potBefore;
        assertApproxEqRel(fee * 10_000 / (fee + received), 9_900, 0.001e18, "99% of the output went to the Harvest");
    }

    function test_buyExactInFeeInGamma() public {
        uint256 d = game.today();
        uint256 potBefore = game.getDay(d).pot;
        uint256 gameBal = gamma.balanceOf(address(game));
        swapExactIn(bob, false, 100_000e18);
        uint256 fee = game.getDay(d).pot - potBefore;
        assertGt(fee, 0);
        assertEq(gamma.balanceOf(address(game)) - gameBal, fee, "fee tokens arrived with the accounting");
        uint256 received = gamma.balanceOf(bob);
        assertApproxEqAbs(fee * 10_000 / (fee + received), 300, 1);
    }

    function test_sellExactInFeeInGamma() public {
        uint256 d = game.today();
        uint256 potBefore = game.getDay(d).pot;
        swapExactIn(alice, true, 100_000e18);
        uint256 fee = game.getDay(d).pot - potBefore;
        assertEq(fee, 100_000e18 * 300 / 10_000, "3% of the GAMMA sent");
    }

    function test_exactOutBuyIsRejected() public {
        uint256 bobGamma = gamma.balanceOf(bob);
        vm.startPrank(bob);
        imd.approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = !gammaIs0;
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(50_000e18),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertEq(gamma.balanceOf(bob), bobGamma);
        assertEq(imd.balanceOf(address(game)), 0, "no IMD fee can reach the game");
    }

    function test_gamePurchasesAreExempt() public {
        settleAll(); // so the purchase has no settlement work moving emission into the pot
        uint256 d = game.today();
        uint256 potBefore = game.getDay(d).pot;
        buy(bob, 0, 50);
        assertEq(game.getDay(d).pot, potBefore, "no hook fee on energy purchases");
        assertEq(imd.balanceOf(address(game)), 0);
    }

    function test_tradingFeesReachMiners() public {
        uint256 id = buy(bob, 3, 100);
        swapExactIn(alice, true, 1_000_000e18);
        toNextDay();
        settleAll();
        warpDays(1);
        uint256 w = game.userBatches(bob, 0, 1)[0].winnings;
        vm.prank(bob);
        game.claim(ids1(id));

        GammaGame.Day memory day = game.getDay(game.getBatch(id).epoch / 144);
        assertGt(w, 0);
        // The 3% fee on the 1M GAMMA sell is in tonight's pot, on top of the emission.
        assertGe(day.pot, 30_000e18);
    }

    function test_onlyPoolManager() public {
        PoolKey memory k = key;
        vm.expectRevert(GammaHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), k, 0, 0);
    }

    function test_onlyHookCanReportFees() public {
        vm.expectRevert(GammaGame.NotHook.selector);
        game.onHookFee(Currency.wrap(address(gamma)), 1e18);
    }

    function test_secondPoolRejected() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        PoolKey memory k = key;
        (address a, address b) =
            address(other) < address(imd) ? (address(other), address(imd)) : (address(imd), address(other));
        k.currency0 = Currency.wrap(a);
        k.currency1 = Currency.wrap(b);
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
    }
}
