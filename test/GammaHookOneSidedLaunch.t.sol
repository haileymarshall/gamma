// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockBeacon} from "./utils/GammaFixture.sol";
import {GammaToken} from "src/GammaToken.sol";
import {GammaGame} from "src/GammaGame.sol";
import {GammaHook} from "src/GammaHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @dev Offline reconstruction at the brief's three addresses. Constructors run at those addresses,
/// including PoolManager's NoDelegateCall immutable. No fork state or RPC is required.
contract GammaHookOneSidedLaunchTest is Test {
    address constant MANAGER = address(bytes20(hex"8366a39cc670b4001a1121b8f6a443a643e40951"));
    address constant IMD = address(bytes20(hex"5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127"));
    address constant GAME = address(bytes20(hex"b333a22c2c3dd0fe29fd1bf184c5ff2282148535"));
    PoolManager internal manager;
    PoolSwapTest internal router;
    GammaToken internal gamma;
    MockERC20 internal imd;
    GammaGame internal game;
    GammaHook internal hook;
    PoolKey internal key;
    bool internal gammaIs0;
    address internal buyer;

    function setUp() public {
        vm.warp(1_760_000_000);
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), MANAGER);
        manager = PoolManager(MANAGER);
        deployCodeTo(
            "lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20",
            abi.encode("IMD", "IMD", uint8(18)),
            IMD
        );
        imd = MockERC20(IMD);
        MockBeacon beacon = new MockBeacon();
        deployCodeTo("GammaGame.sol:GammaGame", abi.encode(manager, imd, beacon, address(this)), GAME);
        game = GammaGame(GAME);
        gamma = new GammaToken();
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        address at = address(uint160(0x8888 << 144) | flags);
        deployCodeTo("GammaHook.sol:GammaHook", abi.encode(manager, IMD, game), at);
        hook = GammaHook(at);
        gammaIs0 = address(gamma) < IMD;
        key = PoolKey(
            Currency.wrap(gammaIs0 ? address(gamma) : IMD),
            Currency.wrap(gammaIs0 ? IMD : address(gamma)),
            12_500,
            60,
            hook
        );
        manager.initialize(key, uint160(1 << 96));
        gamma.transfer(GAME, 800_000_000e18);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        gamma.approve(address(lp), type(uint256).max);
        // Price starts on the edge of the range: all deposited liquidity is GAMMA, no IMD or ETH.
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                gammaIs0 ? int24(0) : TickMath.minUsableTick(60),
                gammaIs0 ? TickMath.maxUsableTick(60) : int24(0),
                100_000_000e18,
                0
            ),
            ""
        );
        assertEq(imd.balanceOf(MANAGER), 0);
        assertEq(MANAGER.balance, 0);
        assertApproxEqAbs(gamma.balanceOf(MANAGER), 100_000_000e18, 10_000_000);
        assertEq(gamma.balanceOf(GAME), 800_000_000e18);
        router = new PoolSwapTest(manager);
        buyer = makeAddr("one sided pool buyer");
        imd.mint(buyer, 10_000_000e18);
        vm.prank(buyer);
        imd.approve(address(router), type(uint256).max);
    }

    function test_firstBuyBeforeGenesisPaysGammaAndBecomesDayZeroHarvest() public {
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(hook.feeBps(), 9_900);
        uint256 fee = firstBuy(1_000e18);
        assertEq(game.genesis(), 0);
        assertEq(game.getDay(0).pot, 0);
        game.initialize(key);
        assertEq(game.getDay(0).pot, fee);
        assertEq(game.gammaHeld(), gamma.balanceOf(GAME));
        assertEq(game.sweep(), 0, "pre-genesis fee counted twice");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_firstBuyNeedsNoPrefundedImdOrEth(uint96 amountSeed, uint8 minuteSeed) public {
        game.initialize(key);
        vm.warp(uint256(game.genesis()) + bound(minuteSeed, 0, 200) * 60);
        uint256 fee = firstBuy(bound(amountSeed, 1e18, 1_000_000e18));
        assertEq(game.getDay(0).pot, fee);
        assertEq(game.gammaHeld(), gamma.balanceOf(GAME));
    }

    function test_sellWithNoBuySideLiquidityRevertsWithoutChargingFee() public {
        game.initialize(key);
        gamma.approve(address(router), type(uint256).max);
        uint256 beforeSeller = gamma.balanceOf(address(this));
        uint256 beforeManager = gamma.balanceOf(MANAGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(GammaHook.PartialFillSellNotSupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.swap(
            key,
            SwapParams(gammaIs0, -int256(1e18), gammaIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(gamma.balanceOf(address(this)), beforeSeller);
        assertEq(gamma.balanceOf(MANAGER), beforeManager);
        assertEq(gamma.balanceOf(GAME), 800_000_000e18);
        assertEq(game.getDay(0).pot, 0);
        assertEq(hook.pendingFees(), 0);
        // A rejected sell must not prevent the first buy from opening trading in the range.
        assertGt(firstBuy(1_000e18), 0);
    }

    function firstBuy(uint256 amount) internal returns (uint256 fee) {
        assertEq(imd.balanceOf(MANAGER), 0, "fixture must be a fresh manager");
        uint256 beforeGame = gamma.balanceOf(GAME);
        uint256 beforeManager = gamma.balanceOf(MANAGER);
        uint256 beforeBuyer = imd.balanceOf(buyer);
        vm.prank(buyer);
        BalanceDelta result = router.swap(
            key,
            SwapParams(
                !gammaIs0, -int256(amount), gammaIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        fee = gamma.balanceOf(GAME) - beforeGame;
        uint256 received = gamma.balanceOf(buyer);
        assertGt(received, 0);
        assertGt(fee, 0);
        assertEq(uint256(int256(gammaIs0 ? result.amount0() : result.amount1())), received);
        assertEq(fee, (fee + received) * hook.feeBps() / 10_000);
        assertEq(beforeManager - gamma.balanceOf(MANAGER), fee + received);
        assertEq(beforeBuyer - imd.balanceOf(buyer), amount);
        assertEq(imd.balanceOf(MANAGER), amount);
        assertEq(imd.balanceOf(GAME), 0);
        assertEq(hook.pendingFees(), 0);
        assertEq(gamma.balanceOf(address(hook)), 0);
    }
}
