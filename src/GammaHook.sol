// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {IGammaGame} from "./interfaces/IGammaGame.sol";

/// @title GammaHook
/// @notice Uniswap v4 hook for the GAMMA/IMD pool. Every trade pays a fee that starts at 99% at launch and falls
/// one point per minute to 3% forever (from minute 96). 100% of it goes to today's Harvest: snipers and traders
/// pay the miners. The fee is taken in GAMMA wherever the swap shape allows, in IMD otherwise (exact-output buys),
/// which the game swaps into GAMMA. The game's own purchases are exempt. No owner.
contract GammaHook is IHooks {
    uint256 public constant BPS = 10_000;
    uint256 public constant START_FEE_BPS = 9_900;
    uint256 public constant FLOOR_FEE_BPS = 300;
    uint256 public constant DECAY_BPS_PER_MINUTE = 100;

    IPoolManager public immutable poolManager;
    address public immutable imd;
    IGammaGame public immutable game;

    Currency public gamma;
    bool public gammaIs0;
    bytes32 public poolId;
    uint64 public launchedAt;

    event TradingFee(address indexed currency, uint256 amount, uint256 feeBps);

    error NotPoolManager();
    error PoolAlreadySet();
    error NotImdPair();
    error HookNotImplemented();

    constructor(IPoolManager poolManager_, address imd_, IGammaGame game_) {
        poolManager = poolManager_;
        imd = imd_;
        game = game_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Current trading fee: 99% at launch (counted from the game's genesis), -1 point per minute, 3% from minute 96.
    function feeBps() public view returns (uint256) {
        // The decay starts when trading can start: the later of pool creation and the game's genesis.
        uint256 start = game.genesis();
        if (launchedAt == 0 || start == 0) return START_FEE_BPS;
        if (launchedAt > start) start = launchedAt;
        uint256 decay = (block.timestamp - start) / 60 * DECAY_BPS_PER_MINUTE;
        if (decay >= START_FEE_BPS - FLOOR_FEE_BPS) return FLOOR_FEE_BPS;
        return START_FEE_BPS - decay;
    }

    // ------------------------------------------------------------------ initialize: one GAMMA/IMD pool only

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (launchedAt != 0) revert PoolAlreadySet();
        if (Currency.unwrap(key.currency0) != imd && Currency.unwrap(key.currency1) != imd) revert NotImdPair();
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        gammaIs0 = Currency.unwrap(key.currency1) == imd;
        gamma = gammaIs0 ? key.currency0 : key.currency1;
        poolId = keccak256(abi.encode(key));
        launchedAt = uint64(block.timestamp);
        return IHooks.afterInitialize.selector;
    }

    // ------------------------------------------------------------------ swaps

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Exact-input sells: take the fee from the GAMMA going in, before it is swapped.
        if (sender != address(game) && params.amountSpecified < 0 && _inputIsGamma(params)) {
            uint256 fee = uint256(-params.amountSpecified) * feeBps() / BPS;
            if (fee > 0) {
                _collect(gamma, fee);
                return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
            }
        }
        key; // silence unused
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        if (sender == address(game)) return (IHooks.afterSwap.selector, 0);

        bool exactIn = params.amountSpecified < 0;
        if (exactIn && _inputIsGamma(params)) return (IHooks.afterSwap.selector, 0); // charged in beforeSwap

        // Unspecified side: the output of an exact-input buy (GAMMA), or the input of an exact-output swap.
        bool specifiedIs0 = exactIn == params.zeroForOne;
        (Currency feeCurrency, int128 amount) =
            specifiedIs0 ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0());
        if (amount < 0) amount = -amount;

        uint256 fee = uint256(uint128(amount)) * feeBps() / BPS;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);
        _collect(feeCurrency, fee);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    function _inputIsGamma(SwapParams calldata params) internal view returns (bool) {
        return params.zeroForOne == gammaIs0;
    }

    function _collect(Currency currency, uint256 amount) internal {
        poolManager.take(currency, address(game), amount);
        game.onHookFee(currency, amount);
        emit TradingFee(Currency.unwrap(currency), amount, feeBps());
    }

    // ------------------------------------------------------------------ not enabled

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
