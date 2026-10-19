// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {IGammaGame} from "./interfaces/IGammaGame.sol";

/// @title GammaHook
/// @notice Uniswap v4 hook for GAMMA/IMD. Fees stay at 99% until genesis, then fall one point per minute from
/// the later of genesis and pool creation to 3% forever (minute 96). All fees are GAMMA for the game's Harvest.
/// A fee the manager cannot transfer yet is held as a claim for permissionless redemption to the game.
/// Exact-output buys are refused (buy with exact IMD input instead); exact-input sells must fill completely.
/// The game's own swaps are exempt. No owner.
contract GammaHook is IHooks, IUnlockCallback {
    using SafeCast for uint256;
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

    /// @notice GAMMA fees held as PoolManager claims until its token balance can pay the game.
    uint256 public pendingFees;

    event TradingFee(address indexed currency, uint256 amount, uint256 feeBps);
    event FeesDeferred(uint256 amount);
    event FeesRedeemed(uint256 amount);

    error NotPoolManager();
    error PoolAlreadySet();
    error NotImdPair();
    error HookNotImplemented();
    error ExactOutputBuyNotSupported();
    error PartialFillSellNotSupported();

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
        // Decay starts only after both pool creation and the game's genesis; earlier trades still pay 99%.
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

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender == address(game)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        // Exact-output buys would pay the fee in IMD; refuse them so the Harvest only ever receives GAMMA.
        if (params.amountSpecified > 0 && !_inputIsGamma(params)) revert ExactOutputBuyNotSupported();
        // Reserve the sell fee from the specified input. Collection waits until afterSwap verifies a full fill.
        if (params.amountSpecified < 0 && _inputIsGamma(params)) {
            uint256 fee = uint256(-params.amountSpecified) * feeBps() / BPS;
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address sender, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (sender == address(game)) return (IHooks.afterSwap.selector, 0);

        uint256 rate = feeBps();
        int256 gammaDelta = gammaIs0 ? delta.amount0() : delta.amount1();
        uint256 amount = uint256(gammaDelta < 0 ? -gammaDelta : gammaDelta);
        bool sell = _inputIsGamma(params);
        if (params.amountSpecified < 0 && sell) {
            uint256 requested = uint256(-params.amountSpecified);
            uint256 reservedFee = requested * rate / BPS;
            // afterSwap can only return an unspecified (IMD) delta here, so it cannot refund a GAMMA fee.
            // Revert the entire trade if the price limit or available liquidity leaves input unspent.
            if (amount != requested - reservedFee) revert PartialFillSellNotSupported();
            if (reservedFee > 0) _collect(reservedFee, rate);
            return (IHooks.afterSwap.selector, 0); // fee already reserved by the specified beforeSwap delta
        }

        // Buys: fee is a share of the realised GAMMA output. Exact-output sells: gross up the realised
        // GAMMA input so the Harvest gets rate/BPS of the seller's total payment, just as for exact input.
        uint256 fee = amount * rate / (sell ? BPS - rate : BPS);
        if (fee == 0) return (IHooks.afterSwap.selector, 0);
        int128 feeDelta = fee.toInt128();
        _collect(fee, rate);
        return (IHooks.afterSwap.selector, feeDelta);
    }

    function _inputIsGamma(SwapParams calldata params) internal view returns (bool) {
        return params.zeroForOne == gammaIs0;
    }

    function _collect(uint256 amount, uint256 rate) internal {
        // The router has not settled its input yet. A large sell must not depend on existing GAMMA reserves.
        if (gamma.balanceOf(address(poolManager)) >= amount) {
            _sendToGame(amount);
        } else {
            pendingFees += amount;
            poolManager.mint(address(this), gamma.toId(), amount);
            emit FeesDeferred(amount);
        }
        emit TradingFee(Currency.unwrap(gamma), amount, rate);
    }

    function _sendToGame(uint256 amount) internal {
        poolManager.take(gamma, address(game), amount);
        // Before genesis the existing game's initialize credits all surplus above its 800M Reserve to day 0.
        // Calling onHookFee before that wiring would revert NotHook and freeze ordinary trading.
        if (game.genesis() != 0) game.onHookFee(gamma, amount);
    }

    /// @notice Anyone may redeem deferred fees after the swap's unlock completes. All GAMMA goes to the game;
    /// the game credits the Harvest on receipt (day 0 if redeemed before genesis). No caller can redirect it.
    function redeemFees() external returns (uint256 amount) {
        if (pendingFees == 0) return 0;
        return abi.decode(poolManager.unlock(""), (uint256));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 amount = pendingFees;
        uint256 available = gamma.balanceOf(address(poolManager));
        if (amount > available) amount = available;
        if (amount > 0) {
            pendingFees -= amount;
            poolManager.burn(address(this), gamma.toId(), amount);
            _sendToGame(amount);
            emit FeesRedeemed(amount);
        }
        return abi.encode(amount);
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
