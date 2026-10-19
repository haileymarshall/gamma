// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {GammaHook} from "src/GammaHook.sol";
import {GammaGame} from "src/GammaGame.sol";
import {GammaToken} from "src/GammaToken.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @dev No balance edits, minting, storage edits, or swallowed reverts during the campaign.
/// The manager's Swap event is the independent observation of the AMM leg before hook fees.
contract GammaHookLedger is Test {
    using TransientStateLibrary for IPoolManager;

    bytes32 internal constant SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    GammaHook public immutable hook;
    GammaGame public immutable game;
    GammaToken public immutable gamma;
    ERC20 public immutable imd;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable router;
    bool public immutable gammaIs0;
    uint256 public immutable initialGameBalance;
    PoolKey internal key;
    address[3] public actors;

    uint256 public expectedFees;
    uint256[8] public expectedPots;
    uint256 public successfulTrades;
    uint256 public rejectedTrades;
    uint256 public redemptions;

    constructor(
        GammaHook hook_,
        GammaGame game_,
        GammaToken gamma_,
        ERC20 imd_,
        PoolSwapTest router_,
        PoolKey memory key_,
        address[3] memory actors_
    ) {
        hook = hook_;
        game = game_;
        gamma = gamma_;
        imd = imd_;
        manager = hook_.poolManager();
        router = router_;
        key = key_;
        actors = actors_;
        gammaIs0 = Currency.unwrap(key_.currency0) == address(gamma_);
        initialGameBalance = gamma_.balanceOf(address(game_));
        expectedFees = hook_.pendingFees();
        for (uint256 d; d < 8; ++d) {
            expectedPots[d] = game_.getDay(d).pot;
        }
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(actors_[i]);
            gamma_.approve(address(router_), type(uint256).max);
            imd_.approve(address(router_), type(uint256).max);
            vm.stopPrank();
        }
    }

    function tradeExactInput(uint256 who, uint256 seed, bool sell, bool dust) external {
        address actor = actors[who % 3];
        uint256 available = (sell ? ERC20(address(gamma)) : imd).balanceOf(actor);
        uint256 cap = dust ? 100 : (sell ? 5_000_000e18 : 1e29);
        if (available > cap) available = cap;
        if (available == 0) return;
        _trade(actor, sell, -int256(bound(seed, 1, available)));
    }

    function sellExactOutput(uint256 who, uint256 seed) external {
        address actor = actors[who % 3];
        // The campaign begins with abundant IMD liquidity; this small output is affordable even at 99%.
        if (gamma.balanceOf(actor) < 1e18) return;
        _trade(actor, true, int256(bound(seed, 1, 1e15)));
    }

    function advance(uint256 seed, bool longJump) external {
        uint256 oldRate = hook.feeBps();
        uint256 now_ = vm.getBlockTimestamp();
        uint256 end = uint256(game.genesis()) + 7 days;
        uint256 step = bound(seed, 0, longJump ? 1 days : 180);
        vm.warp(step > end - now_ ? end : now_ + step);
        assertLe(hook.feeBps(), oldRate, "fee increased as time advanced");
        assertGe(hook.feeBps(), 300);
        if (vm.getBlockTimestamp() >= uint256(game.genesis()) + 96 minutes) assertEq(hook.feeBps(), 300);
    }

    function redeem(uint256 who) public {
        address caller = actors[who % 3];
        uint256 due = hook.pendingFees();
        uint256 beforeGame = gamma.balanceOf(address(game));
        uint256 beforeCaller = gamma.balanceOf(caller);
        uint256 beforeManager = gamma.balanceOf(address(manager));
        // Every fee was funded by a completed, settled swap. It must remain redeemable in full.
        assertGe(beforeManager, due);
        vm.prank(caller);
        uint256 paid = hook.redeemFees();
        assertEq(paid, due);
        assertEq(hook.pendingFees(), 0);
        assertEq(gamma.balanceOf(address(game)), beforeGame + due);
        assertEq(gamma.balanceOf(address(manager)), beforeManager - due);
        assertEq(gamma.balanceOf(caller), beforeCaller, "redemption paid the caller");
        expectedPots[game.today()] += due;
        if (due != 0) ++redemptions;
        assertSettled();
    }

    function rejectExactOutputBuy(uint256 who, uint256 seed) external {
        address actor = actors[who % 3];
        bytes32 beforeState = stateDigest(actor);
        vm.prank(actor);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(GammaHook.ExactOutputBuyNotSupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(
            key,
            SwapParams(!gammaIs0, int256(bound(seed, 1, uint256(uint128(type(int128).max)))), limit(false)),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(address(game))
        );
        assertEq(stateDigest(actor), beforeState, "rejected swap changed funds or pool state");
        ++rejectedTrades;
        assertSettled();
    }

    function rejectForgedCallback(uint256 who, uint8 which) external {
        address actor = actors[who % 3];
        SwapParams memory params = SwapParams(gammaIs0, -int256(1e18), limit(true));
        bytes memory data;
        which %= 5;
        if (which == 0) {
            data = abi.encodeCall(hook.beforeInitialize, (address(game), key, uint160(1 << 96)));
        } else if (which == 1) {
            data = abi.encodeCall(hook.afterInitialize, (address(game), key, uint160(1 << 96), int24(0)));
        } else if (which == 2) {
            data = abi.encodeCall(hook.beforeSwap, (address(game), key, params, bytes("")));
        } else if (which == 3) {
            data =
                abi.encodeCall(hook.afterSwap, (address(game), key, params, BalanceDeltaLibrary.ZERO_DELTA, bytes("")));
        } else {
            data = abi.encodeCall(hook.unlockCallback, (bytes("")));
        }
        bytes32 beforeState = stateDigest(actor);
        vm.prank(actor);
        (bool ok, bytes memory reason) = address(hook).call(data);
        assertFalse(ok, "forged manager callback accepted");
        assertEq(reason, abi.encodeWithSelector(GammaHook.NotPoolManager.selector));
        assertEq(stateDigest(actor), beforeState);
    }

    function _trade(address actor, bool sell, int256 specified) internal {
        uint256 beforeGame = gamma.balanceOf(address(game));
        uint256 beforeGamma = gamma.balanceOf(actor);
        uint256 beforeImd = imd.balanceOf(actor);
        uint256 beforePending = hook.pendingFees();
        uint256 rate = hook.feeBps();
        vm.recordLogs();
        vm.prank(actor);
        BalanceDelta result = router.swap(
            key, SwapParams(sell == gammaIs0, specified, limit(sell)), PoolSwapTest.TestSettings(false, false), ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (int256 poolGamma, int256 poolImd) = readPoolSwap(logs);
        uint256 fee;
        if (!sell) {
            assertGe(poolGamma, 0);
            fee = uint256(poolGamma) * rate / 10_000;
            assertEq(gamma.balanceOf(actor) - beforeGamma + fee, uint256(poolGamma), "buy output fee");
        } else {
            assertLe(poolGamma, 0);
            if (specified < 0) {
                fee = uint256(-specified) * rate / 10_000;
                assertEq(beforeGamma - gamma.balanceOf(actor), uint256(-specified), "sell not fully filled");
            } else {
                fee = uint256(-poolGamma) * rate / (10_000 - rate);
                assertEq(imd.balanceOf(actor) - beforeImd, uint256(specified), "exact output not delivered");
            }
            assertEq(beforeGamma - gamma.balanceOf(actor), uint256(-poolGamma) + fee, "sell payment fee");
        }
        int256 paidGamma = int256(gamma.balanceOf(actor)) - int256(beforeGamma);
        int256 paidImd = int256(imd.balanceOf(actor)) - int256(beforeImd);
        assertEq(paidGamma, gammaIs0 ? result.amount0() : result.amount1(), "returned GAMMA delta");
        assertEq(paidImd, gammaIs0 ? result.amount1() : result.amount0(), "returned IMD delta");
        assertEq(paidImd, poolImd, "hook changed the IMD leg");
        uint256 delivered = gamma.balanceOf(address(game)) - beforeGame;
        assertEq(delivered + hook.pendingFees() - beforePending, fee, "fee lost or double counted");
        assertFeeEvents(logs, fee, rate, hook.pendingFees() - beforePending);
        expectedFees += fee;
        expectedPots[game.today()] += delivered;
        ++successfulTrades;
        assertSettled();
    }

    function readPoolSwap(Vm.Log[] memory logs) internal view returns (int256 g, int256 i) {
        uint256 matches;
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].emitter != address(manager) || logs[j].topics.length != 3 || logs[j].topics[0] != SWAP) {
                continue;
            }
            assertEq(logs[j].topics[1], hook.poolId());
            (int128 a0, int128 a1,,,, uint24 lpFee) =
                abi.decode(logs[j].data, (int128, int128, uint160, uint128, int24, uint24));
            assertEq(lpFee, 12_500, "hook changed launch LP fee");
            g = gammaIs0 ? a0 : a1;
            i = gammaIs0 ? a1 : a0;
            ++matches;
        }
        assertEq(matches, 1, "expected one AMM swap observation");
    }

    function assertFeeEvents(Vm.Log[] memory logs, uint256 fee, uint256 rate, uint256 deferred) internal view {
        uint256 fees;
        uint256 deferrals;
        for (uint256 j; j < logs.length; ++j) {
            if (logs[j].emitter != address(hook) || logs[j].topics.length == 0) continue;
            if (logs[j].topics[0] == keccak256("TradingFee(address,uint256,uint256)")) {
                assertEq(logs[j].topics.length, 2);
                assertEq(logs[j].topics[1], bytes32(uint256(uint160(address(gamma)))));
                (uint256 amount, uint256 bps) = abi.decode(logs[j].data, (uint256, uint256));
                assertEq(amount, fee);
                assertEq(bps, rate);
                ++fees;
            } else if (logs[j].topics[0] == keccak256("FeesDeferred(uint256)")) {
                assertEq(abi.decode(logs[j].data, (uint256)), deferred);
                ++deferrals;
            }
        }
        assertEq(fees, fee == 0 ? 0 : 1, "fee event count");
        assertEq(deferrals, deferred == 0 ? 0 : 1, "deferral event count");
    }

    function limit(bool sell) internal view returns (uint160) {
        return sell == gammaIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function stateDigest(address actor) internal view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(manager, key.toId());
        return keccak256(
            abi.encode(
                price,
                tick,
                protocolFee,
                lpFee,
                gamma.balanceOf(actor),
                imd.balanceOf(actor),
                gamma.balanceOf(address(manager)),
                imd.balanceOf(address(manager)),
                gamma.balanceOf(address(game)),
                game.getDay(game.today()).pot,
                hook.pendingFees(),
                hook.poolId(),
                hook.launchedAt()
            )
        );
    }

    function assertSettled() public view {
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
    }
}
