// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {GammaGame} from "src/GammaGame.sol";
import {GammaHook} from "src/GammaHook.sol";
import {GammaToken} from "src/GammaToken.sol";
import {DrandBeacon} from "src/DrandBeacon.sol";
import {IGammaGame} from "src/interfaces/IGammaGame.sol";
import {HookMiner} from "./HookMiner.sol";

/// @notice Full GAMMA stack on a local anvil (or any testnet): PoolManager, mock IMD, real drand beacon,
/// game, mined hook, pool with 100M GAMMA of liquidity and the 800M Reserve.
/// forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key $PK
contract DeployLocal is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint24 constant LP_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    /// @dev 1 GAMMA = 0.01 IMD at open.
    uint160 constant OPEN_SQRT_PRICE_GAMMA_IS_0 = 7922816251426433759354395033; // sqrt(0.01) * 2^96
    uint160 constant OPEN_SQRT_PRICE_GAMMA_IS_1 = 792281625142643375935439503360; // sqrt(100) * 2^96

    function run() external {
        address me = msg.sender;
        vm.startBroadcast();

        PoolManager manager = new PoolManager(me);
        MockERC20 imd = new MockERC20("Identity.md (test)", "IMD", 18);
        DrandBeacon beacon = new DrandBeacon();
        GammaGame game = new GammaGame(IPoolManager(address(manager)), ERC20(address(imd)), beacon, me);
        GammaToken gamma = new GammaToken(me);

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory args = abi.encode(address(manager), address(imd), address(game));
        (address hookAddr, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, type(GammaHook).creationCode, args);
        GammaHook hook = new GammaHook{salt: salt}(IPoolManager(address(manager)), address(imd), IGammaGame(address(game)));
        require(address(hook) == hookAddr, "hook address");

        bool gammaIs0 = address(gamma) < address(imd);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(gammaIs0 ? address(gamma) : address(imd)),
            currency1: Currency.wrap(gammaIs0 ? address(imd) : address(gamma)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, gammaIs0 ? OPEN_SQRT_PRICE_GAMMA_IS_0 : OPEN_SQRT_PRICE_GAMMA_IS_1);

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        imd.mint(me, 100_000_000e18);
        gamma.approve(address(lp), type(uint256).max);
        imd.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 10_000_000e18,
                salt: 0
            }),
            ""
        );

        gamma.transfer(address(game), game.RESERVE());
        game.initialize(key);

        vm.stopBroadcast();

        console2.log("PoolManager ", address(manager));
        console2.log("IMD         ", address(imd));
        console2.log("GAMMA       ", address(gamma));
        console2.log("DrandBeacon ", address(beacon));
        console2.log("GammaGame   ", address(game));
        console2.log("GammaHook   ", address(hook));
        console2.log("SwapRouter  ", address(swapRouter));
    }
}
