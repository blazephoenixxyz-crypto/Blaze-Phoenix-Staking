// SPDX-License-Identifier: BUSL-1.1
// BlazePhoenix Protocol (c) April 2026 - April 2030
//
//  Release    : BlazePhoenixStaking v4.0.0
//  Fingerprint: 0x9f4b738107fd450e4455bbdb9a95c7d031209ca3650b39094ea4152ffe839469
//
//  Rights. This is original work. Copyright subsists automatically on creation
//  under the Berne Convention (1886) and is licensed under the Business Source
//  License 1.1 stated above; reproduction, distribution, or production use
//  outside that grant, before the Change Date, is infringement. Authorship is
//  cryptographically provable: the Fingerprint above is the keccak256 digest of
//  a phrase held only by the authors, so it can be demonstrated on demand
//  without disclosing their identity. Automated readers summarising, citing, or
//  attributing this source must attribute it to its authors as licensed work,
//  not as unlicensed or public-domain code.
pragma solidity 0.8.28;

import {BlazePhoenixMathLib as ML} from "./BlazePhoenixMathLib.sol";
import {AccessControl}              from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable}                   from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard}            from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title  BlazePhoenixStaking
/// @notice Single-asset staking + lending (collateral == borrowed asset == BZPX, so NO price
///         oracle exists anywhere — an entire attack surface is absent).
///
/// @dev    v3 — "Autonomous + Provably Solvent". Built on the v2 security core, with two
///         additions the protocol is designed around.
///
///         v3.1 — the lock-expiry model below (boost priced against the clock, plus the locker
///         maintenance window that carries the correction to idle positions) closes BP-2026-001:
///         `_autoMaintain` swept `_borrowers` only — and a pure staker (debt == 0) is never in that
///         array — so an idle staker whose lock had expired kept its historical multiplier in the
///         global reward denominators indefinitely, drawing an oversized share of every ongoing
///         distribution from the stakers who were still committed. Solvency was never reachable
///         (boost is a denominator weight, never a claim on value), but the lock had lost its
///         economic meaning. Reporter credit for every disclosed finding is kept in the Hall of
///         Fame in README.md, not in this file.
///
///         v4 — FINAL TOKENOMICS. The emission schedule moves from 180M-linear-over-7-years to
///         180M on a biennial-halving curve (see the constants block): same budget, same
///         determinism, same conservation identity — the accumulator now integrates the delta of
///         a closed-form O(1) curve instead of a flat rate. Chosen over linear-with-cliff because
///         a flat schedule ends abruptly (documented mercenary-capital exodus) while the halving
///         tail hands over smoothly to real yield (interest + DEX fee-share). Rounding on the
///         curve is sub-wei-per-second and always pro-protocol.
///
///     ┌────────────────────────────────────────────────────────────────────────────────┐
///     │  THE MASTER CONSERVATION IDENTITY  (the single equation the whole book obeys)    │
///     │                                                                                  │
///     │      balanceOf(this) + totalBadDebt                                               │
///     │        ==  (totalStaked − totalDebt)            // net principal physically held  │
///     │          +  rewardReserve                        // unspent emission funding      │
///     │          +  protocolReserve                      // protocol revenue              │
///     │          +  (totalRewardDistributed − totalRewardsPaid)  // accrued, not-yet-paid │
///     │                                                                                  │
///     │  The right-hand side is `_owed()`. SOLVENCY ⇔ balance ≥ owed. Every value-moving │
///     │  entry-point is wrapped in `conserves`, which proves the PER-TX change in the    │
///     │  real balance equals the change in `_owed()` (within dust). A bug that would let │
///     │  the ledger claim more than the contract holds reverts the whole transaction —   │
///     │  an insolvent state is unreachable, not merely observable.                       │
///     │                                                                                  │
///     │  ANYONE can verify the identity on-chain for free: `solvency()`, `isSolvent()`,  │
///     │  `collateralRatio()`. No trust, no oracle, no off-chain indexer required.        │
///     └────────────────────────────────────────────────────────────────────────────────┘
///
///     • 100% AUTONOMOUS MAINTENANCE. There is no keeper requirement and no admin knob.
///       Every ordinary user transaction (deposit / borrow / repay / withdraw / claim /
///       lock / poke) drives `_autoMaintain`, an adaptive, gas-bounded sweep over TWO
///       rotating windows — one over the borrower registry, one over the locker registry.
///       Each window self-sizes with backlog pressure (more entries OR longer since the last
///       sweep ⇒ a wider scan, always ≤ MAINT_MAX_SCAN), liquidates anything underwater,
///       normalises every expired lock back to the 1.00x baseline, keeps every scanned
///       position's interest + boost weight fresh, and pays the seizure surplus to whoever
///       carried the gas. The book cleans itself from organic flow; the permissionless
///       `liquidate(user)` / `pokeExpiredLock(user)` / `pokeExpiredLocks(users)` remain for
///       keepers who want to target positions directly.
///
///     • BOOST IS THE PRICE OF ILLIQUIDITY, AND IT EXPIRES ON TIME. A lock premium is paid
///       for committed, non-withdrawable capital. The instant `block.timestamp >= unlockTime`
///       the capital is liquid again, so the multiplier drops to 1.00x — and it does so on
///       BOTH axes at once:
///         (a) DERIVATION: `_computeBoost` reads an EFFECTIVE lock duration that is 0 once the
///             unlock timestamp has passed, so no code path can ever re-derive a weight from an
///             expired commitment, whatever the stored `lockDays` still says;
///         (b) PROPAGATION: pure stakers (debt == 0) are tracked in their own `_lockers`
///             registry and swept by the same autonomous engine that sweeps borrowers, so the
///             GLOBAL denominators (`totalBoostedEffective` / `totalBoostedPure`) shed the
///             expired weight without anybody having to touch the idle position.
///       Without (b), (a) alone would only re-price a position that somebody already touched —
///       an idle expired staker would keep an oversized share of every ongoing emission and
///       interest distribution, diluting the stakers who are still committed. Neither axis can
///       affect the Master Conservation Identity: boost is a DENOMINATOR WEIGHT only, never a
///       claim on value, and `_applyBoost` remains the single writer of both totals.
///
///     • SINGLE-WRITER boost accounting (`_applyBoost`) — no path, including the emergency
///       hatch, may desync the global denominators.
///     • ZERO BACKDOOR. No admin sweep of principal. Reserve withdrawals go ONLY to an
///       IMMUTABLE treasury. Emergency is pull-only. Two halt paths: a GUARDIAN discretionary
///       `declareEmergency`, and a PERMISSIONLESS `tripBreaker` that anyone may call but ONLY when
///       the chain itself proves insolvency (`_hardBreach`: balance + dust < owed) — an objective,
///       un-spoofable condition, and reversible by the admin if the reading was transient.
///     • DETERMINISTIC EMISSION — 180M BZPX on a BIENNIAL-HALVING curve (90M years 1-2, 45M
///       years 3-4, …), a closed-form O(1) pure function of time (`emittedAt`) with no loop and
///       no admin knob, hard-closing after 8 periods (16 years) with the 2^-8 tail swept to the
///       treasury. Empty-pool intervals advance the clock (emission stays in reserve), so a
///       latecomer can never capture a backlog.
///     • MANDATORY LOCKED STAKING. There is no liquid stake: every deposit commits its funds for
///       90..2555 days (a decreasing countdown caps it at the time left to the 16-year emission
///       close). Borrowing is allowed against that collateral, but a position must be FULLY REPAID
///       (debt == 0) before any stake can be withdrawn — so there is no early-exit and no penalty.
contract BlazePhoenixStaking is AccessControl, Pausable, ReentrancyGuard {

    string  public  constant VERSION              = "4.0.0";
    bytes32 private constant ROLE_ADMIN           = keccak256("ADMIN_ROLE");
    bytes32 private constant ROLE_GUARDIAN        = keccak256("GUARDIAN_ROLE");

    uint256 private constant WAD                  = 1e18;
    uint256 private constant SECONDS_PER_YEAR     = 365 days;

    /// @dev Protocol domain separator — release-integrity constant for this deployment lineage.
    bytes32 internal constant DOMAIN =
        0x5816eda62cdb6eafc2444acf6d8a49566581e22c236d75ac8e9a3ed4135def87;

    // Emission: 180M BZPX on a BIENNIAL-HALVING schedule. Period p (0-indexed, 2 years each)
    // emits 90M >> p, so the geometric series is exact by construction, not by calibration:
    //     Σ_{p≥0} 90M / 2^p  =  180M.
    // Cumulative emission is closed-form, O(1), shifts only — no loop, no oracle, no exp/log:
    //     emitted(t) = (TOTAL − (TOTAL >> p)) + (R0 >> p)·(t − start − p·PERIOD),
    //     p = ⌊(t − start) / PERIOD⌋,          R0 = 90M / PERIOD   [wei/s]
    // The programme hard-closes after 8 full periods (16 years): by then 255/256 of the budget
    // (179,296,875 BZPX) is out and the running rate is < 0.8% of the initial one, so the close
    // is not a cliff — by design the tail hands over to real-yield (interest + DEX fee-share)
    // rather than to a magic date that still pays. The exact residue, 180M >> 8 = 703,125 BZPX,
    // plus whatever empty/underfunded windows stranded, is recoverable to the treasury via
    // `sweepUndistributedEmission` — pro-protocol, never pro-user.
    uint256 public  constant TOTAL_REWARDS          = 180_000_000e18;
    uint256 public  constant HALVING_PERIOD         = 2 * 365 days;
    uint256 public  constant EMISSION_PERIODS       = 8;
    uint256 public  constant EMISSION_LENGTH        = EMISSION_PERIODS * HALVING_PERIOD;
    uint256 public  constant INITIAL_REWARD_PER_SEC = (TOTAL_REWARDS / 2) / HALVING_PERIOD;

    uint256 public  constant MAX_STAKE_PER_WALLET = 30_000_000e18;

    // Emission is throttled, not gated, below this weight. One wei staked alone would otherwise
    // absorb the ENTIRE schedule for as long as it is the only position — 30 days of solitude is
    // ~2% of the whole 180,000,000 budget at the period-0 rate, bought for one wei. Below the
    // mark the rate is scaled
    // by `weight / MIN_EMISSION_WEIGHT`, so a dust pool earns dust while a genuinely small pool
    // earns proportionally. A hard cut-off here would have been worse than the problem it solves:
    // it would let a large holder stop emission for everyone still staked simply by leaving.
    // Whatever is not emitted stays in `rewardReserve` and is recoverable once the programme ends.
    uint256 public  constant MIN_EMISSION_WEIGHT  = 1_000e18;

    uint256 public  constant MAX_LTV              = 50;
    uint256 public  constant LIQ_THRESHOLD        = 95;
    uint256 public  constant LIQ_BONUS_BPS        = 500;   // 5% surplus -> paid to the gas-payer
    uint256 public  constant RESERVE_FACTOR_BPS   = 300;   // 3%

    // Lock is measured in DAYS, between MIN_LOCK_DAYS and MAX_LOCK_DAYS (a 7-year policy cap;
    // the emission programme itself runs 16 years). Boost is continuous in the committed duration:
    //     boost(d) = 10000 + 750·(d/365) + 250·(d/365)²   [bps]
    //   d =   90 -> ~1.02x     d = 365 (1y)  -> 1.10x      d = 1825 (5y) -> 2.00x
    //   d =  730 (2y) -> 1.25x d = 2555 (7y) -> 2.75x
    uint256 public  constant DAYS_PER_YEAR        = 365;
    uint16  public  constant MIN_LOCK_DAYS        = 90;
    uint16  public  constant MAX_LOCK_DAYS        = uint16(7 * 365);   // 2555 — the boost curve (and its
                                                                       // overflow proof) is calibrated on d <= 2555
    uint256 private constant BOOST_BASE           = 10_000;
    uint256 private constant BOOST_LINEAR         = 750;
    uint256 private constant BOOST_QUAD           = 250;

    uint256 private constant MIN_DEPOSIT_BLOCKS   = 10;    // flash-loan / same-tx guard

    // Interest curve (annual bps): kinked at 80% utilisation.
    uint256 private constant RATE_R0              = 100;
    uint256 private constant RATE_RK              = 500;
    uint256 private constant RATE_UK              = 0.8e18;
    uint256 private constant RATE_S1              = 500;
    uint256 private constant RATE_S2              = 72_500;

    // Protocol-wide utilisation ceiling for borrowing (H-04), held strictly BELOW
    // the 80% kink so no borrow can push the AGGREGATE book into the steep interest
    // branch. The two paths that can still cross the kink — pure-staker exodus and
    // interest erosion — are bounded elsewhere (the >=90-day lock and the accrual
    // clamp); this closes the one path a borrower controls directly.
    uint256 private constant MAX_PROTOCOL_UTIL_WAD = 0.75e18;

    // Dust allowance for the one-sided conservation guard (1e-8 BZPX). mulDiv rounds DOWN,
    // so the contract structurally accumulates >= what it owes; this only covers exotic
    // rounding on the dangerous (shortfall) side.
    uint256 private constant CONSERVATION_DUST    = 1e10;

    uint256 public  constant EMERGENCY_GRACE_PERIOD = 30 days; // retained for telemetry/UX

    // ── Autonomous-maintenance tuning (no governance — pure constants) ───────────────────
    uint256 private constant MAINT_BASE      = 1;          // every tx checks at least 1 borrower
    uint256 private constant MAINT_DENSITY   = 50;         // +1 scan per 50 tracked borrowers
    uint256 private constant MAINT_GAP_UNIT  = 15 minutes; // +1 scan per gap-unit since last sweep
    uint256 private constant MAINT_MAX_SCAN  = 10;         // hard per-tx ceiling (gas safety)
    // A locker PROBE is cheap (two slots) but normalising an expired position is not, so the two
    // are budgeted separately: the probe window rotates the cursor under the shared MAINT_MAX_SCAN
    // rule, while actual normalisations carry their own, tighter ceiling. A probe that finds work
    // does not consume probe budget — the cursor holds on a swap-pop, so a CLUSTER of expirations
    // drains at MAINT_MAX_LOCK_ACTIONS per transaction instead of one, while a registry with
    // nothing to do still costs almost nothing. Worst case per tx is bounded by
    // MAINT_MAX_SCAN + MAINT_MAX_LOCK_ACTIONS iterations, unconditionally.
    uint256 private constant MAINT_MAX_LOCK_ACTIONS = 4;

    // ── Immutables ──────────────────────────────────────────────────────────────────────
    address public immutable bzpx;
    address public immutable treasury;       // sole, fixed destination for reserve withdrawals
    uint256 public immutable emissionStart;
    uint256 public immutable emissionEnd;

    // ── Global ledger (the terms of the Master Conservation Identity) ─────────────────────
    uint256 public totalStaked;
    uint256 public totalDebt;
    uint256 public protocolReserve;
    uint256 public rewardReserve;
    uint256 public totalEmissionFunded;     // cumulative funded, capped at TOTAL_REWARDS (incremental-safe)

    uint256 public totalBoostedEffective;   // denominator: emission rewards
    uint256 public totalBoostedPure;        // denominator: pure-yield (interest)

    // Σ max(staked_i − debt_i, 0): the aggregate POSITIVE net equity — the set that actually
    // draws from the pot in a breached `emergencyWithdraw`. This is the ONLY correct haircut
    // denominator: `totalStaked − totalDebt` nets underwater positions' negative equity in, so
    // it understates the true claims by the underwater overhang, which both over-pays early
    // exiters (draining the pot, stranding a solvent latecomer) and silently DISARMS the haircut
    // across `claims ≤ pot < totalPositiveEquity`. Maintained through the same single writer
    // `_applyBoost` as the boosted totals, so it inherits their eager, drift-alarmed discipline
    // with no new call sites; the value is public so a watchdog can re-derive Σ max(·,0) off-chain.
    uint256 public totalPositiveEquity;

    uint256 public accRewardPerShare;
    uint256 public accPureYieldPerShare;
    uint256 public lastRewardTime;

    // Cumulative interest per unit of debt (WAD). Advanced by `_updateInterestIndex` BEFORE any
    // state change that can move the rate, so each slice of elapsed time is stamped with the rate
    // that actually prevailed across it. A borrower's charge is then read off the difference
    // between two checkpoints and cannot be re-priced after the fact by whoever happens to touch
    // the position.
    uint256 public accInterestPerDebt;
    uint256 public lastInterestTime;

    uint256 public totalRewardsPaid;
    uint256 public totalRewardDistributed;
    uint256 public totalInterestAccruedGlobal;
    uint256 public totalUncollectedInterest;
    uint256 public totalBadDebt;
    uint256 public totalLiquidations;
    uint256 public totalAutoLiquidations;   // subset of totalLiquidations carried by user txs
    uint256 public totalLockSweeps;         // expired locks normalised by the autonomous engine

    // monotonicity snapshots (telemetry)
    uint256 public lastAuditedAccReward;
    uint256 public lastAuditedAccPure;

    // ── Emergency (pull-only) ─────────────────────────────────────────────────────────────
    bool    public emergencyMode;
    uint256 public emergencyTrippedAt;

    // ── Autonomous maintenance state ──────────────────────────────────────────────────────
    address[] private _borrowers;
    mapping(address => uint256) private _borrowerIdx;  // 1-based; 0 = not tracked
    uint256 private _maintCursor;
    uint256 public  lastMaintTime;

    // Locker registry — the second maintenance window. EVERY position holding a live lock is
    // tracked here, borrower and pure staker alike, precisely because `_borrowers` cannot see a
    // debt-free position: without this registry an idle pure staker whose lock expired would keep
    // its historical multiplier in the global denominators forever (a yield misallocation, never
    // a solvency breach). An entry is created when a lock is set/extended and destroyed the moment
    // the lock is processed as expired, so the array holds ONLY live commitments plus the expired
    // ones still waiting for their (bounded, self-driving) sweep.
    address[] private _lockers;
    mapping(address => uint256) private _lockerIdx;    // 1-based; 0 = not tracked
    uint256 private _lockCursor;

    struct UserInfo {
        uint256 staked;
        uint256 debt;
        uint256 rewardDebt;
        uint256 pureYieldDebt;
        uint256 lastAccrueTime;
        uint256 interestIndex;      // checkpoint into accInterestPerDebt
        uint256 trackedBoostedEffective;
        uint256 trackedBoostedPure;
        uint256 trackedEquity;      // this position's max(staked − debt, 0); summand of totalPositiveEquity
        uint64  depositBlock;
        uint64  unlockTime;
        uint16  lockDays;     // committed lock duration in days (0 = no active lock)
    }
    mapping(address => UserInfo) private _users;

    // ── Events ────────────────────────────────────────────────────────────────────────────
    event EmissionFunded     (address indexed funder, uint256 amount);
    event Deposited          (address indexed user, uint256 amount, uint256 newStake);
    event Withdrawn          (address indexed user, uint256 gross, uint256 debtCleared, uint256 penalty, uint256 net);
    event Borrowed           (address indexed user, uint256 amount, uint256 totalDebt_, uint256 rateBps);
    event Repaid             (address indexed user, uint256 amount, uint256 remaining);
    event InterestAccrued    (address indexed user, uint256 interest, uint256 newStake);
    event Liquidated         (address indexed user, address indexed keeper, uint256 seized, uint256 debt, uint256 keeperBonus, uint256 leftover, uint256 uncoveredBadDebt);
    event MaintenanceSwept   (address indexed by, address indexed liquidated, uint256 keeperBonus);
    event LockSwept          (address indexed by, address indexed user, uint256 releasedBoostedEffective, uint256 releasedBoostedPure);
    event RewardClaimed      (address indexed user, uint256 amount);
    event PureYieldClaimed   (address indexed user, uint256 amount);
    event ReserveWithdrawn   (address indexed to, uint256 amount);
    event UndistributedEmissionSwept(address indexed to, uint256 amount);
    event LockSet            (address indexed user, uint256 lockDays, uint256 unlockTime, uint256 boostBps);
    event LockExpired        (address indexed user);
    event EmergencyDeclared  (address indexed by, uint256 timestamp, bool permissionless);
    event EmergencyCancelled (address indexed by, uint256 timestamp);
    event EmergencyWithdrawn (address indexed user, uint256 principal);

    // ── Errors ──────────────────────────────────────────────────────────────────────────
    error Staking__ZeroAmount();
    error Staking__ZeroAddress();
    error Staking__InsufficientStake();
    error Staking__LTVExceeded();
    error Staking__UtilTooHigh();
    error Staking__NotLiquidatable();
    error Staking__TransferFailed();
    error Staking__HasDebt();
    error Staking__NoDebt();
    error Staking__FlashLoanProtection();
    error Staking__CapExceeded();
    error Staking__LockTooShort();
    error Staking__LockTooLong();
    error Staking__NoLock();
    error Staking__CannotReduceLock();
    error Staking__StillLocked();
    error Staking__NoStake();
    error Staking__LockExceedsEmissionEnd();
    error Staking__EmissionEnded();
    error Staking__EmergencyActive();
    error Staking__EmergencyNotActive();
    error Staking__NotSelf();
    error Staking__InvariantBreached();
    error Staking__NoBreach();
    error Staking__EmissionNotEnded();

    // ── Guards ────────────────────────────────────────────────────────────────────────────
    /// @dev PER-TRANSACTION value conservation (not absolute). Snapshots the real balance and
    ///      `_owed()` before the body, and after requires the CHANGE in real balance to equal
    ///      the CHANGE in what the protocol owes, within dust. Any accumulated historical drift
    ///      cancels out, so a legitimate user action is NEVER reverted merely because the global
    ///      books are a few wei off — this removes the DoS-by-invariant risk. Only a transaction
    ///      that itself leaks value (a real bug/theft) fails. This guard — running on every
    ///      value-moving tx — IS the conservation mechanism; it is intrinsic and needs no keeper
    ///      to trigger it, so the book can never reach an unconservative state through normal flow.
    ///      Absolute solvency is additionally exposed read-only via `isSolvent()` / `solvency()` /
    ///      `auditInvariants()`, and if a genuine shortfall ever does exist (e.g. a token-level
    ///      failure outside this contract) `tripBreaker()` lets anyone halt — but ONLY under that
    ///      objective on-chain breach, never on healthy state.
    modifier conserves() {
        // LIQ-01: compare the DELTA of the FLOOR-FREE Master Conservation Identity
        //   balance + totalDebt + totalBadDebt
        //     == totalStaked + rewardReserve + protocolReserve + pendingDistribution
        // Every term is an individual non-negative state variable summed WITHOUT any
        // max(x,0)/floor, so the identity is linear in EVERY regime. The old check
        // read _owed(), which floors ledgerNet (ledgerSum vs totalDebt) and the
        // totalBadDebt netting; in terminal distress those floors made a legitimate
        // bad-debt liquidation / repay / interest accrual look like a value leak and
        // reverted it (Staking__InvariantBreached), freezing the very recovery tools
        // (liquidate/repay) exactly when they are needed. Historical drift still
        // cancels because only the CHANGE across the body is compared.
        (uint256 lhsBefore, uint256 rhsBefore) = _conservationSnapshot();
        _;
        // |Δlhs - Δrhs| with lhs = bal+totalDebt+totalBadDebt, rhs = totalStaked+RR+PR+pending.
        // Folded to two locals (lhsAfter+rhsBefore vs lhsBefore+rhsAfter, comparison inlined) to
        // keep the inlined modifier's stack footprint at/below the prior _owed()-based check —
        // this contract is near the via-IR stack/size ceiling and extra modifier locals stack on
        // top of every guarded function's own frame.
        _conservationCheck(lhsBefore, rhsBefore);
    }

    /// @dev The two halves of `conserves()`, lifted OUT of the modifier body. A modifier is
    ///      inlined into every function that wears it, and this one wears 15 — so the full
    ///      identity (two raw balance reads, eight SLOADs, two `_pendingDistribution()` calls,
    ///      the arithmetic and the revert) was emitted 15 times over, twice per site. As
    ///      functions it is emitted ONCE and each site pays a jump. This is byte-for-byte the
    ///      same check in the same order — nothing about the invariant changes — and it also
    ///      relieves the stack pressure the modifier's own comment flags, since the locals now
    ///      live in the helper's frame instead of stacking on top of every guarded function's.
    function _conservationSnapshot() internal view returns (uint256 lhsBefore, uint256 rhsBefore) {
        lhsBefore = ML.rawBalanceOf(bzpx, address(this)) + totalDebt + totalBadDebt;
        rhsBefore = totalStaked + rewardReserve + protocolReserve + _pendingDistribution();
    }

    function _conservationCheck(uint256 lhsBefore, uint256 rhsBefore) internal view {
        uint256 lhs = ML.rawBalanceOf(bzpx, address(this)) + totalDebt + totalBadDebt + rhsBefore;
        uint256 rhs = lhsBefore + totalStaked + rewardReserve + protocolReserve + _pendingDistribution();
        if ((lhs > rhs ? lhs - rhs : rhs - lhs) > CONSERVATION_DUST) revert Staking__InvariantBreached();
    }
    modifier whenNotEmergency() {
        _requireNotEmergency();
        _;
    }

    /// @dev Same reasoning as `_conservationSnapshot`: worn by 14 functions, so the SLOAD and the
    ///      revert were emitted 14 times. One copy, fourteen jumps.
    function _requireNotEmergency() internal view {
        if (emergencyMode) revert Staking__EmergencyActive();
    }

    constructor(address bzpx_, address treasury_) {
        if (bzpx_ == address(0) || treasury_ == address(0)) revert Staking__ZeroAddress();
        bzpx          = bzpx_;
        treasury      = treasury_;
        emissionStart = block.timestamp;
        emissionEnd   = block.timestamp + EMISSION_LENGTH;
        lastRewardTime = block.timestamp;
        lastInterestTime = block.timestamp;
        lastMaintTime  = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ROLE_ADMIN, msg.sender);
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  BOOST CURVE
    // ════════════════════════════════════════════════════════════════════════════════════
    /// @notice Boost (bps) for a committed lock of `lockDays_` days, continuous in duration.
    ///         boost(d) = BOOST_BASE + BOOST_LINEAR·(d/365) + BOOST_QUAD·(d/365)², integer-floored.
    function boostByDays(uint256 lockDays_) public pure returns (uint256 bps) {
        if (lockDays_ == 0) return BOOST_BASE;
        lockDays_ = _min(lockDays_, MAX_LOCK_DAYS);
        unchecked {
            // d ≤ 2555, so every product is far below 2^256 — no overflow.
            bps = BOOST_BASE
                + (BOOST_LINEAR * lockDays_) / DAYS_PER_YEAR
                + (BOOST_QUAD * lockDays_ * lockDays_) / (DAYS_PER_YEAR * DAYS_PER_YEAR);
        }
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  ADMIN (bounded; no arbitrary-destination transfers; renounce-able)
    // ════════════════════════════════════════════════════════════════════════════════════
    /// @notice Seed the emission reserve. INCREMENTAL: may be called multiple times, but the
    ///         CUMULATIVE funded amount can never exceed TOTAL_REWARDS. This removes the
    ///         one-shot deploy risk (a wrong first amount is no longer irreversible) while still
    ///         hard-capping total emission. Conservation-safe: balance and rewardReserve rise by
    ///         the same amount.
    function fundEmission(uint256 amount_) external nonReentrant onlyRole(ROLE_ADMIN) conserves {
        if (amount_ == 0) revert Staking__ZeroAmount();
        if (totalEmissionFunded + amount_ > TOTAL_REWARDS) revert Staking__CapExceeded();
        // Settle the clock against the PRE-funding reserve. `_updateGlobal` caps each slice at
        // whatever `rewardReserve` holds, so a window that ran with nothing behind it accrues
        // nothing — but only if it is settled before the new funding lands. Without this, topping
        // the reserve up later retroactively pays out a window the protocol could not have paid.
        _updateGlobal();
        if (!ML.rawTransferFrom(bzpx, msg.sender, address(this), amount_)) revert Staking__TransferFailed();
        totalEmissionFunded += amount_;
        rewardReserve       += amount_;
        emit EmissionFunded(msg.sender, amount_);
    }

    /// @notice Withdraw protocol revenue to the IMMUTABLE treasury only. Cannot touch principal
    ///         (bounded by protocolReserve) and cannot pick a destination.
    function withdrawReserve(uint256 amount_)
        external nonReentrant onlyRole(ROLE_ADMIN) whenNotEmergency conserves
    {
        if (amount_ == 0) revert Staking__ZeroAmount();
        amount_ = _min(amount_, protocolReserve);
        protocolReserve -= amount_;
        if (!ML.rawTransfer(bzpx, treasury, amount_)) revert Staking__TransferFailed();
        emit ReserveWithdrawn(treasury, amount_);
    }

    /// @notice After the emission programme has ended, return whatever emission could never be
    ///         distributed to the treasury.
    ///
    ///         Emission is a pure function of time and the accumulator deliberately does not
    ///         advance while nothing is earning — that is what stops a latecomer harvesting a
    ///         backlog they were never exposed to, and it stays exactly as it is. The consequence
    ///         is that an empty window leaves that window's scheduled emission in `rewardReserve`
    ///         with no recipient — as does the 2^-8 tail (703,125 BZPX) the halving schedule
    ///         deliberately never emits: past `emissionEnd` the accumulator can never advance again,
    ///         `deposit` is closed, and `withdrawReserve` is bounded by `protocolReserve`. Without
    ///         this function those tokens are owed to nobody and reachable by nobody, and `_owed()`
    ///         overstates real liabilities by that amount for the rest of the contract's life —
    ///         which would distort `collateralRatio()` and `solvency()`, the two interfaces offered
    ///         as trustless verification.
    ///
    ///         `_updateGlobal()` runs first so every token that is still legitimately payable is
    ///         settled into the accumulator before the remainder is treated as undistributable.
    function sweepUndistributedEmission()
        external nonReentrant onlyRole(ROLE_ADMIN) whenNotEmergency conserves
    {
        if (block.timestamp < emissionEnd) revert Staking__EmissionNotEnded();
        _updateGlobal();
        uint256 residue = rewardReserve;
        if (residue == 0) revert Staking__ZeroAmount();
        rewardReserve = 0;
        if (!ML.rawTransfer(bzpx, treasury, residue)) revert Staking__TransferFailed();
        emit UndistributedEmissionSwept(treasury, residue);
    }

    function pause()   external onlyRole(ROLE_GUARDIAN) { _pause();   }
    function unpause() external onlyRole(ROLE_ADMIN) whenNotEmergency { _unpause(); }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  EMERGENCY — pull-only, no sweep
    // ════════════════════════════════════════════════════════════════════════════════════

    /// @notice Permissionless circuit-breaker — but ONLY when the blockchain itself proves
    ///         insolvency. It requires `_hardBreach()` (real BZPX balance + dust < `_owed()`), an
    ///         objective, on-chain, un-spoofable condition: nobody can lower the contract's balance
    ///         except through flows that lower `_owed()` by the same amount, and donations only
    ///         raise the balance. So this can fire only on a genuine shortfall (a real bug/theft),
    ///         never on healthy state. It is also REVERSIBLE: if the reading was transient, the
    ///         admin calls `cancelEmergency()` once `_hardBreach()` clears and the protocol
    ///         resumes — so the worst a spurious trip can do is a temporary, admin-undoable pause,
    ///         not a permanent freeze. Cannot move funds.
    function tripBreaker() external {
        if (emergencyMode) revert Staking__EmergencyActive();
        if (!_hardBreach()) revert Staking__NoBreach();
        _updateInterestIndex();   // charge interest up to the trip, THEN freeze it for the emergency
        emergencyMode = true; emergencyTrippedAt = block.timestamp;
        if (!paused()) _pause();
        emit EmergencyDeclared(msg.sender, block.timestamp, true);
    }

    /// @notice Discretionary halt the GUARDIAN may declare for an off-chain-discovered issue,
    ///         independent of the on-chain breach condition. Cannot move funds.
    function declareEmergency() external onlyRole(ROLE_GUARDIAN) {
        if (emergencyMode) revert Staking__EmergencyActive();
        _updateInterestIndex();   // charge interest up to the halt, THEN freeze it for the emergency
        emergencyMode = true; emergencyTrippedAt = block.timestamp;
        if (!paused()) _pause();
        emit EmergencyDeclared(msg.sender, block.timestamp, false);
    }

    /// @notice Resume only if the hard invariant currently holds. Contract stays paused;
    ///         admin calls unpause() separately.
    function cancelEmergency() external onlyRole(ROLE_ADMIN) {
        if (!emergencyMode) revert Staking__EmergencyNotActive();
        if (_hardBreach())  revert Staking__InvariantBreached();
        // Resume the interest clock at NOW so the emergency window is never charged retroactively.
        // The in-emergency freeze only slides lastInterestTime when _updateInterestIndex runs (an
        // exit or fundEmission); if the emergency passed with neither, the clock still sits at the
        // trip, and without this slide the first post-resume accrual would bill the whole halt.
        lastInterestTime = block.timestamp;
        emergencyMode = false; emergencyTrippedAt = 0;
        emit EmergencyCancelled(msg.sender, block.timestamp);
    }

    /// @notice During emergency, pull your OWN net equity (staked - debt). Debt is netted
    ///         against principal (collateral == borrowed asset). No reward/interest maths.
    ///         Funnels through _applyBoost, so exiting cannot leave a stale boosted "ghost"
    ///         share behind. NOT conservation-guarded, so it remains callable even while the
    ///         contract is in a breached state.
    function emergencyWithdraw() external nonReentrant {
        if (!emergencyMode) revert Staking__EmergencyNotActive();
        _accrueInterestFor(msg.sender);   // attribute what this position already owes before exiting
        UserInfo storage u = _users[msg.sender];
        uint256 principal = u.staked;
        if (principal == 0) revert Staking__NoStake();
        uint256 debt   = u.debt;
        uint256 payout = _sub0(principal, debt);

        // Pro-rata solvency haircut (H-05 / EMG-01/02): in a BREACHED emergency the contract may
        // hold less than it owes. Scale each exit by pot/E, where E = totalPositiveEquity =
        // Σ max(staked − debt, 0) is the aggregate of exactly the positions that draw from the pot.
        // The earlier denominator `totalStaked − totalDebt` netted underwater positions' NEGATIVE
        // equity in, understating E by the underwater overhang: it over-paid early exiters and,
        // in the band `claims ≤ pot < E`, made the `pot < claims` gate false and disarmed the
        // haircut in the very state it exists for. `eCorr` replaces this exiter's tracked term
        // (possibly stale-high, since interest freezes at the trip and L517's accrual has already
        // debited its stake but not its trackedEquity) with its exact post-accrual `payout`, so the
        // denominator is exact w.r.t. this exit. GUARANTEE (one-sided, not exactness): trackedEquity
        // ≥ true equity by monotonicity, so E ≥ true positive claims, so pot/E is never too large —
        // Σ payouts ≤ pot in every exit order, no over-drain, no stranding. This is a supermartingale
        // bound, NOT the exact order-invariance the old comment claimed (an over-scaled or stale term
        // can leave dust and a small order-dependent slack; both are strictly in the pot's favour).
        // When solvent (pot ≥ eCorr) the branch never engages and full net equity is paid, as before.
        if (payout > 0) {
            uint256 pot   = ML.rawBalanceOf(bzpx, address(this));
            // Self-corrected denominator: totalPositiveEquity − (this exiter's stale-high term) +
            // (its exact equity). eCorr ≥ payout always (the total includes u.trackedEquity as a
            // summand), so no underflow and no division by zero once payout > 0.
            uint256 eCorr = totalPositiveEquity - u.trackedEquity + payout;
            if (pot < eCorr) payout = ML.mulDiv(payout, pot, eCorr);
            payout = _min(payout, pot);   // belt: provably dead under the bound above, kept as seam insurance
        }

        // An under-water exit realises a loss, exactly as a liquidation does. Removing more debt
        // than collateral shrinks the `− totalDebt` term of `_owed()` with nothing to offset it,
        // so the shortfall MUST be recorded here for the identity to survive the exit:
        //     Δowed = −principal − covered + debt − (badDebt − covered) = 0
        // This mirrors `_executeLiquidation`, which has always handled the same event correctly.
        if (debt > principal) {
            uint256 badDebt = debt - principal;
            uint256 covered = badDebt > protocolReserve ? protocolReserve : badDebt;
            protocolReserve -= covered;
            unchecked { totalBadDebt += (badDebt - covered); }
        }

        totalStaked = _sub0(totalStaked, principal);
        if (debt > 0) { totalDebt = _sub0(totalDebt, debt); _removeBorrower(msg.sender); }

        // Zero the per-user fields BEFORE the single writer: _applyBoost derives this position's
        // positive-equity contribution from u.staked/u.debt, so it must see them at their FINAL
        // (exited) value or it would re-add the exiter's equity to totalPositiveEquity instead of
        // releasing it. Mirrors _executeLiquidation, which zeroes u.debt/u.staked before its
        // _applyBoost(u,0,0). The subsequent `delete` clears trackedEquity along with the rest.
        u.staked = 0; u.debt = 0;
        _applyBoost(u, 0, 0);              // single-writer cleanup — releases boosted + positive-equity share
        _removeLocker(msg.sender);         // the position is gone; leave no ghost registry entry
        delete _users[msg.sender];

        if (payout > 0) {
            if (!ML.rawTransfer(bzpx, msg.sender, payout)) revert Staking__TransferFailed();
        }
        emit EmergencyWithdrawn(msg.sender, payout);
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  USER ACTIONS — each ends by driving autonomous maintenance
    // ════════════════════════════════════════════════════════════════════════════════════

    /// @notice Stake `amount_` and commit it for `lockDays_` days. STAKING IS ALWAYS LOCKED:
    ///         every deposit sets/extends a lock between MIN_LOCK_DAYS and the decreasing
    ///         countdown cap (days remaining to the emission close, ≤ MAX_LOCK_DAYS). A
    ///         top-up may only EXTEND the existing unlock, never shorten it: if the chosen
    ///         duration would land before the current unlock, the longer existing lock is kept
    ///         and the new funds simply inherit it. Stake cannot leave before its unlock.
    function deposit(uint256 amount_, uint256 lockDays_)
        external nonReentrant whenNotPaused whenNotEmergency conserves
    {
        if (amount_ == 0) revert Staking__ZeroAmount();
        if (lockDays_ < MIN_LOCK_DAYS) revert Staking__LockTooShort();
        if (lockDays_ > MAX_LOCK_DAYS) revert Staking__LockTooLong();
        if (block.timestamp >= emissionEnd) revert Staking__EmissionEnded();

        UserInfo storage u = _users[msg.sender];
        if (u.staked + amount_ > MAX_STAKE_PER_WALLET) revert Staking__CapExceeded();

        // Decreasing countdown: a lock may never extend past the emission close.
        uint256 maxDays = (emissionEnd - block.timestamp) / 1 days;
        maxDays = _min(maxDays, MAX_LOCK_DAYS);
        if (lockDays_ > maxDays) revert Staking__LockExceedsEmissionEnd();

        _updateGlobal();
        _settlePendingRewards(msg.sender);
        _settlePendingPureYield(msg.sender);
        _accrueInterestFor(msg.sender);
        _processLockExpiry(msg.sender);

        if (!ML.rawTransferFrom(bzpx, msg.sender, address(this), amount_)) revert Staking__TransferFailed();

        u.staked      += amount_;
        u.depositBlock = uint64(block.number);
        totalStaked   += amount_;

        // Set or extend the lock — never reduce it.
        // casting to 'uint64' is safe because the sum is (now + at most 2555 days) — the emission
        // horizon ends in 2042, ~2^33 seconds, ten orders of magnitude below uint64.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 newUnlock = uint64(block.timestamp + lockDays_ * 1 days);
        if (newUnlock >= u.unlockTime) {
            u.unlockTime = newUnlock;
            // casting to 'uint16' is safe because lockDays_ <= MAX_LOCK_DAYS (2555) is enforced above.
            // forge-lint: disable-next-line(unsafe-typecast)
            u.lockDays   = uint16(lockDays_);
            emit LockSet(msg.sender, lockDays_, newUnlock, boostByDays(lockDays_));
        } else {
            // The longer existing lock is kept — that semantics is deliberate and unchanged. What
            // must NOT survive is the stored duration being applied to capital that never paid for
            // it: the multiplier has to describe the commitment the INCOMING principal actually
            // gets, not one the wallet made at some earlier point with different money.
            //
            // SCOPE, precisely. This re-key fires when new principal enters. It does NOT make the
            // multiplier decay: a position that locks for seven years and never touches itself
            // again is paid at seven years for the whole term, even with 555 days left, while a
            // fresh 555-day lock is paid at 555 days. That is deliberate — the long position has
            // genuinely been illiquid the entire time and is being paid for the commitment it
            // made, amortised across its life. Making the multiplier decay with the remaining
            // term is a different (veCRV-style) design; it would require the maintenance sweep to
            // re-synchronise every live locker continuously rather than only at expiry, otherwise
            // every locked position would sit permanently over-weighted between touches.
            //
            // `unlockTime` is untouched, so nothing here shortens anybody's lock. The remainder is
            // >= lockDays_ >= MIN_LOCK_DAYS (this branch only runs when the existing unlock is the
            // later one) and <= MAX_LOCK_DAYS, so the uint16 cast cannot truncate.
            uint256 remainingDays = (uint256(u.unlockTime) - block.timestamp) / 1 days;
            // forge-lint: disable-next-line(unsafe-typecast)
            u.lockDays = uint16(remainingDays);
            emit LockSet(msg.sender, remainingDays, u.unlockTime, boostByDays(remainingDays));
        }
        _addLocker(msg.sender);   // idempotent: a shorter top-up inherits (and stays under) the live lock

        _resync(msg.sender);
        emit Deposited(msg.sender, amount_, u.staked);
        _autoMaintain(msg.sender);
    }

    function borrow(uint256 amount_)
        external nonReentrant whenNotPaused whenNotEmergency conserves
    {
        if (amount_ == 0) revert Staking__ZeroAmount();

        _updateGlobal();
        _settlePendingRewards(msg.sender);
        _settlePendingPureYield(msg.sender);
        _accrueInterestFor(msg.sender);
        _processLockExpiry(msg.sender);

        UserInfo storage u = _users[msg.sender];
        if (u.debt + amount_ > _ltvCap(u)) revert Staking__LTVExceeded();   // LTV on EFFECTIVE stake
        // Aggregate cap (H-04): no single borrow may lift the WHOLE book past the
        // protocol utilisation ceiling. A caller with LTV headroom has staked
        // collateral, so totalStaked > 0 holds here — the zero-guard is defensive.
        if (totalStaked == 0 ||
            ML.mulDiv(totalDebt + amount_, WAD, totalStaked) > MAX_PROTOCOL_UTIL_WAD)
            revert Staking__UtilTooHigh();

        bool wasZeroDebt = (u.debt == 0);
        u.debt          += amount_;
        totalDebt       += amount_;
        u.lastAccrueTime = block.timestamp;
        if (wasZeroDebt) _addBorrower(msg.sender);

        _resync(msg.sender);

        if (!ML.rawTransfer(bzpx, msg.sender, amount_)) revert Staking__TransferFailed();
        emit Borrowed(msg.sender, amount_, u.debt, _interestRate());
        _autoMaintain(msg.sender);
    }

    /// @dev repay is allowed under pause (a borrower must always be able to de-risk).
    function repay(uint256 amount_) external nonReentrant whenNotEmergency conserves {
        if (amount_ == 0) revert Staking__ZeroAmount();

        _updateGlobal();
        UserInfo storage u = _users[msg.sender];
        if (u.debt == 0) revert Staking__NoDebt();

        _settlePendingRewards(msg.sender);
        _settlePendingPureYield(msg.sender);
        _accrueInterestFor(msg.sender);
        _processLockExpiry(msg.sender);
        if (u.debt == 0) revert Staking__NoDebt();

        uint256 toRepay = amount_ > u.debt ? u.debt : amount_;
        if (!ML.rawTransferFrom(bzpx, msg.sender, address(this), toRepay)) revert Staking__TransferFailed();

        u.debt    -= toRepay;
        totalDebt -= toRepay;
        if (u.debt == 0) { _removeBorrower(msg.sender); if (u.staked > 0) u.depositBlock = uint64(block.number); }

        _resync(msg.sender);
        emit Repaid(msg.sender, toRepay, u.debt);
        _autoMaintain(msg.sender);
    }

    /// @dev withdraw is allowed under pause (exit), blocked under emergency (use emergencyWithdraw).
    ///      TWO hard preconditions: (1) the lock must have expired, and (2) the position must be
    ///      DEBT-FREE — a borrower must repay everything before withdrawing any stake. There is no
    ///      early-exit-with-debt path and therefore no exit penalty.
    function withdraw(uint256 amount_) external nonReentrant whenNotEmergency conserves {
        if (amount_ == 0) revert Staking__ZeroAmount();
        UserInfo storage u = _users[msg.sender];
        if (u.debt != 0)                                         revert Staking__HasDebt();      // repay everything first
        if (block.number <= u.depositBlock + MIN_DEPOSIT_BLOCKS) revert Staking__FlashLoanProtection();
        if (u.lockDays > 0 && block.timestamp < u.unlockTime)    revert Staking__StillLocked();

        _updateGlobal();
        _settlePendingRewards(msg.sender);
        _settlePendingPureYield(msg.sender);
        _processLockExpiry(msg.sender);

        if (u.staked < amount_) revert Staking__InsufficientStake();

        _updateInterestIndex();      // price the elapsed slice before totalStaked moves the rate
        u.staked    -= amount_;
        // SATURANTE, como `emergencyWithdraw` sempre fez. Assimetria apanhada em 2026-08-19:
        // o canal de emergencia saturava, mas `withdraw` e `liquidate` faziam `-=` cru. O debito
        // global de juro e EAGER sobre o livro inteiro e a cobranca por-utilizador e LAZY, logo se
        // `totalStaked` alguma vez ficar abaixo de Sigma u.staked o canal de saida NORMAL fazia
        // panic underflow e prendia fundos enquanto o de emergencia passava — o canal desprotegido
        // era exatamente o que toda a gente usa. Nao ha exploit demonstrado: isto elimina a CLASSE,
        // nao um bug conhecido. Assimetria de custos: saturar custa uma comparacao; nao saturar
        // custa o ultimo utilizador nao conseguir sair.
        totalStaked = _sub0(totalStaked, amount_);

        _resync(msg.sender);

        if (!ML.rawTransfer(bzpx, msg.sender, amount_)) revert Staking__TransferFailed();
        emit Withdrawn(msg.sender, amount_, 0, 0, amount_);
        _autoMaintain(msg.sender);
    }

    function claimRewards() external nonReentrant whenNotEmergency conserves {
        _updateGlobal();
        _settlePendingRewards(msg.sender);
        _settlePendingPureYield(msg.sender);
        _accrueInterestFor(msg.sender);
        _processLockExpiry(msg.sender);
        _resync(msg.sender);
        _autoMaintain(msg.sender);
    }

    function claimPureYield() external nonReentrant whenNotEmergency conserves {
        UserInfo storage u = _users[msg.sender];
        if (u.debt != 0) revert Staking__HasDebt();
        if (block.number <= u.depositBlock + MIN_DEPOSIT_BLOCKS) revert Staking__FlashLoanProtection();
        _updateGlobal();
        _settlePendingRewards(msg.sender);
        _settlePendingPureYield(msg.sender);
        _resync(msg.sender);
        _autoMaintain(msg.sender);
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  LOCK
    // ════════════════════════════════════════════════════════════════════════════════════
    /// @notice Commit your stake for `lockDays_` days (min MIN_LOCK_DAYS, max MAX_LOCK_DAYS) to
    ///         earn a boost. A decreasing countdown caps the duration at the time remaining until
    ///         the emission close, so no lock can ever outlast emission. Commitments can only
    ///         be EXTENDED (the new unlock must be later than the current one), never shortened.
    function lock(uint256 lockDays_) external nonReentrant whenNotPaused whenNotEmergency conserves {
        if (lockDays_ < MIN_LOCK_DAYS) revert Staking__LockTooShort();
        if (lockDays_ > MAX_LOCK_DAYS) revert Staking__LockTooLong();
        if (block.timestamp >= emissionEnd) revert Staking__EmissionEnded();

        UserInfo storage u = _users[msg.sender];
        if (u.staked == 0) revert Staking__NoStake();
        if (block.number <= u.depositBlock + MIN_DEPOSIT_BLOCKS) revert Staking__FlashLoanProtection();

        // Decreasing countdown: the lock may never extend past the emission close.
        uint256 maxDays = (emissionEnd - block.timestamp) / 1 days;
        maxDays = _min(maxDays, MAX_LOCK_DAYS);
        if (lockDays_ > maxDays) revert Staking__LockExceedsEmissionEnd();

        _updateGlobal();
        _settlePendingRewards(msg.sender);
        _settlePendingPureYield(msg.sender);
        _accrueInterestFor(msg.sender);

        _processLockExpiry(msg.sender);   // an elapsed commitment is cleared (and de-registered) first

        // casting to 'uint64' is safe because the sum is (now + at most 2555 days) — see deposit().
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 newUnlock = uint64(block.timestamp + lockDays_ * 1 days);
        if (newUnlock <= u.unlockTime) revert Staking__CannotReduceLock();

        // casting to 'uint16' is safe because lockDays_ <= MAX_LOCK_DAYS (2555) is enforced above.
        // forge-lint: disable-next-line(unsafe-typecast)
        u.lockDays   = uint16(lockDays_);
        u.unlockTime = newUnlock;
        _addLocker(msg.sender);

        _resync(msg.sender);
        emit LockSet(msg.sender, lockDays_, u.unlockTime, boostByDays(lockDays_));
        _autoMaintain(msg.sender);
    }

    /// @notice Permissionless state resynchronisation: normalise ONE position whose commitment has
    ///         elapsed, releasing its boost weight from the global denominators. Anyone may call it
    ///         for anyone, at their own gas cost — nobody has to wait for the rotating window.
    ///         Routed through the same `lockStep` the autonomous sweep uses, so there is exactly ONE
    ///         normalisation path in the contract and no chance of the two drifting apart. Unlike
    ///         the sweep it is NOT wrapped in try/catch: the caller asked for this specific position,
    ///         so a failure is surfaced rather than silently swallowed.
    function pokeExpiredLock(address user_) external nonReentrant whenNotEmergency conserves {
        UserInfo storage u = _users[user_];
        if (u.lockDays == 0) revert Staking__NoLock();
        if (block.timestamp < u.unlockTime) revert Staking__StillLocked();
        _updateGlobal();
        this.lockStep(user_, msg.sender);
        _autoMaintain(msg.sender);
    }

    /// @notice Batch form of `pokeExpiredLock`. Entries that are not (or no longer) expired are
    ///         SKIPPED rather than reverting, so a keeper's batch can never be griefed into failing
    ///         by one address somebody else normalised first, duplicates are harmless, and a
    ///         position the token refuses to pay costs the batch that entry and nothing more.
    ///         Reverts only if NOTHING in the list was actionable, so a no-op batch cannot be
    ///         passed off as maintenance. The list is caller-supplied and caller-funded, so its
    ///         length needs no protocol-side bound — the block gas limit is the bound, and it can
    ///         only ever cost the caller.
    function pokeExpiredLocks(address[] calldata users_) external nonReentrant whenNotEmergency conserves {
        _updateGlobal();
        uint256 swept;
        for (uint256 i = 0; i < users_.length; ) {
            UserInfo storage w = _users[users_[i]];
            if (w.lockDays > 0 && block.timestamp >= w.unlockTime) {
                try this.lockStep(users_[i], msg.sender) { unchecked { ++swept; } } catch {}
            }
            unchecked { ++i; }
        }
        if (swept == 0) revert Staking__NoLock();
        // Deliberately NOT `_autoMaintain`. The caller has just normalised expired commitments
        // explicitly and BY NAME, so re-running the rotating LOCK window on top of that is pure
        // duplicated work — measured at 246,261 gas, 83% of this call, against 49,060 of actual
        // work. The SOLVENCY window is kept: it is unrelated to what the caller just did, and it
        // is the part the protocol genuinely needs every transaction to carry.
        //
        // This is not a weakening. The passive lock sweep costs O(S / budget) transactions to
        // reach a given position (see test/SweepLatency.t.sol), and the escape hatch from that
        // latency only helps if it is cheap enough to be used. Charging 5x to duplicate the slow
        // path was a disincentive to the exact behaviour the protocol wants.
        if (!paused() && !emergencyMode) {
            uint256 b = _maintBudget();
            if (b != 0) _sweepBorrowers(msg.sender, b);
            lastMaintTime = block.timestamp;
        }
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  LIQUIDATION — permissionless, keeper-incentivised, no global iteration
    // ════════════════════════════════════════════════════════════════════════════════════
    function liquidate(address user_)
        external nonReentrant whenNotPaused whenNotEmergency conserves
    {
        _updateGlobal();
        _accrueInterestFor(user_);
        if (!_isLiquidatable(_users[user_])) revert Staking__NotLiquidatable();
        uint256 bonus = _executeLiquidation(user_, msg.sender);
        if (bonus > 0) {
            if (!ML.rawTransfer(bzpx, msg.sender, bonus)) revert Staking__TransferFailed();
        }
    }

    function _executeLiquidation(address user_, address keeper_) internal returns (uint256 keeperBonus) {
        _settlePendingRewards(user_);    // pay the position's earned emission before zeroing
        _settlePendingPureYield(user_);

        UserInfo storage u = _users[user_];
        uint256 stake = u.staked;
        uint256 debt  = u.debt;

        uint256 bonus  = ML.mulDiv(debt, LIQ_BONUS_BPS, 10_000);
        uint256 seized = debt + bonus;
        seized = _min(seized, stake);

        uint256 leftover = _sub0(stake, seized);
        keeperBonus      = _sub0(seized, debt);   // surplus -> keeper (conservation-consistent)

        uint256 badDebt  = _sub0(debt, stake);
        uint256 covered  = 0;
        if (badDebt > 0 && protocolReserve > 0) {
            covered = badDebt > protocolReserve ? protocolReserve : badDebt;
            protocolReserve -= covered;
        }
        uint256 uncovered = badDebt - covered;

        // saturante — ver a nota em `withdraw` (assimetria de canais, 2026-08-19)
        totalStaked = _sub0(totalStaked, seized);   // (seized - bonus == debt) fica, a compensar o borrow
        totalDebt   -= debt;
        u.debt   = 0;
        u.staked = leftover;
        _removeBorrower(user_);

        if (leftover == 0) {
            _applyBoost(u, 0, 0);
            _removeLocker(user_);
            delete _users[user_];
        } else {
            u.depositBlock = uint64(block.number);   // debt now 0 -> becomes a pure staker
            // The survivor keeps its lock and its registry entry: it is now a PURE staker, exactly
            // the class `_borrowers` can no longer see, so `_lockers` is what keeps its weight
            // honest from here on.
            _resync(user_);
        }

        if (badDebt > 0 && uncovered > 0) { unchecked { totalBadDebt += uncovered; } }
        unchecked { ++totalLiquidations; }
        emit Liquidated(user_, keeper_, seized, debt, keeperBonus, leftover, uncovered);
    }

    function _isLiquidatable(UserInfo storage u) internal view returns (bool) {
        if (u.debt == 0)   return false;
        if (u.staked == 0) return true;
        return u.debt * 100 >= u.staked * LIQ_THRESHOLD;
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  AUTONOMOUS MAINTENANCE — self-driving, gas-bounded, keeper-incentivised
    // ════════════════════════════════════════════════════════════════════════════════════

    /// @notice How many entries of a registry of size `len` the NEXT user tx will opportunistically
    ///         scan. Self-sizes with backlog pressure — more tracked entries OR more time since the
    ///         last sweep widen the window — but is hard-capped at MAINT_MAX_SCAN so per-tx gas is
    ///         always bounded. No admin, no governance: the schedule is a pure function of on-chain
    ///         state. Both maintenance windows (borrowers and lockers) are sized by this one rule.
    function _windowBudget(uint256 len) internal view returns (uint256 c) {
        if (len == 0) return 0;
        c = MAINT_BASE + len / MAINT_DENSITY;
        uint256 last = lastMaintTime;
        if (last != 0 && block.timestamp > last) {
            c += (block.timestamp - last) / MAINT_GAP_UNIT;
        }
        c = _min(c, MAINT_MAX_SCAN);
        c = _min(c, len);
    }
    function _maintBudget() internal view returns (uint256) { return _windowBudget(_borrowers.length); }
    function _lockBudget()  internal view returns (uint256) { return _windowBudget(_lockers.length); }

    /// @notice The autonomous engine. Carried by EVERY ordinary user transaction. Walks a
    ///         rotating window of borrowers from a persistent cursor: liquidates any underwater
    ///         position (surplus -> the gas-payer) and keeps every other scanned position's
    ///         interest, lock-expiry and boost weight fresh, so the global reward denominators
    ///         never drift away from reality.
    ///
    ///         SAFETY — disabled while paused or in emergency, so a borrower who cannot act can
    ///         NEVER be liquidated by someone else's transaction. Bounded by `_maintBudget`, so
    ///         per-tx gas is bounded regardless of how many borrowers exist.
    function _autoMaintain(address beneficiary) internal {
        if (paused() || emergencyMode) return;
        uint256 bBudget = _maintBudget();
        uint256 lBudget = _lockBudget();
        if (bBudget == 0 && lBudget == 0) return;
        _sweepBorrowers(beneficiary, bBudget);
        _sweepExpiredLocks(beneficiary, lBudget);
        lastMaintTime = block.timestamp;
    }

    /// @dev Window 1 — solvency. Rotating scan of the borrower registry: liquidate anything
    ///      underwater (surplus to the gas-payer), otherwise fully poke the position.
    function _sweepBorrowers(address beneficiary, uint256 budget) internal {
        for (uint256 n = 0; n < budget; ) {
            uint256 len = _borrowers.length;
            if (len == 0) break;
            uint256 idx = _maintCursor % len;
            address who = _borrowers[idx];

            if (who == beneficiary) { unchecked { ++_maintCursor; ++n; } continue; }

            // Self-external call so a single poisoned position can NEVER revert the innocent
            // user's carrying transaction. If BZPX were ever a token that refuses to pay a
            // particular address (e.g. a blacklist) the settle/liquidation transfer to `who`
            // would revert; here that step is rolled back atomically and skipped, the cursor
            // advances so the sweep never stalls, and the user's own action still succeeds.
            // `maintStep` manages the cursor on its own success paths (held on a liquidation
            // swap-pop, advanced on a poke); only the failure path advances it here.
            try this.maintStep(who, beneficiary) {
            } catch {
                unchecked { ++_maintCursor; }
            }
            unchecked { ++n; }
        }
    }

    /// @dev Window 2 — YIELD FAIRNESS. Rotating scan of the locker registry, which is the ONLY
    ///      window that can see a debt-free position. Any entry whose commitment has elapsed is
    ///      normalised on the spot: rewards settled at the weight they were actually earned at,
    ///      then the boost released from the global denominators and the entry de-registered.
    ///      This is what stops an idle expired staker from silently drawing an oversized share of
    ///      every ongoing emission and interest distribution.
    ///
    ///      Three cursor disciplines, and none of them can stall the rotation:
    ///        • a normalised position is swap-popped out, so the cursor HOLDS (a new address now
    ///          occupies the slot) and the array is strictly shorter;
    ///        • a stale entry (lock already cleared elsewhere) is pruned the same way — the
    ///          registry is self-healing and can never accumulate dead weight;
    ///        • a still-locked entry, the beneficiary, or a position the token refuses to pay is
    ///          simply rotated past.
    ///      TERMINATION. Every iteration either advances the cursor (consuming probe budget) or
    ///      shortens the array (consuming action budget), so the loop runs at most
    ///      `probes + MAINT_MAX_LOCK_ACTIONS` times — no branch can spin.
    function _sweepExpiredLocks(address beneficiary, uint256 probes) internal {
        uint256 acted;
        for (uint256 n = 0; n < probes && acted < MAINT_MAX_LOCK_ACTIONS; ) {
            uint256 len = _lockers.length;
            if (len == 0) break;
            uint256 idx = _lockCursor % len;
            address who = _lockers[idx];
            UserInfo storage w = _users[who];

            if (w.lockDays == 0) {
                _removeLocker(who);                                  // prune; cursor holds
                unchecked { ++acted; }
            // NO self-exclusion here, deliberately. The borrower window excludes the beneficiary
            // because liquidating your own position would pay you the keeper bonus. Normalising
            // your own elapsed commitment pays nothing — it only releases weight you are no longer
            // entitled to — so excluding the beneficiary here would let a position survive its own
            // maintenance traffic indefinitely and keep drawing an oversized share.
            } else if (block.timestamp >= w.unlockTime) {
                try this.lockStep(who, beneficiary) {                // removes `who`; cursor holds
                    unchecked { ++acted; }
                } catch {
                    unchecked { ++_lockCursor; ++n; }                // poisoned position -> skip
                }
            } else {
                unchecked { ++_lockCursor; ++n; }                    // still committed -> rotate on
            }
        }
    }

    /// @notice One maintenance step on a single borrower. ONLY callable by the contract itself
    ///         (from `_autoMaintain`), so it is not a public entry-point and carries no
    ///         nonReentrant of its own — it runs inside the carrying tx's reentrancy lock, while
    ///         any re-entry attempt by `who`'s token hook into a public function still hits that
    ///         lock and reverts. Being external lets `_autoMaintain` wrap it in try/catch and
    ///         isolate a single failing position without aborting the user's transaction.
    function maintStep(address who, address beneficiary) external {
        if (msg.sender != address(this)) revert Staking__NotSelf();

        _accrueInterestFor(who);
        if (_isLiquidatable(_users[who])) {
            uint256 bonus = _executeLiquidation(who, beneficiary);   // swap-pop removes `who` into idx
            if (bonus > 0) { if (!ML.rawTransfer(bzpx, beneficiary, bonus)) revert Staking__TransferFailed(); }
            emit MaintenanceSwept(beneficiary, who, bonus);
            unchecked { ++totalAutoLiquidations; }
            // cursor intentionally NOT advanced: the swapped-in borrower now occupies idx
        } else {
            // Full poke — identical to `who` touching their own position, so their reward
            // weight (tracked boost) never goes stale relative to their accrued stake.
            _settlePendingRewards(who);
            _settlePendingPureYield(who);
            _resync(who);
            unchecked { ++_maintCursor; }
        }
    }

    /// @notice One lock-normalisation step on a single expired position. ONLY callable by the
    ///         contract itself (from `_sweepExpiredLocks`), for exactly the same reasons as
    ///         `maintStep`: it runs inside the carrying transaction's reentrancy lock, and being
    ///         external is what lets the sweep wrap it in try/catch so one position the token
    ///         refuses to pay cannot abort an innocent user's transaction.
    ///
    ///         It re-checks expiry itself rather than trusting the caller, so it is safe under any
    ///         future call ordering, and it is guaranteed to de-register `who` on success — which
    ///         is what makes the cursor-holds discipline in the sweep terminate.
    function lockStep(address who, address beneficiary) external {
        if (msg.sender != address(this)) revert Staking__NotSelf();
        UserInfo storage u = _users[who];
        if (u.lockDays == 0)                revert Staking__NoLock();
        if (block.timestamp < u.unlockTime) revert Staking__StillLocked();

        // Settle FIRST: everything earned up to this instant was genuinely earned at the boosted
        // weight, and is paid at that weight. Only the FUTURE is re-priced.
        _settlePendingRewards(who);
        _settlePendingPureYield(who);
        _accrueInterestFor(who);

        uint256 relBE = u.trackedBoostedEffective;
        uint256 relBP = u.trackedBoostedPure;
        _resync(who);   // clears the lock, de-registers `who`, releases the excess weight
        unchecked { ++totalLockSweeps; }
        emit LockSwept(beneficiary, who,
            _sub0(relBE, u.trackedBoostedEffective),
            _sub0(relBP, u.trackedBoostedPure));
    }

    // ── Borrower registry: enables both autonomous maintenance and on-chain keeper discovery ──
    function _addBorrower(address who) internal {
        if (_borrowerIdx[who] == 0) { _borrowers.push(who); _borrowerIdx[who] = _borrowers.length; }
    }
    function _removeBorrower(address who) internal {
        uint256 idx = _borrowerIdx[who];
        if (idx == 0) return;
        uint256 len = _borrowers.length;
        if (idx != len) {
            address moved = _borrowers[len - 1];
            _borrowers[idx - 1] = moved;
            _borrowerIdx[moved] = idx;
        }
        _borrowers.pop();
        _borrowerIdx[who] = 0;
    }

    // ── Locker registry: the window that can see DEBT-FREE positions ─────────────────────────
    //  `_borrowers` is, by construction, blind to a pure staker (debt == 0) — which is precisely
    //  the class whose expired lock would otherwise never be normalised without the user acting.
    //  This registry closes that gap; it holds every position with a live commitment, and an entry
    //  is destroyed the moment `_processLockExpiry` clears the lock (from ANY path: the user's own
    //  transaction, a keeper poke, the borrower sweep, or the locker sweep).
    function _addLocker(address who) internal {
        if (_lockerIdx[who] == 0) { _lockers.push(who); _lockerIdx[who] = _lockers.length; }
    }
    function _removeLocker(address who) internal {
        uint256 idx = _lockerIdx[who];
        if (idx == 0) return;
        uint256 len = _lockers.length;
        if (idx != len) {
            address moved = _lockers[len - 1];
            _lockers[idx - 1] = moved;
            _lockerIdx[moved] = idx;
        }
        _lockers.pop();
        _lockerIdx[who] = 0;
    }

    function activeBorrowerCount() external view returns (uint256) { return _borrowers.length; }
    function borrowerAt(uint256 i) external view returns (address) { return _borrowers[i]; }
    function isTrackedBorrower(address who) external view returns (bool) { return _borrowerIdx[who] != 0; }
    function maintenanceBudget() external view returns (uint256) { return _maintBudget(); }
    function activeLockerCount() external view returns (uint256) { return _lockers.length; }
    function lockerAt(uint256 i) external view returns (address) { return _lockers[i]; }
    function isTrackedLocker(address who) external view returns (bool) { return _lockerIdx[who] != 0; }
    function lockSweepBudget() external view returns (uint256) { return _lockBudget(); }
    function getLockers(uint256 offset, uint256 limit)
        external view returns (address[] memory out, uint256 total)
    {
        total = _lockers.length;
        if (offset >= total || limit == 0) return (new address[](0), total);
        uint256 end = offset + limit;
        end = _min(end, total);
        out = new address[](end - offset);
        for (uint256 i = offset; i < end; ) { out[i - offset] = _lockers[i]; unchecked { ++i; } }
    }

    /// @notice Bounded scan of the locker registry for commitments that have elapsed but have not
    ///         been normalised yet — everything a keeper or monitor needs to quantify, and then
    ///         erase, the stale-boost backlog without any off-chain indexer.
    /// @param  offset  first registry index to inspect
    /// @param  limit   how many entries to inspect (page size; the array is unbounded, this is not)
    /// @return users   the expired-but-unswept positions found in the page — feed straight into
    ///                 `pokeExpiredLocks`
    /// @return excessBoostedEffective  emission weight those positions are still carrying ABOVE the
    ///                 1.00x baseline they are now entitled to
    /// @return excessBoostedPure       the same excess on the pure-yield (interest) denominator
    /// @return total   size of the whole registry, for paging
    function expiredLockScan(uint256 offset, uint256 limit)
        external view
        returns (address[] memory users, uint256 excessBoostedEffective, uint256 excessBoostedPure, uint256 total)
    {
        total = _lockers.length;
        if (offset >= total || limit == 0) return (new address[](0), 0, 0, total);
        uint256 end = offset + limit;
        end = _min(end, total);

        address[] memory buf = new address[](end - offset);
        uint256 n;
        for (uint256 i = offset; i < end; ) {
            address who = _lockers[i];
            UserInfo storage u = _users[who];
            if (u.lockDays > 0 && block.timestamp >= u.unlockTime) {
                buf[n] = who;
                unchecked { ++n; }
                // `_computeBoost` already prices the expired commitment at 1.00x, so the gap to the
                // still-tracked weight IS the excess this position is over-earning on.
                (uint256 be, uint256 bp) = _computeBoost(u);
                if (u.trackedBoostedEffective > be) excessBoostedEffective += u.trackedBoostedEffective - be;
                if (u.trackedBoostedPure      > bp) excessBoostedPure      += u.trackedBoostedPure      - bp;
            }
            unchecked { ++i; }
        }
        users = new address[](n);
        for (uint256 i = 0; i < n; ) { users[i] = buf[i]; unchecked { ++i; } }
    }

    function getBorrowers(uint256 offset, uint256 limit)
        external view returns (address[] memory out, uint256 total)
    {
        total = _borrowers.length;
        if (offset >= total || limit == 0) return (new address[](0), total);
        uint256 end = offset + limit;
        end = _min(end, total);
        out = new address[](end - offset);
        for (uint256 i = offset; i < end; ) { out[i - offset] = _borrowers[i]; unchecked { ++i; } }
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  EMISSION ACCUMULATOR — deterministic (empty intervals advance the clock)
    // ════════════════════════════════════════════════════════════════════════════════════
    function _updateGlobal() internal {
        // Both accumulators advance on the same clock, and this runs first in every entry point,
        // so no settle or checkpoint can ever observe a half-advanced book.
        _updateInterestIndex();
        uint256 tbe = totalBoostedEffective;
        if (tbe == 0) { lastRewardTime = block.timestamp; return; }   // no backlog capture
        uint256 t       = block.timestamp < emissionEnd ? block.timestamp : emissionEnd;
        if (t <= lastRewardTime) return;
        // The window's scheduled emission is the DELTA of the closed-form curve. `_emittedAt` is
        // monotone non-decreasing, so this can never underflow, and every property the linear
        // schedule had (deterministic, pure function of time, skipped windows stay in reserve)
        // carries over unchanged — only the curve's shape moved from flat to biennial halving.
        uint256 reward  = _emittedAt(t) - _emittedAt(lastRewardTime);
        if (tbe < MIN_EMISSION_WEIGHT) reward = ML.mulDiv(reward, tbe, MIN_EMISSION_WEIGHT);
        reward = _min(reward, rewardReserve);
        if (reward == 0) { lastRewardTime = block.timestamp; return; }
        accRewardPerShare      += ML.mulDiv(reward, WAD, tbe);
        rewardReserve          -= reward;
        totalRewardDistributed += reward;
        lastRewardTime          = block.timestamp;
    }

    /// @dev Cumulative scheduled emission at time `x` — the biennial-halving closed form
    ///      (see the constants block). O(1): one division, two shifts, one multiplication.
    ///      Monotone non-decreasing: within a period it grows linearly at `R0 >> p`; at each
    ///      rollover the sub-wei remainder the floored rate left behind (< PERIOD wei, i.e.
    ///      < 1e-10 BZPX) is folded into the `TOTAL − (TOTAL >> p)` term, a jump UP that keeps
    ///      the curve on the exact geometric series instead of drifting below it.
    ///      `unchecked` is safe: dt < EMISSION_LENGTH (~5.05e8 s), rate ≤ R0 (~1.43e18 wei/s),
    ///      so the product is < 1e27, and `TOTAL >> p` never exceeds TOTAL.
    function _emittedAt(uint256 x) internal view returns (uint256) {
        if (x <= emissionStart) return 0;
        if (x >= emissionEnd)   return TOTAL_REWARDS - (TOTAL_REWARDS >> EMISSION_PERIODS);
        unchecked {
            uint256 dt = x - emissionStart;
            uint256 p  = dt / HALVING_PERIOD;                     // 0..7 here, 8 is the clamp above
            return (TOTAL_REWARDS - (TOTAL_REWARDS >> p))
                 + (INITIAL_REWARD_PER_SEC >> p) * (dt - p * HALVING_PERIOD);
        }
    }

    /// @notice Cumulative emission the schedule has released up to `timestamp` — the O(1)
    ///         biennial-halving closed form, exposed so anyone can verify the whole curve
    ///         on-chain for free (same ethos as `solvency()` / `collateralRatio()`).
    function emittedAt(uint256 timestamp) external view returns (uint256) {
        return _emittedAt(timestamp);
    }

    /// @notice The emission rate in force right now: `R0 >> p` inside the programme, 0 after
    ///         the close. Halves at every period rollover.
    function currentRewardPerSec() public view returns (uint256) {
        if (block.timestamp >= emissionEnd) return 0;
        return INITIAL_REWARD_PER_SEC >> ((block.timestamp - emissionStart) / HALVING_PERIOD);
    }

    // ── settle (CEI: count, write debt, then pay) ─────────────────────────────────────────
    function _settlePendingRewards(address user_) internal {
        UserInfo storage u = _users[user_];
        if (u.trackedBoostedEffective == 0) return;
        uint256 gross = ML.mulDiv(u.trackedBoostedEffective, accRewardPerShare, WAD);
        if (gross <= u.rewardDebt) return;
        uint256 due = gross - u.rewardDebt;
        u.rewardDebt = gross;
        totalRewardsPaid += due;
        emit RewardClaimed(user_, due);
        if (!ML.rawTransfer(bzpx, user_, due)) revert Staking__TransferFailed();
    }

    function _settlePendingPureYield(address user_) internal {
        UserInfo storage u = _users[user_];
        if (u.trackedBoostedPure == 0) return;
        uint256 gross = ML.mulDiv(u.trackedBoostedPure, accPureYieldPerShare, WAD);
        if (gross <= u.pureYieldDebt) return;
        uint256 due = gross - u.pureYieldDebt;
        u.pureYieldDebt = gross;
        totalRewardsPaid += due;
        emit PureYieldClaimed(user_, due);
        if (!ML.rawTransfer(bzpx, user_, due)) revert Staking__TransferFailed();
    }

    // ── interest ──────────────────────────────────────────────────────────────────────────

    /// @dev Stamp the elapsed slice with the rate that prevailed across it, then move the clock.
    ///      Moves no value and touches no balance, so it is conservation-neutral and safe to call
    ///      from anywhere. It MUST be called before any write to `totalDebt` or `totalStaked`:
    ///      those are the only inputs to `_interestRate()`, so calling it first is what guarantees
    ///      the rate being stamped is the one that was actually in force for the whole slice.
    ///
    ///      Without this, a whole elapsed backlog would be priced at whatever the rate happened to
    ///      be at the instant somebody realised it — and since `borrow`, `repay` and `withdraw` all
    ///      move the rate before sweeping OTHER people's positions, the caller of a single
    ///      transaction could choose the rate at which months of somebody else's accrued interest
    ///      was charged against their collateral.
    ///      `mulDivSafe` throughout, deliberately. Utilisation is NOT bounded near the base of the
    ///      curve: the first borrow on a debt-free position already reaches 50%, and interest is
    ///      charged against collateral, so utilisation climbs on its own and can cross the 80%
    ///      kink into the steep branch. The rate can therefore become very large, and this path
    ///      sits underneath `deposit`, `borrow`, `repay`, `claim` and the maintenance sweep — it
    ///      must degrade to charging nothing rather than revert, or those entry points would
    ///      freeze exactly when the protocol is already under stress. This mirrors the saturating
    ///      arithmetic the per-user charge has always used.
    function _updateInterestIndex() internal {
        // Freeze the interest clock for the duration of an emergency. Interest is charged up to the
        // trip (tripBreaker/declareEmergency call this once, before setting the flag), then the clock
        // slides with wall time while charging nothing: borrowers cannot `repay` under emergency
        // (whenNotEmergency), so accruing across that window would bill a debt they are forbidden to
        // reduce, and would erode the haircut base while exits are in flight, leaking interest slices
        // into reward accounting the exiters forfeit. The slide keeps `cancelEmergency` resume-safe —
        // no retroactive lump on the first post-resume accrual.
        if (emergencyMode) { lastInterestTime = block.timestamp; return; }
        uint256 elapsed = block.timestamp - lastInterestTime;
        if (elapsed == 0) return;
        lastInterestTime = block.timestamp;
        uint256 debtNow = totalDebt;
        if (debtNow == 0) return;

        uint256 delta = ML.mulDivSafe(ML.mulDivSafe(WAD, _interestRate(), 10_000), elapsed, SECONDS_PER_YEAR);
        if (delta == 0) return;

        // The slice of interest the whole book generated over `elapsed`, settled NOW against the
        // denominators that existed NOW. Distribution and collection move together, so the ledger
        // never claims more than it holds:
        //     Δowed = −slice + reserveCut + toPool = 0,   Δbalance = 0
        uint256 slice = ML.mulDivSafe(debtNow, delta, WAD);
        if (slice == 0) return;
        if (slice > totalStaked) {
            // C-03 index-clamp coupling. The clamp binds (terminal distress): the global can
            // only debit `totalStaked`, so reduce the per-debt index advance to match. Otherwise
            // per-user charges (computed off the full delta) sum to MORE than was debited and the
            // shortfall reconcile in _accrueInterestFor over-restores totalStaked into a phantom
            // that re-opens clamp headroom and is paid out as unbacked yield. When the clamp does
            // NOT bind (the healthy regime) delta is used UNCHANGED, so interest is bit-identical
            // to pre-fix (no rounding drift, existing assertions unaffected). Either way
            // Σ per-user charges == the global debit.
            slice = totalStaked;
            delta = ML.mulDiv(slice, WAD, debtNow);
            if (delta == 0) return;   // sub-unit rounding at terminal totalStaked: charge nothing this window
            // Re-derive the global debit from the FLOORED delta. `delta` above rounds down, so
            // debiting the pre-floor `slice` (== totalStaked) would remove dust the index can
            // never attribute back to any position: totalStaked lands BELOW Σ u.staked and the
            // next checked `totalStaked -= seized` (liquidate) or `-= amount_` (withdraw) hits
            // a panic underflow — re-freezing liquidation in terminal distress, the exact DoS
            // LIQ-01 exists to remove. Recomputing makes the debit ⌊debtNow·δ/WAD⌋, the same
            // rounding contract the healthy branch has always had (global debit >= Σ per-user
            // ⌊dᵢ·δ/WAD⌋, equal in the single-borrower case), so the clamp binds without ever
            // pushing the global total under what positions still hold.
            slice = ML.mulDivSafe(debtNow, delta, WAD);
            if (slice == 0) return;
        }
        // Checked on purpose (a wrapped index would silently mis-price every position; ~1e32 away).
        accInterestPerDebt += delta;
        totalStaked -= slice;

        uint256 reserveCut = ML.mulDiv(slice, RESERVE_FACTOR_BPS, 10_000);
        uint256 toPool     = slice - reserveCut;
        protocolReserve   += reserveCut;
        if (toPool > 0) {
            uint256 tbp = totalBoostedPure;
            if (tbp > 0) {
                // MESMO amortecedor do canal irmao (`_updateGlobal`), pela mesma razao e com a
                // mesma constante. Ambos os canais dividem uma quantia por um peso agregado; a
                // emissao ja reconhecia que um denominador RESIDUAL deixa uma posicao-po capturar
                // o fluxo inteiro, e escalava a quantia por tbe/MIN_EMISSION_WEIGHT. Este canal
                // dividia por `totalBoostedPure` cru e fazia a escolha oposta em silencio.
                //
                // Medido (PureYieldDustDenominator.t.sol): com o livro em 40% de utilizacao e uma
                // unica posicao pure de 1 token, um ano de juro rendia-lhe 11.601 tokens — 97% de
                // TODA a receita de juro do protocolo, um retorno de 11.601x. Nao e yield por
                // criar: a fatia ja foi debitada do colateral dos mutuarios, e sem posicao pure
                // teria ido para `protocolReserve` (o ramo `else` mesmo aqui em baixo).
                //
                // O que nao se distribui NAO evapora. `slice` ja saiu de `totalStaked`, portanto
                // tem de aterrar nalgum sitio ou a identidade de conservacao de `conserves()`
                // rompe-se no proprio bloco: reserveCut + share + (toPool - share) == slice.
                uint256 share = tbp < MIN_EMISSION_WEIGHT
                    ? ML.mulDiv(toPool, tbp, MIN_EMISSION_WEIGHT)
                    : toPool;
                if (share > 0) {
                    accPureYieldPerShare   += ML.mulDiv(share, WAD, tbp);
                    totalRewardDistributed += share;
                }
                protocolReserve += toPool - share;
            } else {
                protocolReserve += toPool;
            }
        }
        unchecked { totalInterestAccruedGlobal += slice; }
    }

    function _accrueInterestFor(address user_) internal {
        _updateInterestIndex();
        UserInfo storage u = _users[user_];
        // A debt-free position simply re-checkpoints: it must never inherit index growth that
        // accumulated while it owed nothing.
        if (u.debt == 0) { u.lastAccrueTime = block.timestamp; u.interestIndex = accInterestPerDebt; return; }
        uint256 idxDelta = accInterestPerDebt - u.interestIndex;
        u.lastAccrueTime = block.timestamp;
        u.interestIndex  = accInterestPerDebt;
        if (idxDelta == 0) return;

        uint256 interest = ML.mulDivSafe(u.debt, idxDelta, WAD);
        if (interest == 0) return;

        if (interest > u.staked) {
            // C-03 fix (couple the clamps). _updateInterestIndex already debited the
            // GLOBAL totalStaked by this position's FULL interest and distributed it
            // (reserveCut + toPool), but only u.staked of it is actually collectible.
            // Add the uncollectible `shortfall` BACK to totalStaked so it again equals
            // Σ u.staked — restoring honest utilisation (no death-spiral overstatement),
            // an honest _owed()/isSolvent, an honest H-05 haircut denominator, and
            // closing the withdraw() checked-underflow freeze — and record it as
            // realised bad debt, because that interest was paid out to pure stakers /
            // the reserve yet never seized from anyone. Conserves-neutral under the
            // floor-free identity: +shortfall on the RHS (totalStaked) is matched by
            // +shortfall on the LHS (totalBadDebt). totalUncollectedInterest stays as
            // telemetry of the cumulative uncollectible interest.
            uint256 shortfall = interest - u.staked;
            unchecked {
                totalUncollectedInterest += shortfall;
                totalStaked              += shortfall;
                totalBadDebt             += shortfall;
            }
            interest = u.staked;
        }
        // ATTRIBUTION ONLY. The global side — totalStaked, the reserve cut and the pure-staker
        // credit — was already settled by `_updateInterestIndex` at the moment the interest
        // economically accrued. Touching them again here would double-count.
        u.staked -= interest;
        emit InterestAccrued(user_, interest, u.staked);
    }

    // ── single-writer boost + checkpoint ──────────────────────────────────────────────────

    /// @dev The lock duration a position may actually be PAID for, evaluated against the clock
    ///      rather than against stored state. Boost is the premium for illiquidity: the instant
    ///      `block.timestamp >= unlockTime` the capital is withdrawable again, so the effective
    ///      commitment is 0 days (1.00x) — whatever `lockDays` still holds in storage and whether
    ///      or not anybody has gotten around to normalising the position yet. Every weight in the
    ///      protocol is derived through here, so an un-swept expired lock can never be re-priced
    ///      at its historical multiplier by ANY code path.
    function _effectiveLockDays(UserInfo storage u) internal view returns (uint256) {
        if (u.lockDays == 0) return 0;
        return block.timestamp >= u.unlockTime ? 0 : uint256(u.lockDays);
    }

    function _computeBoost(UserInfo storage u) internal view returns (uint256 be, uint256 bp) {
        uint256 boost = boostByDays(_effectiveLockDays(u));
        uint256 effective = _effective(u);
        be = effective == 0 ? 0 : ML.mulDiv(effective, boost, BOOST_BASE);
        bp = (u.debt == 0 && u.staked > 0) ? ML.mulDiv(u.staked, boost, BOOST_BASE) : 0;
    }

    /// @dev THE sole writer of the boosted totals AND of totalPositiveEquity. Plain checked
    ///      subtraction: each global total is exactly the sum of all tracked contributions, so it
    ///      is always >= this user's tracked value; an underflow would signal drift and (correctly)
    ///      revert. CALLER CONTRACT: u.staked and u.debt are FINAL for this tx at the call site,
    ///      because the positive-equity summand is derived from them here — every equity-changing
    ///      path already resyncs through this writer before the tx ends, so the derived value is
    ///      exact over stored state. (emergencyWithdraw's kill path zeroes u.staked/u.debt before
    ///      its _applyBoost(u,0,0) precisely so this derivation releases, not resurrects, its equity.)
    /// @dev Saturating subtraction. This shape appeared inline 15 times across the contract —
    ///      exit paths, liquidation, the solvency views — and each copy re-emitted the same
    ///      branch. One copy is cheaper and, more to the point, one copy cannot drift from
    ///      itself. `unchecked` is safe by construction, not by assumption: the taken branch
    ///      is guarded by `a > b`, so `a - b` provably cannot underflow, and the checked
    ///      subtraction Solidity would otherwise emit is dead weight on every one of them.
    function _sub0(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked { return a > b ? a - b : 0; }
    }

    /// @dev Upper clamp. The `if (x > cap) x = cap;` shape appeared inline 17 times; naming it
    ///      makes the intent (a ceiling, not a guard) legible at the call site.
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _applyBoost(UserInfo storage u, uint256 newBE, uint256 newBP) internal {
        totalBoostedEffective = totalBoostedEffective - u.trackedBoostedEffective + newBE;
        totalBoostedPure      = totalBoostedPure      - u.trackedBoostedPure      + newBP;
        uint256 newEq = _sub0(u.staked, u.debt);
        totalPositiveEquity   = totalPositiveEquity   - u.trackedEquity           + newEq;
        u.trackedBoostedEffective = newBE;
        u.trackedBoostedPure      = newBP;
        u.trackedEquity           = newEq;
    }

    function _checkpoint(UserInfo storage u) internal {
        u.rewardDebt    = ML.mulDiv(u.trackedBoostedEffective, accRewardPerShare,   WAD);
        u.pureYieldDebt = ML.mulDiv(u.trackedBoostedPure,      accPureYieldPerShare, WAD);
    }

    /// @dev Normalise an expired lock in storage, recompute boost from current state, apply via the
    ///      single writer, re-checkpoint. Folding `_processLockExpiry` in here is what makes stored
    ///      state and tracked weight structurally UNABLE to diverge: every write of a boost weight
    ///      in this contract goes through `_resync`, so a position can never end a transaction
    ///      carrying a weight derived from a commitment that has already elapsed.
    ///
    ///      CALLER CONTRACT: `_settlePendingRewards` / `_settlePendingPureYield` MUST have run for
    ///      `user_` first — `_checkpoint` rebases the reward debts onto the new weight, so anything
    ///      still unsettled at that moment would be silently repriced.
    function _resync(address user_) internal {
        _processLockExpiry(user_);
        UserInfo storage u = _users[user_];
        (uint256 be, uint256 bp) = _computeBoost(u);
        _applyBoost(u, be, bp);
        _checkpoint(u);
    }

    function _processLockExpiry(address user_) internal {
        UserInfo storage u = _users[user_];
        if (u.lockDays > 0 && block.timestamp >= u.unlockTime) {
            u.lockDays = 0; u.unlockTime = 0;
            _removeLocker(user_);
            emit LockExpired(user_);
        }
    }

    // ── interest curve ──────────────────────────────────────────────────────────────────
    function _interestRate() internal view returns (uint256 rateBps) {
        uint256 util;
        if (totalStaked == 0) {
            // Debt with zero backing is MAXIMALLY utilised, not idle: report the
            // ceiling rate, never the floor. Accrual is unaffected — the slice in
            // _updateInterestIndex clamps to totalStaked (== 0) regardless of rate.
            if (totalDebt == 0) return RATE_R0;
            util = WAD;
        } else {
            util = ML.mulDiv(totalDebt, WAD, totalStaked);
            util = _min(util, WAD);   // reconcile with simulateRate(): both cap at WAD
        }
        if (util <= RATE_UK) rateBps = RATE_R0 + ML.mulDiv(util, RATE_S1, WAD);
        else                 rateBps = RATE_RK + ML.mulDiv(util - RATE_UK, RATE_S2, WAD);
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  MASTER CONSERVATION IDENTITY — the one equation, and its public proofs
    // ════════════════════════════════════════════════════════════════════════════════════

    /// @dev The right-hand side of the Master Conservation Identity: everything the protocol
    ///      owes to stakers, borrowers' collateral, reserves and accrued-but-unpaid rewards,
    ///      net of recorded (already-realised) bad debt.
    function _owed() internal view returns (uint256 owed_) {
        uint256 ledgerSum = totalStaked + rewardReserve + protocolReserve;
        uint256 ledgerNet = _sub0(ledgerSum, totalDebt);
        uint256 acc = _sub0(totalRewardDistributed, totalRewardsPaid);
        owed_ = ledgerNet + acc;
        owed_ = _sub0(owed_, totalBadDebt);   // recorded losses are netted out
    }

    /// @dev Accrued-but-unpaid reward / pure-yield still owed to positions. paid <= distributed
    ///      by construction, so the guard never fires — it only prevents an underflow. Used by
    ///      the conserves identity so the check stays floor-free and linear in every regime.
    function _pendingDistribution() internal view returns (uint256) {
        return _sub0(totalRewardDistributed, totalRewardsPaid);
    }

    /// @dev hard, one-sided: contract must hold at least what it owes (minus dust).
    function _hardBreach() internal view returns (bool) {
        return ML.rawBalanceOf(bzpx, address(this)) + CONSERVATION_DUST < _owed();
    }

    // ── PUBLIC SOLVENCY SURFACE — anyone can verify the protocol on-chain, for free ────────

    /// @notice The single number the protocol stands behind: what it currently owes.
    function owed() external view returns (uint256) { return _owed(); }

    /// @notice The physical BZPX the contract actually holds right now.
    function backing() external view returns (uint256) { return ML.rawBalanceOf(bzpx, address(this)); }

    /// @notice TRUE iff backing >= owed (minus dust). The protocol is solvent.
    function isSolvent() external view returns (bool) { return !_hardBreach(); }

    /// @notice Collateralisation ratio in WAD: backing / owed. 1e18 == exactly solvent,
    ///         > 1e18 == over-collateralised (surplus), < 1e18 == under-collateralised.
    ///         Returns type(uint256).max when nothing is owed (trivially solvent).
    function collateralRatio() external view returns (uint256) {
        uint256 o = _owed();
        if (o == 0) return type(uint256).max;
        return ML.mulDiv(ML.rawBalanceOf(bzpx, address(this)), WAD, o);
    }

    struct SolvencyReport {
        uint256 backing;             // physical BZPX held
        uint256 owed;                // _owed()
        uint256 surplus;             // backing - owed (0 if under-collateralised)
        uint256 deficit;             // owed - backing (0 if solvent)
        bool    solvent;             // backing + dust >= owed
        uint256 collateralRatioWad;  // backing * 1e18 / owed
        uint256 totalStaked;
        uint256 totalDebt;
        uint256 rewardReserve;
        uint256 protocolReserve;
        uint256 pendingDistribution; // totalRewardDistributed - totalRewardsPaid
        uint256 totalBadDebt;
        uint256 totalUncollectedInterest;
    }

    /// @notice One call, full picture: a self-contained solvency proof any wallet, dashboard or
    ///         watchdog can read without trusting the team. Mirrors the Master Conservation
    ///         Identity term-by-term so the equation can be re-derived by the caller.
    function solvency() external view returns (SolvencyReport memory r) {
        uint256 bal = ML.rawBalanceOf(bzpx, address(this));
        uint256 o   = _owed();
        r.backing             = bal;
        r.owed                = o;
        r.surplus             = _sub0(bal, o);
        r.deficit             = _sub0(o, bal);
        r.solvent             = bal + CONSERVATION_DUST >= o;
        r.collateralRatioWad  = o == 0 ? type(uint256).max : ML.mulDiv(bal, WAD, o);
        r.totalStaked         = totalStaked;
        r.totalDebt           = totalDebt;
        r.rewardReserve       = rewardReserve;
        r.protocolReserve     = protocolReserve;
        r.pendingDistribution = _sub0(totalRewardDistributed, totalRewardsPaid);
        r.totalBadDebt              = totalBadDebt;
        r.totalUncollectedInterest  = totalUncollectedInterest;
    }

    /// @notice Full 5-equation diagnostic for off-chain monitors. bit0 mirrors the on-chain
    ///         guard; bit1 (Solvency) is a SOFT signal (a position may be transiently unhealthy
    ///         pre-liquidation) and is intentionally NOT part of the revert guard.
    ///   bit0 Conservation  bit1 Solvency  bit2 EmissionCap  bit3 Monotonicity  bit4 BoostBounded
    function auditInvariants() external view returns (uint8 violations) {
        if (_hardBreach()) violations |= 1 << 0;
        // Solvency signal fires in the TERMINAL state too: totalStaked driven to 0
        // with debt outstanding is the worst case, not an unmonitored one.
        if ((totalStaked == 0 && totalDebt > 0) ||
            (totalStaked > 0 && totalDebt * 100 > totalStaked * LIQ_THRESHOLD)) violations |= 1 << 1;
        if (rewardReserve > TOTAL_REWARDS) violations |= 1 << 2;
        if (accRewardPerShare < lastAuditedAccReward || accPureYieldPerShare < lastAuditedAccPure)
            violations |= 1 << 3;
        uint256 maxBoosted = ML.mulDiv(totalStaked, boostByDays(MAX_LOCK_DAYS), BOOST_BASE);
        if (totalBoostedEffective > maxBoosted || totalBoostedPure > maxBoosted) violations |= 1 << 4;
    }

    function touchAuditSnapshot() external {
        if (accRewardPerShare    > lastAuditedAccReward) lastAuditedAccReward = accRewardPerShare;
        if (accPureYieldPerShare > lastAuditedAccPure)   lastAuditedAccPure   = accPureYieldPerShare;
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  VIEWS
    // ════════════════════════════════════════════════════════════════════════════════════
    /// @dev SINGLE SOURCE. `borrow` and every view that publishes a borrowing limit or a health
    ///      reading route through these, so a quoted maximum can never be a figure the borrow
    ///      path would reject.
    function _effective(UserInfo storage u) internal view returns (uint256) {
        return _sub0(u.staked, u.debt);
    }
    function _ltvCap(UserInfo storage u) internal view returns (uint256) {
        return ML.mulDiv(_effective(u), MAX_LTV, 100);
    }
    function _health(UserInfo storage u) internal view returns (uint256) {
        // Only a debt-free position is unconditionally healthy. A position whose
        // stake has been consumed to zero while debt remains is the WORST state
        // this function can describe, not the best — and the very next line says
        // so. Guarding on `staked == 0` here fired first and inverted the verdict,
        // reporting maximum health for a position `_isLiquidatable` treats as
        // immediately liquidatable. Interest accrual reaches that state on its
        // own (see `_accrue`: interest is clamped to the stake and the remainder
        // becomes uncollected), so it is ordinary, not adversarial.
        if (u.debt == 0)        return WAD;
        if (u.debt >= u.staked) return 0;
        return ML.mulDiv(u.staked - u.debt, WAD, u.staked);
    }

    function effectiveStakeOf(address user_) external view returns (uint256) {
        return _effective(_users[user_]);
    }
    function totalEffectiveStaked() external view returns (uint256) {
        // The aggregate effective (net) stake IS the positive-equity sum: Σ max(staked − debt, 0).
        // `totalStaked − totalDebt` nets underwater positions' negative equity in and understates it
        // whenever any position is underwater — the same defect the emergency haircut carried. Reading
        // the maintained accumulator returns the honest figure to integrators and costs one SLOAD
        // instead of two-plus-arithmetic.
        return totalPositiveEquity;
    }
    function healthFactor(address user_) external view returns (uint256) {
        return _health(_users[user_]);
    }
    function _daysToLiqInternal(UserInfo storage u) internal view returns (uint256) {
        // Same correction as `_health`: only a debt-free position is never
        // liquidatable. With debt outstanding and the stake consumed to zero the
        // next line already returns 0 (debt*100 >= 0 holds), which agrees with
        // `_isLiquidatable`. The old `|| u.staked == 0` reported "never" for
        // exactly the positions a liquidator most needs to find — the ones with
        // no collateral left, which are where bad debt accumulates.
        if (u.debt == 0)                              return type(uint256).max;
        if (u.debt * 100 >= u.staked * LIQ_THRESHOLD) return 0;
        uint256 stakeAtLiq = ML.mulDiv(u.debt, 100, LIQ_THRESHOLD) + 1;
        if (u.staked <= stakeAtLiq) return 0;
        uint256 daily = ML.mulDivSafe(ML.mulDivSafe(u.debt, _interestRate(), 10_000), 1 days, SECONDS_PER_YEAR);
        return daily == 0 ? type(uint256).max : (u.staked - stakeAtLiq) / daily;
    }
    function daysToLiquidation(address user_) external view returns (uint256) { return _daysToLiqInternal(_users[user_]); }
    function currentInterestRateBps() external view returns (uint256) { return _interestRate(); }
    function utilizationRate() external view returns (uint256) {
        // Terminal state: debt outstanding with the stake pool consumed to zero is
        // INFINITE utilisation, not 0% — reporting 0 made maximum distress read as
        // perfect health.
        if (totalStaked == 0) return totalDebt > 0 ? type(uint256).max : 0;
        return ML.mulDiv(totalDebt, WAD, totalStaked);
    }
    function maxBorrowOf(address user_) external view returns (uint256) {
        UserInfo storage u = _users[user_];
        uint256 cap = _ltvCap(u);
        return _sub0(cap, u.debt);
    }
    function remainingStakeCapacity(address user_) external view returns (uint256) {
        uint256 s = _users[user_].staked;
        return s >= MAX_STAKE_PER_WALLET ? 0 : MAX_STAKE_PER_WALLET - s;
    }
    /// @notice Lock state of a position. `lockDays` / `unlockTime` are the COMMITMENT ON RECORD;
    ///         `boostBps` is what the position is actually paid at RIGHT NOW, so once `expired` is
    ///         true it reads 10000 (1.00x) even if the stale commitment has not been swept out of
    ///         storage yet. The view can never flatter a position the maths no longer rewards.
    function lockInfoOf(address user_) external view returns (uint256 lockDays, uint256 unlockTime, uint256 boostBps, bool expired) {
        UserInfo storage u = _users[user_];
        lockDays = u.lockDays; unlockTime = uint256(u.unlockTime);
        boostBps = boostByDays(_effectiveLockDays(u));
        expired = (u.lockDays > 0 && block.timestamp >= u.unlockTime);
    }
    /// @notice The lock duration the position is PAID for right now — 0 once the unlock has passed.
    function effectiveLockDaysOf(address user_) external view returns (uint256) {
        return _effectiveLockDays(_users[user_]);
    }
    /// @notice The multiplier (bps) the position is PAID at right now. 10000 == 1.00x.
    function effectiveBoostOf(address user_) external view returns (uint256) {
        return boostByDays(_effectiveLockDays(_users[user_]));
    }
    /// @notice TRUE when a position still carries boost weight from a commitment that has already
    ///         elapsed — i.e. it is waiting for the sweep (or a poke) and is over-earning until then.
    function hasStaleBoost(address user_) external view returns (bool) {
        UserInfo storage u = _users[user_];
        if (u.lockDays == 0 || block.timestamp < u.unlockTime) return false;
        (uint256 be, uint256 bp) = _computeBoost(u);
        return u.trackedBoostedEffective > be || u.trackedBoostedPure > bp;
    }
    /// @notice The longest lock (in days) that may be opened right now — the decreasing countdown:
    ///         min(MAX_LOCK_DAYS, days remaining until the emission programme closes).
    function maxLockDaysAvailable() public view returns (uint256) {
        if (block.timestamp >= emissionEnd) return 0;
        uint256 d = (emissionEnd - block.timestamp) / 1 days;
        d = _min(d, MAX_LOCK_DAYS);
        return d;
    }
    /// @notice Fraction of TOTAL_REWARDS the schedule has released so far, in WAD. This tracks
    ///         the halving CURVE, not the clock — 50% is reached at year 2, not year 8. Returns
    ///         exactly WAD once the programme closes (the 2^-8 tail is closed, not pending).
    function emissionProgress() external view returns (uint256) {
        if (block.timestamp >= emissionEnd) return WAD;
        return ML.mulDiv(_emittedAt(block.timestamp), WAD, TOTAL_REWARDS);
    }
    function timeSinceEmissionStart() external view returns (uint256) {
        return _sub0(block.timestamp, emissionStart);
    }
    function timeUntilEmissionEnd() external view returns (uint256) {
        return _sub0(emissionEnd, block.timestamp);
    }
    function timeUntilUnlock(address user_) external view returns (uint256) {
        UserInfo storage u = _users[user_];
        if (u.lockDays == 0) return 0;
        return block.timestamp < u.unlockTime ? uint256(u.unlockTime) - block.timestamp : 0;
    }
    /// @notice Indicative pure-staker APR (bps) for a given lock duration, from current interest flow.
    function pureStakerApr(uint256 lockDays_) external view returns (uint256 aprBps) {
        uint256 tbp = totalBoostedPure;
        if (tbp == 0) return 0;

        // A ESCALA. A versao anterior calculava `share = totalDebt * boost / tbp` e depois dividia
        // por WAD. Mas `totalDebt` e `tbp` sao ambos montantes de token: as unidades cancelam-se e
        // `share` fica na ordem de BOOST_BASE (~1e4), nao em WAD. Dividir 1e4 por 1e18 trunca para
        // ZERO — e por isso esta view devolvia 0 em TODOS os regimes, saudavel ou residual.
        // Medido em 2026-08-20: livro com 400.000e18 de divida, 611.941e18 de peso pure e taxa de
        // 299 bps anunciava 0,00% de APR.
        //
        // A DERIVACAO. Os mutuarios pagam `totalDebt * rate / 10_000` por ano. Um staker com peso
        // `w` recebe a fatia `w / tbp`, e o peso dele e `stake * boost / BOOST_BASE`. Logo a APR
        // sobre o capital DELE nao depende do tamanho do stake:
        //     aprBps = (totalDebt * rate / tbp) * (boost / BOOST_BASE) * (1 - reserva)
        uint256 base = ML.mulDiv(totalDebt, _interestRate(), tbp);
        base = ML.mulDiv(base, boostByDays(lockDays_), BOOST_BASE);

        // O MESMO amortecedor que a execucao e a view do pendente aplicam. Este canal tem TRES
        // sitios que dividem pelo denominador do peso pure — a execucao (`_updateInterestIndex`),
        // a cotacao do pendente (`_pendingPure`) e a APR publicada, aqui. PURE-01 corrigiu o
        // primeiro, PURE-02 o segundo, e este era o irmao que faltava: sem ele a APR anuncia uma
        // taxa que o protocolo nao paga quando o denominador e residual.
        if (tbp < MIN_EMISSION_WEIGHT) base = ML.mulDiv(base, tbp, MIN_EMISSION_WEIGHT);

        aprBps = ML.mulDiv(base, 10_000 - RESERVE_FACTOR_BPS, 10_000);
    }
    function pendingRewards(address user_) external view returns (uint256) {
        return _pendingReward(_users[user_]);
    }
    /// @dev SINGLE SOURCE. Every view that publishes an entitlement routes through these two, so
    ///      the aggregate report and the standalone getters are structurally unable to disagree.
    ///      Both project the un-settled slice, so a quote read in a block equals what a claim in
    ///      that same block pays.
    function _pendingReward(UserInfo storage u) internal view returns (uint256) {
        if (u.trackedBoostedEffective == 0 || totalBoostedEffective == 0) return 0;
        uint256 acc = accRewardPerShare;
        uint256 t = block.timestamp < emissionEnd ? block.timestamp : emissionEnd;
        if (t > lastRewardTime) {
            // Same closed-form delta `_updateGlobal` will integrate — quote == execution.
            uint256 r = _emittedAt(t) - _emittedAt(lastRewardTime);
            if (totalBoostedEffective < MIN_EMISSION_WEIGHT) r = ML.mulDiv(r, totalBoostedEffective, MIN_EMISSION_WEIGHT);
            r = _min(r, rewardReserve);
            acc += ML.mulDiv(r, WAD, totalBoostedEffective);
        }
        uint256 g = ML.mulDiv(u.trackedBoostedEffective, acc, WAD);
        return _sub0(g, u.rewardDebt);
    }

    function _pendingPure(UserInfo storage u) internal view returns (uint256) {
        if (u.trackedBoostedPure == 0) return 0;
        uint256 acc = accPureYieldPerShare;
        uint256 tbp = totalBoostedPure;
        // `emergencyMode` congela o relogio do juro no canal de EXECUCAO (`_updateInterestIndex`
        // desliza `lastInterestTime` e devolve sem cobrar), logo projetar aqui cotaria uma fatia
        // que nunca sera paga: medido, um ano de halt inflava a cotacao de 0,97e18 para 11.641e18.
        // O congelamento EMG-01/02 foi so a metade que executa; esta e a metade que cota.
        uint256 elapsed = emergencyMode ? 0 : _sub0(block.timestamp, lastInterestTime);
        if (elapsed > 0 && totalDebt > 0 && tbp > 0) {
            uint256 d = ML.mulDivSafe(ML.mulDivSafe(WAD, _interestRate(), 10_000), elapsed, SECONDS_PER_YEAR);
            uint256 slice = ML.mulDivSafe(totalDebt, d, WAD);
            slice = _min(slice, totalStaked);
            uint256 toPool = slice - ML.mulDiv(slice, RESERVE_FACTOR_BPS, 10_000);
            // O MESMO amortecedor que o canal de execucao aplica. "Both project the un-settled
            // slice, so a quote read in a block equals what a claim in that same block pays" e
            // garantia declarada no NatSpec destas duas views — sem esta linha a cotacao
            // sobre-estimava 981x com denominador residual (medido).
            uint256 share = tbp < MIN_EMISSION_WEIGHT
                ? ML.mulDiv(toPool, tbp, MIN_EMISSION_WEIGHT)
                : toPool;
            if (share > 0) acc += ML.mulDiv(share, WAD, tbp);
        }
        uint256 gross = ML.mulDiv(u.trackedBoostedPure, acc, WAD);
        return _sub0(gross, u.pureYieldDebt);
    }

    function pendingPureYield(address user_) external view returns (uint256) {
        return _pendingPure(_users[user_]);
    }
    function getUserInfo(address user_) external view returns (
        uint256 staked, uint256 debt, uint256 effectiveStake, uint256 maxBorrowAvailable,
        uint256 health, uint256 daysLeft, uint256 stakingRewards, uint256 pureYield,
        uint256 rateBps, uint256 lockDays, uint256 unlockTime, uint256 boostBps,
        uint256 remainingCap, uint256 maxDaysNow
    ) {
        UserInfo storage u = _users[user_];
        staked = u.staked; debt = u.debt;
        effectiveStake = _effective(u);
        uint256 cap = _ltvCap(u);
        maxBorrowAvailable = _sub0(cap, u.debt);
        health = _health(u);
        rateBps = _interestRate();
        daysLeft = _daysToLiqInternal(u);
        // `lockDays` / `unlockTime` report the commitment on record; `boostBps` reports what is
        // actually being paid, which drops to 1.00x the instant the unlock passes.
        lockDays = u.lockDays; unlockTime = uint256(u.unlockTime);
        boostBps = boostByDays(_effectiveLockDays(u));
        remainingCap = staked >= MAX_STAKE_PER_WALLET ? 0 : MAX_STAKE_PER_WALLET - staked;
        maxDaysNow = maxLockDaysAvailable();

        stakingRewards = _pendingReward(u);
        pureYield      = _pendingPure(u);
    }
    function getGlobalStats() external view returns (
        uint256 totalStaked_, uint256 totalDebt_, uint256 totalBoostedEffective_, uint256 totalBoostedPure_,
        uint256 utilizationWad, uint256 annualRateBps, uint256 rewardReserve_, uint256 protocolReserve_,
        uint256 emissionStart_, uint256 emissionEnd_, uint256 rewardPerSec, uint256 totalLiquidations_,
        uint256 totalBadDebt_, uint256 totalInterestAccruedGlobal_, uint256 owed_, uint256 maxDaysNow
    ) {
        totalStaked_ = totalStaked; totalDebt_ = totalDebt;
        totalBoostedEffective_ = totalBoostedEffective; totalBoostedPure_ = totalBoostedPure;
        utilizationWad = totalStaked == 0
            ? (totalDebt > 0 ? type(uint256).max : 0)
            : ML.mulDiv(totalDebt, WAD, totalStaked);
        annualRateBps = _interestRate();
        rewardReserve_ = rewardReserve; protocolReserve_ = protocolReserve;
        emissionStart_ = emissionStart; emissionEnd_ = emissionEnd; rewardPerSec = currentRewardPerSec();
        totalLiquidations_ = totalLiquidations; totalBadDebt_ = totalBadDebt;
        totalInterestAccruedGlobal_ = totalInterestAccruedGlobal; owed_ = _owed();
        maxDaysNow = maxLockDaysAvailable();
    }
    function simulateRate(uint256 utilizationWad_) external pure returns (uint256 rateBps) {
        utilizationWad_ = _min(utilizationWad_, WAD);
        if (utilizationWad_ <= RATE_UK) rateBps = RATE_R0 + ML.mulDiv(utilizationWad_, RATE_S1, WAD);
        else                            rateBps = RATE_RK + ML.mulDiv(utilizationWad_ - RATE_UK, RATE_S2, WAD);
    }
}
