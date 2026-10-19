// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {GammaEmission} from "./libraries/GammaEmission.sol";
import {IGammaBeacon} from "./interfaces/IGammaBeacon.sol";
import {IGammaGame} from "./interfaces/IGammaGame.sol";
import {IGammaHook} from "./interfaces/IGammaHook.sol";

/// @title GammaGame
/// @notice GAMMA can only be mined by playing. Players burn GAMMA (bought with IMD) for energies, place them on
/// one of four machines, and every 10 minutes the Reserve's fixed tranche is shared among the miners: survivors
/// split the Shares, failures split the evening Harvest. No owner, no mint, no withdraw.
contract GammaGame is IGammaGame, IUnlockCallback, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    // ------------------------------------------------------------------ constants

    uint256 public constant EPOCH = 10 minutes;
    uint256 public constant EPOCHS_PER_DAY = 144;
    uint256 public constant DAY = 1 days;

    uint256 public constant RESERVE = GammaEmission.TOTAL;
    uint256 public constant ENERGY_COST = 1_000e18;
    uint256 public constant MAX_BATCH = 500;

    uint256 public constant BPS = 10_000;
    uint256 public constant SHARES_BPS = 9_000;

    uint256 public constant CLAIM_FEE_START_BPS = 8_000;
    uint256 public constant CLAIM_FEE_END_BPS = 1_000;

    /// @notice Settlement work bundled into every purchase and claim, so an active game settles itself.
    uint256 public constant AUTO_SETTLE_UNITS = 8;
    uint256 public constant MAX_SETTLE_UNITS = 256;

    /// @notice Launch guardrail: per machine, per epoch energy cap for the first week. Lifts by itself.
    uint256 public constant GUARD_PERIOD = 7 days;
    uint256 public constant GUARD_ENERGIES_PER_MACHINE = 2_000;

    /// @notice drand round used for an epoch is the first one at least this long after the epoch closes.
    uint256 public constant BEACON_DELAY = 6;
    /// @notice If the beacon never delivers, settlement falls back to block data after this long so funds never freeze.
    uint256 public constant BEACON_FALLBACK = 2 hours;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant INDEX_SCALE = 1e36;

    // ------------------------------------------------------------------ immutables

    IPoolManager public immutable poolManager;
    ERC20 public immutable imd;
    IGammaBeacon public immutable beacon;
    address public immutable configurator;

    // ------------------------------------------------------------------ setup state

    ERC20 public gamma;
    address public hook;
    PoolKey internal _poolKey;
    bool internal _gammaIs0;
    uint64 public genesis;

    // ------------------------------------------------------------------ game state

    struct Batch {
        address owner;
        uint8 machine;
        bool drawn;
        bool claimed;
        uint32 epoch;
        uint16 energies;
        uint16 survivors;
    }

    struct Epoch {
        uint32 drawn;
        bool finalized;
        uint32[4] energies;
        uint32[4] survivors;
        uint256[4] payPerSurvivor;
        uint8[4] shareBps; // in units of 10%: 6, 2, 2, 0
    }

    struct Day {
        uint256 pot;
        uint256 fails;
        uint256 perFail;
        uint256 sharesPaid;
        uint256 bonusIndex;
        bool finalized;
    }

    struct BeaconProof {
        uint64 round;
        bytes signature;
    }

    Batch[] internal _batches;
    mapping(address => uint256[]) internal _userBatches;
    mapping(uint256 => uint256[]) internal _epochBatches;
    mapping(uint256 => Epoch) internal _epochs;
    mapping(uint256 => Day) internal _days;

    /// @notice Epochs that have at least one batch, in order. Empty epochs between them settle in one step.
    uint256[] public activeEpochs;
    uint256 public activeCursor;
    /// @notice Next epoch to finalize.
    uint256 public cursor;

    /// @notice Winnings of harvested, unclaimed batches. They earn a third of every claim fee.
    uint256 public totalUnclaimed;
    uint256 public bonusIndex;

    /// @notice IMD fees from exact-output buys, waiting to be swapped into today's Harvest.
    uint256 public pendingImd;

    uint256 public totalBurned;
    uint256 public totalEnergies;

    /// @notice GAMMA the game has accounted for. A hook fee is only credited once the tokens are really here.
    uint256 public gammaHeld;

    /// @notice Fallback seeding, per epoch: the block committed to, and the seed once that block's hash was read.
    /// Committing first and reading later means no settler can pick the block that seeds an epoch.
    mapping(uint256 => uint256) public fallbackBlock;
    mapping(uint256 => bytes32) public fallbackSeed;

    // ------------------------------------------------------------------ events and errors

    event Initialized(address gamma, address hook, uint64 genesis);
    event EnergiesBought(
        uint256 indexed batchId, address indexed owner, uint8 machine, uint256 epoch, uint256 energies, uint256 imdPaid
    );
    event BatchDrawn(uint256 indexed batchId, uint256 survivors);
    event EpochFinalized(uint256 indexed epoch, uint256 tranche, uint8[4] shareBps, uint256[4] payPerSurvivor);
    event Harvest(uint256 indexed day, uint256 pot, uint256 fails, uint256 perFail);
    event Claimed(address indexed owner, uint256 winnings, uint256 fee, uint256 bonus, uint256 paid);
    event HarvestFunded(uint256 indexed day, uint256 amount, uint8 source);
    event FallbackCommitted(uint256 indexed epoch, uint256 blockNumber);

    error NotConfigurator();
    error FeeNotReceived();
    error AlreadyInitialized();
    error NotInitialized();
    error BadPool();
    error ReserveNotFunded();
    error BadMachine();
    error BadAmount();
    error EpochCapReached();
    error NotPoolManager();
    error NotHook();
    error NotOwner();
    error SlippageExceeded();

    uint8 internal constant SOURCE_TRADING = 0;
    uint8 internal constant SOURCE_DONATION = 1;
    uint8 internal constant SOURCE_SURPLUS = 2;

    constructor(IPoolManager poolManager_, ERC20 imd_, IGammaBeacon beacon_, address configurator_) {
        poolManager = poolManager_;
        imd = imd_;
        beacon = beacon_;
        configurator = configurator_;
    }

    // ------------------------------------------------------------------ setup

    /// @notice One-time wiring to the GAMMA/IMD pool. Starts the clock. The configurator has no other power.
    function initialize(PoolKey calldata key) external {
        if (msg.sender != configurator) revert NotConfigurator();
        if (genesis != 0) revert AlreadyInitialized();

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 != address(imd) && c1 != address(imd)) revert BadPool();
        if (address(key.hooks) == address(0)) revert BadPool();

        _gammaIs0 = c1 == address(imd);
        gamma = ERC20(_gammaIs0 ? c0 : c1);
        hook = address(key.hooks);
        _poolKey = key;

        uint256 balance = gamma.balanceOf(address(this));
        if (balance < RESERVE) revert ReserveNotFunded();

        // The key must be the pool the hook was initialized with (so fee and tick spacing cannot be wrong, which
        // would lock the Reserve behind swaps that always revert), and the hook must be the one bound to this game.
        if (address(IGammaHook(hook).game()) != address(this)) revert BadPool();
        if (IGammaHook(hook).poolId() != keccak256(abi.encode(key))) revert BadPool();

        gammaHeld = balance;
        genesis = uint64(block.timestamp);
        if (balance > RESERVE) _fund(0, balance - RESERVE, SOURCE_SURPLUS);

        emit Initialized(address(gamma), hook, genesis);
    }

    // ------------------------------------------------------------------ play

    /// @notice Buys `energies` (each 1,000 GAMMA bought with IMD and burned) and places them on `machine`.
    /// @param maxImdIn Most IMD to spend; the unused part is refunded.
    /// @param proofs drand signatures for rounds settlement is waiting on (the frontend attaches them).
    function buyEnergies(uint8 machine, uint256 energies, uint256 maxImdIn, BeaconProof[] calldata proofs)
        external
        nonReentrant
        returns (uint256 batchId)
    {
        if (genesis == 0) revert NotInitialized();
        if (machine > 3) revert BadMachine();
        if (energies == 0 || energies > MAX_BATCH) revert BadAmount();

        _prove(proofs);
        _settle(AUTO_SETTLE_UNITS);

        uint256 e = currentEpoch();
        Epoch storage ep = _epochs[e];
        if (block.timestamp < genesis + GUARD_PERIOD && ep.energies[machine] + energies > GUARD_ENERGIES_PER_MACHINE) {
            revert EpochCapReached();
        }

        uint256 gammaNeeded = energies * ENERGY_COST;
        imd.safeTransferFrom(msg.sender, address(this), maxImdIn);
        uint256 imdSpent = abi.decode(poolManager.unlock(abi.encode(false, gammaNeeded, maxImdIn)), (uint256));
        if (imdSpent > maxImdIn) revert SlippageExceeded();
        if (maxImdIn > imdSpent) imd.safeTransfer(msg.sender, maxImdIn - imdSpent);

        gamma.safeTransfer(DEAD, gammaNeeded);
        totalBurned += gammaNeeded;
        totalEnergies += energies;

        if (_epochBatches[e].length == 0) activeEpochs.push(e);
        batchId = _batches.length;
        _batches.push(
            Batch({
                owner: msg.sender,
                machine: machine,
                drawn: false,
                claimed: false,
                epoch: uint32(e),
                energies: uint16(energies),
                survivors: 0
            })
        );
        _epochBatches[e].push(batchId);
        _userBatches[msg.sender].push(batchId);
        ep.energies[machine] += uint32(energies);

        emit EnergiesBought(batchId, msg.sender, machine, e, energies, imdSpent);
    }

    /// @notice Claims every ready batch, each at its own day's current fee.
    function claim(uint256[] calldata batchIds) external nonReentrant returns (uint256) {
        return _claim(batchIds, false);
    }

    /// @notice Claims only batches whose day has matured (24h after its Harvest), at the 10% floor fee.
    function claimMatured(uint256[] calldata batchIds) external nonReentrant returns (uint256) {
        return _claim(batchIds, true);
    }

    /// @notice Catch up settlement after a quiet period. Anyone can call.
    function settle(uint256 units, BeaconProof[] calldata proofs) external nonReentrant {
        if (genesis == 0) revert NotInitialized();
        _prove(proofs);
        _settle(units > MAX_SETTLE_UNITS ? MAX_SETTLE_UNITS : units);
    }

    /// @notice Adds GAMMA to today's Harvest.
    function donate(uint256 amount) external nonReentrant {
        if (genesis == 0) revert NotInitialized();
        gamma.safeTransferFrom(msg.sender, address(this), amount);
        gammaHeld += amount;
        _fund(today(), amount, SOURCE_DONATION);
    }

    /// @notice Swaps IMD trading fees into GAMMA for today's Harvest. Anyone can call.
    function convertPendingImd(uint256 minGammaOut) external nonReentrant {
        uint256 amount = pendingImd;
        if (amount == 0) return;
        pendingImd = 0;
        uint256 out = abi.decode(poolManager.unlock(abi.encode(true, amount, minGammaOut)), (uint256));
        gammaHeld += out;
        _fund(today(), out, SOURCE_TRADING);
    }

    /// @inheritdoc IGammaGame
    /// @dev Only tokens that actually arrived are credited: the hook's word alone never moves the Harvest.
    function onHookFee(Currency currency, uint256 amount) external nonReentrant {
        if (msg.sender != hook) revert NotHook();
        if (Currency.unwrap(currency) == address(gamma)) {
            if (gamma.balanceOf(address(this)) < gammaHeld + amount) revert FeeNotReceived();
            gammaHeld += amount;
            _fund(today(), amount, SOURCE_TRADING);
        } else {
            if (imd.balanceOf(address(this)) < pendingImd + amount) revert FeeNotReceived();
            pendingImd += amount;
        }
    }

    // ------------------------------------------------------------------ pool

    /// @dev data = (exactInImd, amount, limit). exactInImd=false: buy exactly `amount` GAMMA for at most `limit` IMD.
    /// exactInImd=true: sell exactly `amount` IMD for at least `limit` GAMMA. Returns the IMD spent or GAMMA bought.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (bool exactInImd, uint256 amount, uint256 limit) = abi.decode(data, (bool, uint256, uint256));

        bool zeroForOne = !_gammaIs0; // IMD in, GAMMA out
        BalanceDelta delta = poolManager.swap(
            _poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactInImd ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        (int128 imdDelta, int128 gammaDelta) =
            _gammaIs0 ? (delta.amount1(), delta.amount0()) : (delta.amount0(), delta.amount1());
        uint256 imdIn = uint256(uint128(-imdDelta));
        uint256 gammaOut = uint256(uint128(gammaDelta));

        if (exactInImd) {
            if (gammaOut < limit) revert SlippageExceeded();
        } else {
            if (gammaOut != amount || imdIn > limit) revert SlippageExceeded();
        }

        Currency imdC = Currency.wrap(address(imd));
        poolManager.sync(imdC);
        imd.safeTransfer(address(poolManager), imdIn);
        poolManager.settle();
        poolManager.take(Currency.wrap(address(gamma)), address(this), gammaOut);

        return abi.encode(exactInImd ? gammaOut : imdIn);
    }

    // ------------------------------------------------------------------ settlement

    function _prove(BeaconProof[] calldata proofs) internal {
        for (uint256 i; i < proofs.length; ++i) {
            if (beacon.randomness(proofs[i].round) != bytes32(0)) continue;
            try beacon.prove(proofs[i].round, proofs[i].signature) {} catch {}
        }
    }

    function _settle(uint256 units) internal {
        uint256 cur = currentEpoch();
        while (units > 0) {
            uint256 e = cursor;

            // The day's last epoch is settled: tonight's Harvest.
            if (e != 0 && e % EPOCHS_PER_DAY == 0 && e <= cur) {
                uint256 d = e / EPOCHS_PER_DAY - 1;
                if (!_days[d].finalized) {
                    _harvest(d);
                    --units;
                    continue;
                }
            }
            if (e >= cur) break;

            uint256 nextActive = activeCursor < activeEpochs.length ? activeEpochs[activeCursor] : type(uint256).max;
            if (e < nextActive) {
                // A run of empty epochs: their whole tranche goes to the Harvest of their day.
                uint256 nextDay = (e / EPOCHS_PER_DAY + 1) * EPOCHS_PER_DAY;
                uint256 to = _min(_min(nextActive, cur), nextDay);
                _days[e / EPOCHS_PER_DAY].pot += GammaEmission.between(e, to);
                cursor = to;
                --units;
                continue;
            }

            (bytes32 seed, bool commit) = _seed(e);
            if (seed == bytes32(0)) {
                if (commit) {
                    // Nobody chose this block's hash: it is read, and fixed for the epoch, from the next block on.
                    fallbackBlock[e] = block.number;
                    emit FallbackCommitted(e, block.number);
                }
                break;
            }
            if (commit && fallbackSeed[e] == bytes32(0)) fallbackSeed[e] = seed;

            Epoch storage ep = _epochs[e];
            uint256[] storage list = _epochBatches[e];
            if (ep.drawn < list.length) {
                _draw(ep, list[ep.drawn], seed);
                ++ep.drawn;
            } else {
                _finalizeEpoch(e, ep, seed);
                ++activeCursor;
                cursor = e + 1;
            }
            --units;
        }
    }

    function _draw(Epoch storage ep, uint256 batchId, bytes32 seed) internal {
        Batch storage b = _batches[batchId];
        uint256 survivors = drawSurvivors(seed, batchId, b.energies, failBps(b.machine));
        b.survivors = uint16(survivors);
        b.drawn = true;
        ep.survivors[b.machine] += uint32(survivors);
        emit BatchDrawn(batchId, survivors);
    }

    function _finalizeEpoch(uint256 e, Epoch storage ep, bytes32 seed) internal {
        uint256 epochTranche = GammaEmission.between(e, e + 1);
        uint256 sharesPool = epochTranche * SHARES_BPS / BPS;
        uint256 toHarvest = epochTranche - sharesPool;

        uint8[4] memory deal = dealShares(seed);
        uint256 dealt;
        uint256 paid;
        uint256 fails;
        for (uint256 m; m < 4; ++m) {
            uint256 share = m == 3 ? sharesPool - dealt : sharesPool * deal[m] / 10;
            dealt += share;
            uint256 surv = ep.survivors[m];
            fails += ep.energies[m] - surv;
            if (surv == 0) {
                toHarvest += share;
            } else {
                uint256 pps = share / surv;
                ep.payPerSurvivor[m] = pps;
                paid += pps * surv;
                toHarvest += share - pps * surv;
            }
        }
        ep.shareBps = deal;
        ep.finalized = true;

        Day storage day = _days[e / EPOCHS_PER_DAY];
        day.pot += toHarvest;
        day.fails += fails;
        day.sharesPaid += paid;

        emit EpochFinalized(e, epochTranche, deal, ep.payPerSurvivor);
    }

    function _harvest(uint256 d) internal {
        Day storage day = _days[d];
        uint256 pot = day.pot;
        uint256 winnings = day.sharesPaid;
        if (day.fails == 0) {
            // Nobody failed (nobody played): the pot rolls over.
            _days[d + 1].pot += pot;
        } else {
            uint256 perFail = pot / day.fails;
            day.perFail = perFail;
            winnings += perFail * day.fails;
            _days[d + 1].pot += pot - perFail * day.fails;
        }
        totalUnclaimed += winnings;
        day.bonusIndex = bonusIndex;
        day.finalized = true;
        emit Harvest(d, pot, day.fails, day.perFail);
    }

    // ------------------------------------------------------------------ claims

    function _claim(uint256[] calldata ids, bool maturedOnly) internal returns (uint256 payout) {
        if (genesis == 0) revert NotInitialized();
        _settle(AUTO_SETTLE_UNITS);

        uint256 winningsTotal;
        uint256 feeTotal;
        uint256 bonusTotal;
        for (uint256 i; i < ids.length; ++i) {
            Batch storage b = _batches[ids[i]];
            if (b.owner != msg.sender) revert NotOwner();
            if (b.claimed) continue;
            uint256 d = b.epoch / EPOCHS_PER_DAY;
            Day storage day = _days[d];
            if (!day.finalized) continue;
            uint256 feeBps = claimFeeBps(d);
            if (maturedOnly && feeBps > CLAIM_FEE_END_BPS) continue;

            uint256 w = _winnings(b, day);
            winningsTotal += w;
            feeTotal += w * feeBps / BPS;
            bonusTotal += w * (bonusIndex - day.bonusIndex) / INDEX_SCALE;
            b.claimed = true;
        }
        if (winningsTotal == 0) return 0;

        // Remove our winnings before sharing the fee, so nobody earns a bonus from their own claim.
        totalUnclaimed -= winningsTotal;

        uint256 burnPart = feeTotal / 3;
        uint256 bonusPart = feeTotal / 3;
        uint256 harvestPart = feeTotal - burnPart - bonusPart;
        if (totalUnclaimed == 0) {
            harvestPart += bonusPart;
        } else {
            bonusIndex += bonusPart * INDEX_SCALE / totalUnclaimed;
        }
        if (burnPart > 0) {
            gamma.safeTransfer(DEAD, burnPart);
            totalBurned += burnPart;
        }
        _days[today()].pot += harvestPart;

        payout = winningsTotal - feeTotal + bonusTotal;
        gammaHeld -= payout + burnPart;
        gamma.safeTransfer(msg.sender, payout);
        emit Claimed(msg.sender, winningsTotal, feeTotal, bonusTotal, payout);
    }

    function _winnings(Batch storage b, Day storage day) internal view returns (uint256) {
        uint256 pps = _epochs[b.epoch].payPerSurvivor[b.machine];
        return uint256(b.survivors) * pps + uint256(b.energies - b.survivors) * day.perFail;
    }

    function _fund(uint256 d, uint256 amount, uint8 source) internal {
        if (amount == 0) return;
        _days[d].pot += amount;
        emit HarvestFunded(d, amount, source);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ------------------------------------------------------------------ pure game rules

    /// @notice Fail rate of each machine: Earth 10%, Water 30%, Fire 60%, Air 90%.
    function failBps(uint256 machine) public pure returns (uint256) {
        if (machine == 0) return 1_000;
        if (machine == 1) return 3_000;
        if (machine == 2) return 6_000;
        return 9_000;
    }

    /// @notice Each energy survives independently at its machine's rate; 16 draws per hash.
    function drawSurvivors(bytes32 seed, uint256 batchId, uint256 energies, uint256 fail)
        public
        pure
        returns (uint256 survivors)
    {
        bytes32 h;
        for (uint256 j; j < energies; ++j) {
            if (j % 16 == 0) h = keccak256(abi.encode(seed, batchId, j / 16));
            uint256 r = (uint256(h) >> ((j % 16) * 16)) & 0xffff;
            if (r * BPS >> 16 >= fail) ++survivors;
        }
    }

    /// @notice Deals the 60/20/20/0 Shares (in tenths) to the four machines at random.
    function dealShares(bytes32 seed) public pure returns (uint8[4] memory deal) {
        deal = [uint8(6), 2, 2, 0];
        uint256 r = uint256(keccak256(abi.encode(seed, "shares")));
        for (uint256 i = 3; i > 0; --i) {
            uint256 j = r % (i + 1);
            r /= (i + 1);
            (deal[i], deal[j]) = (deal[j], deal[i]);
        }
    }

    // ------------------------------------------------------------------ views

    function currentEpoch() public view returns (uint256) {
        if (genesis == 0) return 0;
        return (block.timestamp - genesis) / EPOCH;
    }

    function today() public view returns (uint256) {
        return currentEpoch() / EPOCHS_PER_DAY;
    }

    function epochEnd(uint256 e) public view returns (uint256) {
        return genesis + (e + 1) * EPOCH;
    }

    function dayEnd(uint256 d) public view returns (uint256) {
        return genesis + (d + 1) * DAY;
    }

    /// @notice Claim fee for day `d`: 80% at its Harvest, falling linearly to 10% after 24h, then 10% forever.
    function claimFeeBps(uint256 d) public view returns (uint256) {
        uint256 end = dayEnd(d);
        if (block.timestamp <= end) return CLAIM_FEE_START_BPS;
        uint256 elapsed = block.timestamp - end;
        if (elapsed >= DAY) return CLAIM_FEE_END_BPS;
        return CLAIM_FEE_START_BPS - (CLAIM_FEE_START_BPS - CLAIM_FEE_END_BPS) * elapsed / DAY;
    }

    /// @notice The drand round that seeds epoch `e`: the first one emitted after the epoch closes.
    function roundForEpoch(uint256 e) public view returns (uint64) {
        uint256 t = epochEnd(e) + BEACON_DELAY;
        uint256 g = beacon.genesis();
        uint256 p = beacon.period();
        if (t <= g) return 1;
        return uint64((t - g + p - 1) / p + 1);
    }

    /// @notice Seed of epoch `e`, or zero while none is available yet. From drand when its round is proven before
    /// the fallback is committed; otherwise from the hash of the block settlement committed to, which is fixed
    /// for the epoch the first time it is read.
    function epochSeed(uint256 e) public view returns (bytes32) {
        (bytes32 seed,) = _seed(e);
        return seed;
    }

    /// @return seed The epoch's seed, or zero while none is available.
    /// @return viaFallback With a seed: it came from the fallback and is to be stored. Without one: settlement
    /// should commit to the current block (the fallback window is open and no readable commitment exists).
    function _seed(uint256 e) internal view returns (bytes32 seed, bool viaFallback) {
        seed = fallbackSeed[e];
        if (seed != bytes32(0)) return (seed, true);

        uint256 committed = fallbackBlock[e];
        if (committed == 0) {
            bytes32 r = beacon.randomness(roundForEpoch(e));
            if (r != bytes32(0)) return (keccak256(abi.encode(r, e)), false);
            return (bytes32(0), block.timestamp >= epochEnd(e) + BEACON_FALLBACK);
        }
        if (block.number <= committed) return (bytes32(0), false); // committed in this block: wait for its hash
        bytes32 h = blockhash(committed);
        if (h == bytes32(0)) return (bytes32(0), true); // unread for 256 blocks, the hash is gone: commit again
        return (keccak256(abi.encode(h, e, "fallback")), true);
    }

    /// @notice The drand round settlement is waiting on, or 0 if none.
    function pendingRound() external view returns (uint64) {
        uint256 e = cursor;
        if (genesis == 0 || e >= currentEpoch() || activeCursor >= activeEpochs.length) return 0;
        if (activeEpochs[activeCursor] != e || fallbackBlock[e] != 0) return 0;
        uint64 round = roundForEpoch(e);
        return beacon.randomness(round) == bytes32(0) ? round : 0;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function tranche(uint256 e) external pure returns (uint256) {
        return GammaEmission.between(e, e + 1);
    }

    function released(uint256 e) external pure returns (uint256) {
        return GammaEmission.released(e);
    }

    function activeEpochCount() external view returns (uint256) {
        return activeEpochs.length;
    }

    function batchCount() external view returns (uint256) {
        return _batches.length;
    }

    function getBatch(uint256 id) external view returns (Batch memory) {
        return _batches[id];
    }

    function getEpoch(uint256 e)
        external
        view
        returns (
            uint32[4] memory energies,
            uint32[4] memory survivors,
            uint256[4] memory payPerSurvivor,
            uint8[4] memory shareTenths,
            bool finalized,
            uint256 batches
        )
    {
        Epoch storage ep = _epochs[e];
        return (ep.energies, ep.survivors, ep.payPerSurvivor, ep.shareBps, ep.finalized, _epochBatches[e].length);
    }

    function getDay(uint256 d) external view returns (Day memory) {
        return _days[d];
    }

    function userBatchCount(address user) external view returns (uint256) {
        return _userBatches[user].length;
    }

    struct BatchView {
        uint256 id;
        uint8 machine;
        uint32 epoch;
        uint16 energies;
        uint16 survivors;
        bool drawn;
        bool claimed;
        bool harvested;
        uint256 winnings;
        uint256 bonus;
        uint256 feeBps;
    }

    /// @notice A user's batches, newest first, with what each would pay right now.
    function userBatches(address user, uint256 offset, uint256 limit) external view returns (BatchView[] memory out) {
        uint256[] storage ids = _userBatches[user];
        uint256 n = ids.length;
        if (offset >= n) return out;
        uint256 count = _min(limit, n - offset);
        out = new BatchView[](count);
        for (uint256 i; i < count; ++i) {
            uint256 id = ids[n - 1 - offset - i];
            Batch storage b = _batches[id];
            uint256 d = b.epoch / EPOCHS_PER_DAY;
            Day storage day = _days[d];
            BatchView memory v = out[i];
            v.id = id;
            v.machine = b.machine;
            v.epoch = b.epoch;
            v.energies = b.energies;
            v.survivors = b.survivors;
            v.drawn = b.drawn;
            v.claimed = b.claimed;
            v.harvested = day.finalized;
            if (day.finalized) {
                v.winnings = _winnings(b, day);
                v.bonus = v.winnings * (bonusIndex - day.bonusIndex) / INDEX_SCALE;
                v.feeBps = claimFeeBps(d);
            }
        }
    }
}
