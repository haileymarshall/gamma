// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {GammaGame} from "src/GammaGame.sol";

/// @notice Step 3 of the IMD launch: wire the game to the pool the network's factory created. After this call
/// the configurator has no power left over the game.
/// GAME=0x.. GAMMA=0x.. HOOK=0x.. LP_FEE=12500 TICK_SPACING=60 \
///   forge script script/InitializeGame.s.sol --rpc-url $RPC --broadcast --account me
contract InitializeGame is Script {
    function run() external {
        GammaGame game = GammaGame(vm.envAddress("GAME"));
        address gamma = vm.envAddress("GAMMA");
        address imd = address(game.imd());
        bool gammaIs0 = gamma < imd;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(gammaIs0 ? gamma : imd),
            currency1: Currency.wrap(gammaIs0 ? imd : gamma),
            fee: uint24(vm.envUint("LP_FEE")),
            tickSpacing: int24(int256(vm.envUint("TICK_SPACING"))),
            hooks: IHooks(vm.envAddress("HOOK"))
        });

        vm.startBroadcast();
        game.initialize(key);
        vm.stopBroadcast();

        console2.log("GAMMA game live, genesis", game.genesis());
    }
}
