// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GammaFixture} from "./utils/GammaFixture.sol";
import {GammaHookLedger} from "./utils/GammaHookLedger.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

abstract contract GammaHookLedgerInvariant is GammaFixture {
    GammaHookLedger internal ledger;
    uint256 internal initialLaunchedAt;
    bytes32 internal initialPoolId;

    function setUp() public override {
        super.setUp();
        vm.warp(hook.launchedAt());
        gamma.transfer(alice, 50_000_000e18);
        gamma.transfer(carol, 40_000_000e18);
        // Reach the real liquidity-shortfall path before random actions start. No manager balance edits.
        imd.mint(bob, 1e29);
        swapExactIn(bob, false, 1e29);
        swapExactIn(alice, true, 40_000_000e18);
        assertEq(hook.pendingFees(), 39_600_000e18, "campaign must start with live claims");
        for (uint256 i; i < 3; ++i) {
            imd.mint([alice, bob, carol][i], 1e30);
        }
        ledger = new GammaHookLedger(hook, game, gamma, ERC20(address(imd)), swapRouter, key, [alice, bob, carol]);
        initialLaunchedAt = hook.launchedAt();
        initialPoolId = hook.poolId();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = ledger.tradeExactInput.selector;
        selectors[1] = ledger.sellExactOutput.selector;
        selectors[2] = ledger.advance.selector;
        selectors[3] = ledger.redeem.selector;
        selectors[4] = ledger.rejectExactOutputBuy.selector;
        selectors[5] = ledger.rejectForgedCallback.selector;
        targetContract(address(ledger));
        targetSelector(FuzzSelector(address(ledger), selectors));
    }

    function invariant_everyAssessedFeeIsDeliveredOrBackedByClaims() public view {
        assertEq(
            gamma.balanceOf(address(game)) - ledger.initialGameBalance() + hook.pendingFees(),
            ledger.expectedFees(),
            "GAMMA fee conservation"
        );
        assertEq(manager.balanceOf(address(hook), uint160(address(gamma))), hook.pendingFees(), "claim accounting");
        assertGe(gamma.balanceOf(address(manager)), hook.pendingFees(), "claims lost token backing");
        assertEq(game.gammaHeld(), gamma.balanceOf(address(game)), "game custody mirror");
        for (uint256 d; d < 8; ++d) {
            assertEq(game.getDay(d).pot, ledger.expectedPots(d), "wrong Harvest day or amount");
        }
    }

    function invariant_fixedSupplyAndNoFeeLeakage() public view {
        uint256 held =
            gamma.balanceOf(address(this)) + gamma.balanceOf(address(manager)) + gamma.balanceOf(address(game));
        held += gamma.balanceOf(alice) + gamma.balanceOf(bob) + gamma.balanceOf(carol);
        assertEq(held, 1_000_000_000e18, "GAMMA escaped the tracked participants");
        assertEq(gamma.totalSupply(), 1_000_000_000e18);
        assertEq(gamma.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(game)), 0, "Harvest received IMD");
        assertEq(manager.balanceOf(address(hook), uint160(address(imd))), 0, "IMD fee claims");
        assertEq(gamma.balanceOf(address(swapRouter)), 0);
        assertEq(imd.balanceOf(address(swapRouter)), 0);
        ledger.assertSettled();
    }

    function invariant_poolBindingAndFeeBoundsNeverChange() public view {
        assertEq(hook.poolId(), initialPoolId);
        assertEq(hook.launchedAt(), initialLaunchedAt);
        assertEq(Currency.unwrap(hook.gamma()), address(gamma));
        assertEq(hook.gammaIs0(), gammaIs0);
        assertGe(hook.feeBps(), 300);
        assertLe(hook.feeBps(), 9_900);
    }

    function afterInvariant() public {
        ledger.redeem(2);
        assertEq(hook.pendingFees(), 0, "fee exit unavailable after sequence");
        invariant_everyAssessedFeeIsDeliveredOrBackedByClaims();
        invariant_fixedSupplyAndNoFeeLeakage();
    }

    /// @dev Deterministic smoke sequence proves that all successful actions and the live redemption are reachable.
    function test_ledgerActionsAreLive() public {
        ledger.rejectExactOutputBuy(0, 1e18);
        for (uint8 i; i < 5; ++i) {
            ledger.rejectForgedCallback(i, i);
        }
        ledger.tradeExactInput(0, 1_000e18, true, false);
        ledger.tradeExactInput(1, 1_000e18, false, false);
        ledger.sellExactOutput(2, 1e15);
        ledger.advance(1 days, true);
        ledger.redeem(1);
        assertEq(ledger.successfulTrades(), 3);
        assertEq(ledger.rejectedTrades(), 1);
        assertEq(ledger.redemptions(), 1);
        invariant_everyAssessedFeeIsDeliveredOrBackedByClaims();
        invariant_fixedSupplyAndNoFeeLeakage();
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract GammaHookLedgerGamma0Test is GammaHookLedgerInvariant {
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

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract GammaHookLedgerGamma1Test is GammaHookLedgerInvariant {
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
