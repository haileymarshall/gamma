// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {GammaGame} from "src/GammaGame.sol";
import {GammaHook} from "src/GammaHook.sol";
import {GammaToken} from "src/GammaToken.sol";
import {IGammaBeacon} from "src/interfaces/IGammaBeacon.sol";
import {IGammaGame} from "src/interfaces/IGammaGame.sol";

contract MockBeacon is IGammaBeacon {
    mapping(uint64 => bytes32) public randomness;

    function genesis() external pure returns (uint64) {
        return 1727521075;
    }

    function period() external pure returns (uint64) {
        return 3;
    }

    function set(uint64 round, bytes32 value) external {
        randomness[round] = value;
    }

    function prove(uint64 round, bytes calldata signature) external returns (bytes32) {
        if (randomness[round] == bytes32(0)) randomness[round] = keccak256(signature);
        return randomness[round];
    }
}

abstract contract GammaFixture is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant LP_FEE = 12_500; // 1.25%, the IMD launch policy
    int24 constant TICK_SPACING = 60;

    PoolManager manager;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    MockERC20 imd;
    GammaToken gamma;
    MockBeacon beacon;
    GammaGame game;
    GammaHook hook;
    PoolKey key;
    bool gammaIs0;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    GammaGame.BeaconProof[] noProofs;

    function setUp() public virtual {
        vm.warp(1_760_000_000);

        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        imd = deployImd();
        beacon = new MockBeacon();
        gamma = new GammaToken();

        game = new GammaGame(IPoolManager(address(manager)), ERC20(address(imd)), beacon, address(this));

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        address hookAddr = address(uint160(0x4444 << 144) | flags);
        deployCodeTo("GammaHook.sol:GammaHook", abi.encode(address(manager), address(imd), address(game)), hookAddr);
        hook = GammaHook(hookAddr);

        gammaIs0 = address(gamma) < address(imd);
        key = PoolKey({
            currency0: Currency.wrap(gammaIs0 ? address(gamma) : address(imd)),
            currency1: Currency.wrap(gammaIs0 ? address(imd) : address(gamma)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddr)
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        // Reserve to the game, the rest seeds liquidity.
        gamma.transfer(address(game), game.RESERVE());
        imd.mint(address(this), 1_000_000_000e18);
        gamma.approve(address(lpRouter), type(uint256).max);
        imd.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 100_000_000e18,
                salt: 0
            }),
            ""
        );

        initializeGame();

        address[3] memory players = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            imd.mint(players[i], 50_000_000e18);
            vm.prank(players[i]);
            imd.approve(address(game), type(uint256).max);
        }
        // Get past the launch fee window so trades in tests are not dominated by the 99% fee.
        vm.warp(block.timestamp + 97 minutes);
    }

    // ------------------------------------------------------------------ helpers

    function deployImd() internal virtual returns (MockERC20) {
        return new MockERC20("Identity.md", "IMD", 18);
    }

    function initializeGame() internal virtual {
        game.initialize(key);
    }

    function buy(address who, uint8 machine, uint256 energies) internal returns (uint256 id) {
        vm.prank(who);
        id = game.buyEnergies(machine, energies, energies * 2_000e18, noProofs);
    }

    /// @dev Proves every round that settlement can be waiting on, up to the current epoch.
    function seedAll() internal {
        uint256 n = game.currentEpoch();
        for (uint256 i = game.activeCursor(); i < game.activeEpochCount(); ++i) {
            uint256 e = game.activeEpochs(i);
            if (e >= n) break;
            uint64 round = game.roundForEpoch(e);
            if (beacon.randomness(round) == bytes32(0)) beacon.set(round, keccak256(abi.encode("drand", round)));
        }
    }

    function settleAll() internal {
        seedAll();
        for (uint256 i; i < 200; ++i) {
            uint256 before = game.cursor();
            game.settle(256, noProofs);
            if (game.cursor() == before && game.cursor() >= game.currentEpoch()) break;
        }
    }

    function warpDays(uint256 d) internal {
        vm.warp(block.timestamp + d * 1 days);
    }

    function toNextDay() internal {
        uint256 end = game.dayEnd(game.today());
        vm.warp(end + 1);
    }

    function ids1(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function swapExactIn(address who, bool sellGamma, uint256 amountIn) internal {
        ERC20 tokenIn = sellGamma ? ERC20(address(gamma)) : ERC20(address(imd));
        vm.startPrank(who);
        tokenIn.approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = sellGamma == gammaIs0;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function swapExactOutBuy(address who, uint256 gammaOut) internal {
        vm.startPrank(who);
        imd.approve(address(swapRouter), type(uint256).max);
        bool zeroForOne = !gammaIs0;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(gammaOut),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }
}
