// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GammaFixture} from "./utils/GammaFixture.sol";
import {GammaToken} from "src/GammaToken.sol";
import {GammaHook} from "src/GammaHook.sol";
import {GammaGame} from "src/GammaGame.sol";
import {IGammaGame} from "src/interfaces/IGammaGame.sol";
import {HookMiner} from "script/HookMiner.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Only a test fixture: reproduces factory deployment, allocation and its own LP fee collection.
contract GammaLaunchFactoryProbe is IUnlockCallback {
    IPoolManager immutable manager;
    GammaToken public token;
    GammaHook public hook;
    PoolKey private key;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function launch(address imd, IGammaGame game, address distributor, bytes32 salt) external {
        token = new GammaToken();
        hook = new GammaHook{salt: salt}(manager, imd, game);
        bool gammaIs0 = address(token) < imd;
        key = PoolKey(
            Currency.wrap(gammaIs0 ? address(token) : imd),
            Currency.wrap(gammaIs0 ? imd : address(token)),
            12_500,
            60,
            hook
        );
        manager.initialize(key, 79228162514264337593543950336);
        token.transfer(address(game), 800_000_000e18);
        token.transfer(distributor, 100_000_000e18);
    }

    function getKey() external view returns (PoolKey memory) {
        return key;
    }

    function modify(int256 liquidity) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(liquidity)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), abi.decode(data, (int256)), 0
            ),
            ""
        );
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta) internal {
        if (delta < 0) {
            manager.sync(currency);
            currency.transfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(int256(delta)));
        }
    }
}

contract GammaHookLaunchTest is GammaFixture {
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    function test_factoryDeploysAllocatesInitializesAndCollects() public {
        GammaLaunchFactoryProbe factory = new GammaLaunchFactoryProbe(manager);
        GammaGame freshGame = new GammaGame(manager, imd, beacon, address(this));
        (address predicted, bytes32 salt) = HookMiner.find(
            address(factory), FLAGS, type(GammaHook).creationCode, abi.encode(manager, address(imd), freshGame)
        );
        address distributor = makeAddr("launch distributor");
        factory.launch(address(imd), freshGame, distributor, salt);
        assertEq(address(factory.hook()), predicted);
        GammaToken token = factory.token();
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(distributor), 100_000_000e18);
        assertEq(token.balanceOf(address(freshGame)), freshGame.RESERVE());
        assertEq(token.balanceOf(address(factory)), 100_000_000e18);
        PoolKey memory factoryKey = factory.getKey();
        assertEq(factory.hook().poolId(), keccak256(abi.encode(factoryKey)));
        assertEq(Currency.unwrap(factory.hook().gamma()), address(token));
        freshGame.initialize(factoryKey);
        imd.mint(address(factory), 100_000_000e18);
        factory.modify(100_000_000e18);
        // Accrue real LP fees, then collect using the factory's own zero-liquidity modification.
        gamma = token;
        game = freshGame;
        hook = factory.hook();
        key = factoryKey;
        gammaIs0 = address(token) < address(imd);
        swapExactIn(bob, false, 1_000e18);
        BalanceDelta collected = factory.modify(0);
        assertGe(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        assertGt(int256(collected.amount0()) + int256(collected.amount1()), 0);
        factory.modify(-int256(100_000_000e18));
        _checkRuntime(address(hook));
        _checkRuntime(address(token));
    }

    function test_hookConstructorNeedsNoLiveDependencies() public {
        IPoolManager emptyManager = IPoolManager(makeAddr("empty manager"));
        address pair = makeAddr("empty pair");
        IGammaGame recipient = IGammaGame(makeAddr("empty game"));
        assertEq(address(emptyManager).code.length + pair.code.length + address(recipient).code.length, 0);
        (address predicted, bytes32 salt) = HookMiner.find(
            address(this), FLAGS, type(GammaHook).creationCode, abi.encode(emptyManager, pair, recipient)
        );
        GammaHook fresh = new GammaHook{salt: salt}(emptyManager, pair, recipient);
        assertEq(address(fresh), predicted);
        assertEq(address(fresh.poolManager()), address(emptyManager));
        assertEq(fresh.imd(), pair);
        assertEq(address(fresh.game()), address(recipient));
        Hooks.validateHookPermissions(fresh, fresh.getHookPermissions());
    }

    function test_permissionsAreExactlyTheSixRequested() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.afterInitialize && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity || p.afterRemoveLiquidity);
        assertFalse(
            p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
    }

    function _checkRuntime(address target) internal view {
        bytes memory runtime = target.code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }
}

contract GammaTokenLaunchTest is Test {
    function test_supplyMetadataAndTransfer() public {
        address factory = makeAddr("token factory");
        vm.prank(factory);
        GammaToken token = new GammaToken();
        assertEq(token.name(), "Gamma");
        assertEq(token.symbol(), "GAMMA");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(factory), 1e27);
        address recipient = makeAddr("holder");
        vm.prank(factory);
        assertTrue(token.transfer(recipient, 12_345e18));
        assertEq(token.balanceOf(recipient), 12_345e18);
        assertEq(token.balanceOf(factory), 1e27 - 12_345e18);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_neitherFactoryNorHolderCanMintOrConfigureToken() public {
        GammaToken token = new GammaToken();
        address attacker = makeAddr("attacker");
        bytes[5] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", attacker, 1e18),
            abi.encodeWithSignature("setOwner(address)", attacker),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("setMinter(address)", attacker),
            abi.encodeWithSignature("upgradeTo(address)", attacker)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool factoryOk,) = address(token).call(calls[i]);
            assertFalse(factoryOk);
            vm.prank(attacker);
            (bool attackerOk,) = address(token).call(calls[i]);
            assertFalse(attackerOk);
            assertEq(token.totalSupply(), 1e27);
        }
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(attacker), 0);
    }
}
