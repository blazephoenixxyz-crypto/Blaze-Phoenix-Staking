// SPDX-License-Identifier: BUSL-1.1
// BlazePhoenix Protocol (c) April 2026 - April 2030
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
///     • DETERMINISTIC EMISSION. Empty-pool intervals advance the clock (emission stays in
///       reserve), so a latecomer can never capture a backlog.
///     • MANDATORY LOCKED STAKING. There is no liquid stake: every deposit commits its funds for
///       90..2555 days (a decreasing countdown caps it at the time left to the 7-year emission
///       end). Borrowing is allowed against that collateral, but a position must be FULLY REPAID
///       (debt == 0) before any stake can be withdrawn — so there is no early-exit and no penalty.
contract BlazePhoenixStaking is AccessControl, Pausable, ReentrancyGuard {

    string  public  constant VERSION              = "3.1.0";
    bytes32 private constant ROLE_ADMIN           = keccak256("ADMIN_ROLE");
    bytes32 private constant ROLE_GUARDIAN        = keccak256("GUARDIAN_ROLE");

    uint256 private constant WAD                  = 1e18;
    uint256 private constant SECONDS_PER_YEAR     = 365 days;

    // Emission: 180M BZPX linear over 7 years.
    uint256 public  constant TOTAL_REWARDS        = 180_000_000e18;
    uint256 public  constant EMISSION_PERIOD      = 7 * 365 days;
    uint256 public  constant REWARD_PER_SEC       = TOTAL_REWARDS / EMISSION_PERIOD;

    uint256 public  constant MAX_STAKE_PER_WALLET = 30_000_000e18;

    // Emission does not flow to a degenerate pool. The accumulator already declines to advance
    // when nothing is earning, so that a latecomer cannot harvest a backlog they were never
    // exposed to; a pool holding a single dust position is the same situation wearing a disguise.
    // Without this floor, one wei staked alone absorbs the ENTIRE schedule for as long as it is
    // the only position — 30 days of solitude is 1.17% of the whole 180,000,000 budget, bought
    // for one wei. The skipped emission is not lost: it stays in `rewardReserve` and is
    // recoverable by `sweepUndistributedEmission` once the programme ends.
    uint256 public  constant MIN_EMISSION_WEIGHT  = 1_000e18;

    uint256 public  constant MAX_LTV              = 50;
    uint256 public  constant LIQ_THRESHOLD        = 95;
    uint256 public  constant LIQ_BONUS_BPS        = 500;   // 5% surplus -> paid to the gas-payer
    uint256 public  constant RESERVE_FACTOR_BPS   = 300;   // 3%

    // Lock is measured in DAYS, between MIN_LOCK_DAYS and MAX_LOCK_DAYS (== the 7-year emission
    // window). Boost is continuous in the committed duration:
    //     boost(d) = 10000 + 750·(d/365) + 250·(d/365)²   [bps]
    //   d =   90 -> ~1.02x     d = 365 (1y)  -> 1.10x      d = 1825 (5y) -> 2.00x
    //   d =  730 (2y) -> 1.25x d = 2555 (7y) -> 2.75x
    uint256 public  constant DAYS_PER_YEAR        = 365;
    uint16  public  constant MIN_LOCK_DAYS        = 90;
    uint16  public  constant MAX_LOCK_DAYS        = uint16(7 * 365);   // 2555 == EMISSION_PERIOD in days
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
        uint256 balBefore  = ML.rawBalanceOf(bzpx, address(this));
        uint256 owedBefore = _owed();
        _;
        uint256 lhs = ML.rawBalanceOf(bzpx, address(this)) + owedBefore;
        uint256 rhs = balBefore + _owed();
        uint256 d = lhs > rhs ? lhs - rhs : rhs - lhs;
        if (d > CONSERVATION_DUST) revert Staking__InvariantBreached();
    }
    modifier whenNotEmergency() {
        if (emergencyMode) revert Staking__EmergencyActive();
        _;
    }

    constructor(address bzpx_, address treasury_) {
        if (bzpx_ == address(0) || treasury_ == address(0)) revert Staking__ZeroAddress();
        bzpx          = bzpx_;
        treasury      = treasury_;
        emissionStart = block.timestamp;
        emissionEnd   = block.timestamp + EMISSION_PERIOD;
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
        if (lockDays_ > MAX_LOCK_DAYS) lockDays_ = MAX_LOCK_DAYS;
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
        if (amount_ > protocolReserve) amount_ = protocolReserve;
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
    ///         is that an empty window leaves `REWARD_PER_SEC x empty_seconds` in `rewardReserve`
    ///         with no recipient: past `emissionEnd` the accumulator can never advance again,
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
        emergencyMode = true; emergencyTrippedAt = block.timestamp;
        if (!paused()) _pause();
        emit EmergencyDeclared(msg.sender, block.timestamp, true);
    }

    /// @notice Discretionary halt the GUARDIAN may declare for an off-chain-discovered issue,
    ///         independent of the on-chain breach condition. Cannot move funds.
    function declareEmergency() external onlyRole(ROLE_GUARDIAN) {
        if (emergencyMode) revert Staking__EmergencyActive();
        emergencyMode = true; emergencyTrippedAt = block.timestamp;
        if (!paused()) _pause();
        emit EmergencyDeclared(msg.sender, block.timestamp, false);
    }

    /// @notice Resume only if the hard invariant currently holds. Contract stays paused;
    ///         admin calls unpause() separately.
    function cancelEmergency() external onlyRole(ROLE_ADMIN) {
        if (!emergencyMode) revert Staking__EmergencyNotActive();
        if (_hardBreach())  revert Staking__InvariantBreached();
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
        uint256 payout = principal > debt ? principal - debt : 0;

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

        totalStaked = totalStaked > principal ? totalStaked - principal : 0;
        if (debt > 0) { totalDebt = totalDebt > debt ? totalDebt - debt : 0; _removeBorrower(msg.sender); }

        _applyBoost(u, 0, 0);              // single-writer cleanup — no ghost share
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
    ///         countdown cap (days remaining to the 7-year emission end, ≤ MAX_LOCK_DAYS). A
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

        // Decreasing countdown: a lock may never extend past the 7-year emission end.
        uint256 maxDays = (emissionEnd - block.timestamp) / 1 days;
        if (maxDays > MAX_LOCK_DAYS) maxDays = MAX_LOCK_DAYS;
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
        // horizon ends in 2033, ~2^33 seconds, ten orders of magnitude below uint64.
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
        totalStaked -= amount_;

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
    ///         the 7-year emission end, so no lock can ever outlast emission. Commitments can only
    ///         be EXTENDED (the new unlock must be later than the current one), never shortened.
    function lock(uint256 lockDays_) external nonReentrant whenNotPaused whenNotEmergency conserves {
        if (lockDays_ < MIN_LOCK_DAYS) revert Staking__LockTooShort();
        if (lockDays_ > MAX_LOCK_DAYS) revert Staking__LockTooLong();
        if (block.timestamp >= emissionEnd) revert Staking__EmissionEnded();

        UserInfo storage u = _users[msg.sender];
        if (u.staked == 0) revert Staking__NoStake();
        if (block.number <= u.depositBlock + MIN_DEPOSIT_BLOCKS) revert Staking__FlashLoanProtection();

        // Decreasing countdown: the lock may never extend past the 7-year emission end.
        uint256 maxDays = (emissionEnd - block.timestamp) / 1 days;
        if (maxDays > MAX_LOCK_DAYS) maxDays = MAX_LOCK_DAYS;
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
        _autoMaintain(msg.sender);
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
        if (seized > stake) seized = stake;

        uint256 leftover = stake > seized ? stake - seized : 0;
        keeperBonus      = seized > debt ? seized - debt : 0;   // surplus -> keeper (conservation-consistent)

        uint256 badDebt  = stake < debt ? debt - stake : 0;
        uint256 covered  = 0;
        if (badDebt > 0 && protocolReserve > 0) {
            covered = badDebt > protocolReserve ? protocolReserve : badDebt;
            protocolReserve -= covered;
        }
        uint256 uncovered = badDebt - covered;

        totalStaked -= seized;          // the (seized - bonus == debt) part stays, offsetting the borrow
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
        if (c > MAINT_MAX_SCAN) c = MAINT_MAX_SCAN;
        if (c > len) c = len;
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
            } else if (who != beneficiary && block.timestamp >= w.unlockTime) {
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
            relBE > u.trackedBoostedEffective ? relBE - u.trackedBoostedEffective : 0,
            relBP > u.trackedBoostedPure      ? relBP - u.trackedBoostedPure      : 0);
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
        if (end > total) end = total;
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
        if (end > total) end = total;

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
        if (end > total) end = total;
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
        // Below the floor the pool is treated as empty: the clock advances, nothing accrues.
        if (tbe < MIN_EMISSION_WEIGHT) { lastRewardTime = block.timestamp; return; } // no backlog capture
        uint256 t       = block.timestamp < emissionEnd ? block.timestamp : emissionEnd;
        uint256 elapsed = t > lastRewardTime ? t - lastRewardTime : 0;
        if (elapsed == 0) return;
        uint256 reward  = REWARD_PER_SEC * elapsed;
        if (reward > rewardReserve) reward = rewardReserve;
        if (reward == 0) { lastRewardTime = block.timestamp; return; }
        accRewardPerShare      += ML.mulDiv(reward, WAD, tbe);
        rewardReserve          -= reward;
        totalRewardDistributed += reward;
        lastRewardTime          = block.timestamp;
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
        uint256 elapsed = block.timestamp - lastInterestTime;
        if (elapsed == 0) return;
        lastInterestTime = block.timestamp;
        uint256 debtNow = totalDebt;
        if (debtNow == 0) return;

        uint256 delta = ML.mulDivSafe(ML.mulDivSafe(WAD, _interestRate(), 10_000), elapsed, SECONDS_PER_YEAR);
        if (delta == 0) return;
        // Checked on purpose: a wrapped accumulator would silently mis-price every outstanding
        // position, which is strictly worse than reverting. Reaching uint256 max here needs on the
        // order of 1e32 accruals, so this is unreachable in practice.
        accInterestPerDebt += delta;

        // The slice of interest the whole book generated over `elapsed`, settled NOW against the
        // denominators that existed NOW. Distribution and collection move together, so the ledger
        // never claims more than it holds:
        //     Δowed = −slice + reserveCut + toPool = 0,   Δbalance = 0
        uint256 slice = ML.mulDivSafe(debtNow, delta, WAD);
        if (slice == 0) return;
        if (slice > totalStaked) slice = totalStaked;
        totalStaked -= slice;

        uint256 reserveCut = ML.mulDiv(slice, RESERVE_FACTOR_BPS, 10_000);
        uint256 toPool     = slice - reserveCut;
        protocolReserve   += reserveCut;
        if (toPool > 0) {
            if (totalBoostedPure > 0) {
                accPureYieldPerShare   += ML.mulDiv(toPool, WAD, totalBoostedPure);
                totalRewardDistributed += toPool;
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
            unchecked { totalUncollectedInterest += (interest - u.staked); }
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

    /// @dev THE sole writer of the boosted totals. Plain checked subtraction: the global total
    ///      is exactly the sum of all tracked contributions, so it is always >= this user's
    ///      tracked value; an underflow would signal drift and (correctly) revert.
    function _applyBoost(UserInfo storage u, uint256 newBE, uint256 newBP) internal {
        totalBoostedEffective = totalBoostedEffective - u.trackedBoostedEffective + newBE;
        totalBoostedPure      = totalBoostedPure      - u.trackedBoostedPure      + newBP;
        u.trackedBoostedEffective = newBE;
        u.trackedBoostedPure      = newBP;
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
        if (totalStaked == 0) return RATE_R0;
        uint256 util = ML.mulDiv(totalDebt, WAD, totalStaked);
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
        uint256 ledgerNet = ledgerSum > totalDebt ? ledgerSum - totalDebt : 0;
        uint256 acc = totalRewardDistributed > totalRewardsPaid ? totalRewardDistributed - totalRewardsPaid : 0;
        owed_ = ledgerNet + acc;
        owed_ = owed_ > totalBadDebt ? owed_ - totalBadDebt : 0;   // recorded losses are netted out
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
        r.surplus             = bal > o ? bal - o : 0;
        r.deficit             = o > bal ? o - bal : 0;
        r.solvent             = bal + CONSERVATION_DUST >= o;
        r.collateralRatioWad  = o == 0 ? type(uint256).max : ML.mulDiv(bal, WAD, o);
        r.totalStaked         = totalStaked;
        r.totalDebt           = totalDebt;
        r.rewardReserve       = rewardReserve;
        r.protocolReserve     = protocolReserve;
        r.pendingDistribution = totalRewardDistributed > totalRewardsPaid
            ? totalRewardDistributed - totalRewardsPaid : 0;
        r.totalBadDebt              = totalBadDebt;
        r.totalUncollectedInterest  = totalUncollectedInterest;
    }

    /// @notice Full 5-equation diagnostic for off-chain monitors. bit0 mirrors the on-chain
    ///         guard; bit1 (Solvency) is a SOFT signal (a position may be transiently unhealthy
    ///         pre-liquidation) and is intentionally NOT part of the revert guard.
    ///   bit0 Conservation  bit1 Solvency  bit2 EmissionCap  bit3 Monotonicity  bit4 BoostBounded
    function auditInvariants() external view returns (uint8 violations) {
        if (_hardBreach()) violations |= 1 << 0;
        if (totalStaked > 0 && totalDebt * 100 > totalStaked * LIQ_THRESHOLD) violations |= 1 << 1;
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
        return u.staked > u.debt ? u.staked - u.debt : 0;
    }
    function _ltvCap(UserInfo storage u) internal view returns (uint256) {
        return ML.mulDiv(_effective(u), MAX_LTV, 100);
    }
    function _health(UserInfo storage u) internal view returns (uint256) {
        if (u.staked == 0 || u.debt == 0) return WAD;
        if (u.debt >= u.staked)           return 0;
        return ML.mulDiv(u.staked - u.debt, WAD, u.staked);
    }

    function effectiveStakeOf(address user_) external view returns (uint256) {
        return _effective(_users[user_]);
    }
    function totalEffectiveStaked() external view returns (uint256) {
        return totalStaked > totalDebt ? totalStaked - totalDebt : 0;
    }
    function healthFactor(address user_) external view returns (uint256) {
        return _health(_users[user_]);
    }
    function _daysToLiqInternal(UserInfo storage u) internal view returns (uint256) {
        if (u.debt == 0 || u.staked == 0)             return type(uint256).max;
        if (u.debt * 100 >= u.staked * LIQ_THRESHOLD) return 0;
        uint256 stakeAtLiq = ML.mulDiv(u.debt, 100, LIQ_THRESHOLD) + 1;
        if (u.staked <= stakeAtLiq) return 0;
        uint256 daily = ML.mulDivSafe(ML.mulDivSafe(u.debt, _interestRate(), 10_000), 1 days, SECONDS_PER_YEAR);
        return daily == 0 ? type(uint256).max : (u.staked - stakeAtLiq) / daily;
    }
    function daysToLiquidation(address user_) external view returns (uint256) { return _daysToLiqInternal(_users[user_]); }
    function currentInterestRateBps() external view returns (uint256) { return _interestRate(); }
    function utilizationRate() external view returns (uint256) {
        if (totalStaked == 0) return 0;
        return ML.mulDiv(totalDebt, WAD, totalStaked);
    }
    function maxBorrowOf(address user_) external view returns (uint256) {
        UserInfo storage u = _users[user_];
        uint256 cap = _ltvCap(u);
        return cap > u.debt ? cap - u.debt : 0;
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
    ///         min(MAX_LOCK_DAYS, days remaining until the 7-year emission end).
    function maxLockDaysAvailable() public view returns (uint256) {
        if (block.timestamp >= emissionEnd) return 0;
        uint256 d = (emissionEnd - block.timestamp) / 1 days;
        if (d > MAX_LOCK_DAYS) d = MAX_LOCK_DAYS;
        return d;
    }
    function emissionProgress() external view returns (uint256) {
        if (block.timestamp >= emissionEnd) return WAD;
        return ML.mulDiv(block.timestamp - emissionStart, WAD, EMISSION_PERIOD);
    }
    function timeSinceEmissionStart() external view returns (uint256) {
        return block.timestamp >= emissionStart ? block.timestamp - emissionStart : 0;
    }
    function timeUntilEmissionEnd() external view returns (uint256) {
        return block.timestamp < emissionEnd ? emissionEnd - block.timestamp : 0;
    }
    function timeUntilUnlock(address user_) external view returns (uint256) {
        UserInfo storage u = _users[user_];
        if (u.lockDays == 0) return 0;
        return block.timestamp < u.unlockTime ? uint256(u.unlockTime) - block.timestamp : 0;
    }
    /// @notice Indicative pure-staker APR (bps) for a given lock duration, from current interest flow.
    function pureStakerApr(uint256 lockDays_) external view returns (uint256 aprBps) {
        if (totalBoostedPure == 0) return 0;
        uint256 rate     = _interestRate();
        uint256 share    = ML.mulDiv(totalDebt, boostByDays(lockDays_), totalBoostedPure);
        uint256 grossBps = ML.mulDiv(rate, share, WAD);
        aprBps = ML.mulDiv(grossBps, 10_000 - RESERVE_FACTOR_BPS, 10_000);
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
        uint256 elapsed = t > lastRewardTime ? t - lastRewardTime : 0;
        if (elapsed > 0 && totalBoostedEffective >= MIN_EMISSION_WEIGHT) {
            uint256 r = REWARD_PER_SEC * elapsed;
            if (r > rewardReserve) r = rewardReserve;
            acc += ML.mulDiv(r, WAD, totalBoostedEffective);
        }
        uint256 g = ML.mulDiv(u.trackedBoostedEffective, acc, WAD);
        return g > u.rewardDebt ? g - u.rewardDebt : 0;
    }

    function _pendingPure(UserInfo storage u) internal view returns (uint256) {
        if (u.trackedBoostedPure == 0) return 0;
        uint256 acc = accPureYieldPerShare;
        uint256 elapsed = block.timestamp - lastInterestTime;
        if (elapsed > 0 && totalDebt > 0 && totalBoostedPure > 0) {
            uint256 d = ML.mulDivSafe(ML.mulDivSafe(WAD, _interestRate(), 10_000), elapsed, SECONDS_PER_YEAR);
            uint256 slice = ML.mulDivSafe(totalDebt, d, WAD);
            if (slice > totalStaked) slice = totalStaked;
            uint256 toPool = slice - ML.mulDiv(slice, RESERVE_FACTOR_BPS, 10_000);
            if (toPool > 0) acc += ML.mulDiv(toPool, WAD, totalBoostedPure);
        }
        uint256 gross = ML.mulDiv(u.trackedBoostedPure, acc, WAD);
        return gross > u.pureYieldDebt ? gross - u.pureYieldDebt : 0;
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
        maxBorrowAvailable = cap > u.debt ? cap - u.debt : 0;
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
        utilizationWad = totalStaked == 0 ? 0 : ML.mulDiv(totalDebt, WAD, totalStaked);
        annualRateBps = _interestRate();
        rewardReserve_ = rewardReserve; protocolReserve_ = protocolReserve;
        emissionStart_ = emissionStart; emissionEnd_ = emissionEnd; rewardPerSec = REWARD_PER_SEC;
        totalLiquidations_ = totalLiquidations; totalBadDebt_ = totalBadDebt;
        totalInterestAccruedGlobal_ = totalInterestAccruedGlobal; owed_ = _owed();
        maxDaysNow = maxLockDaysAvailable();
    }
    function simulateRate(uint256 utilizationWad_) external pure returns (uint256 rateBps) {
        if (utilizationWad_ > WAD) utilizationWad_ = WAD;
        if (utilizationWad_ <= RATE_UK) rateBps = RATE_R0 + ML.mulDiv(utilizationWad_, RATE_S1, WAD);
        else                            rateBps = RATE_RK + ML.mulDiv(utilizationWad_ - RATE_UK, RATE_S2, WAD);
    }
}
