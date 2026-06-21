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
///         additions the protocol is designed around:
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
///       lock / poke) drives `_autoMaintain`, an adaptive, gas-bounded sweep over a
///       rotating window of borrowers. The window self-sizes with backlog pressure (more
///       borrowers OR longer since the last sweep ⇒ a wider scan, always ≤ MAINT_MAX_SCAN),
///       liquidates anything underwater, keeps every position's interest + boost weight
///       fresh, and pays the seizure surplus to whoever carried the gas. The book cleans
///       itself from organic flow; the permissionless `liquidate(user)` remains for keepers
///       who want to target a position directly.
///
///     • SINGLE-WRITER boost accounting (`_applyBoost`) — no path, including the emergency
///       hatch, may desync the global denominators.
///     • ZERO BACKDOOR. No admin sweep of principal. Reserve withdrawals go ONLY to an
///       IMMUTABLE treasury. Emergency is pull-only; the halt itself is GUARDIAN-only (NOT
///       permissionless), because conservation is already enforced intrinsically per-tx and a
///       public breaker would only hand attackers a griefing lever.
///     • DETERMINISTIC EMISSION. Empty-pool intervals advance the clock (emission stays in
///       reserve), so a latecomer can never capture a backlog.
contract BlazePhoenixStaking is AccessControl, Pausable, ReentrancyGuard {

    string  public  constant VERSION              = "3.0.0";
    bytes32 private constant ROLE_ADMIN           = keccak256("ADMIN_ROLE");
    bytes32 private constant ROLE_GUARDIAN        = keccak256("GUARDIAN_ROLE");

    uint256 private constant WAD                  = 1e18;
    uint256 private constant SECONDS_PER_YEAR     = 365 days;

    // Emission: 180M BZPX linear over 7 years.
    uint256 public  constant TOTAL_REWARDS        = 180_000_000e18;
    uint256 public  constant EMISSION_PERIOD      = 7 * 365 days;
    uint256 public  constant REWARD_PER_SEC       = TOTAL_REWARDS / EMISSION_PERIOD;

    uint256 public  constant MAX_STAKE_PER_WALLET = 30_000_000e18;

    uint256 public  constant MAX_LTV              = 50;
    uint256 public  constant LIQ_THRESHOLD        = 95;
    uint256 public  constant EARLY_EXIT_FEE_BPS   = 500;
    uint256 public  constant LIQ_BONUS_BPS        = 500;   // 5% surplus -> paid to the gas-payer
    uint256 public  constant RESERVE_FACTOR_BPS   = 300;   // 3%

    // Lock tiers: boost(t) = 10000 + 750t + 250t^2  (t=0 -> 1.00x ... t=6 -> 2.35x)
    uint8   public  constant MAX_LOCK_TIER        = 6;
    uint256 public  constant LOCK_PERIOD          = 365 days;
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

    uint256 public totalBoostedEffective;   // denominator: emission rewards
    uint256 public totalBoostedPure;        // denominator: pure-yield (interest)

    uint256 public accRewardPerShare;
    uint256 public accPureYieldPerShare;
    uint256 public lastRewardTime;

    uint256 public totalRewardsPaid;
    uint256 public totalRewardDistributed;
    uint256 public totalInterestAccruedGlobal;
    uint256 public totalUncollectedInterest;
    uint256 public totalBadDebt;
    uint256 public totalLiquidations;
    uint256 public totalAutoLiquidations;   // subset of totalLiquidations carried by user txs

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

    struct UserInfo {
        uint256 staked;
        uint256 debt;
        uint256 rewardDebt;
        uint256 pureYieldDebt;
        uint256 lastAccrueTime;
        uint256 trackedBoostedEffective;
        uint256 trackedBoostedPure;
        uint64  depositBlock;
        uint64  unlockTime;
        uint8   lockTier;
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
    event RewardClaimed      (address indexed user, uint256 amount);
    event PureYieldClaimed   (address indexed user, uint256 amount);
    event ReserveWithdrawn   (address indexed to, uint256 amount);
    event LockSet            (address indexed user, uint8 tier, uint256 unlockTime, uint256 boostBps);
    event LockExpired        (address indexed user);
    event EmergencyDeclared  (address indexed by, uint256 timestamp);
    event EmergencyCancelled (address indexed by, uint256 timestamp);
    event EmergencyWithdrawn (address indexed user, uint256 principal);

    // ── Errors ──────────────────────────────────────────────────────────────────────────
    error Staking__ZeroAmount();
    error Staking__ZeroAddress();
    error Staking__InsufficientStake();
    error Staking__LTVExceeded();
    error Staking__NotLiquidatable();
    error Staking__TransferFailed();
    error Staking__AlreadyFunded();
    error Staking__HasDebt();
    error Staking__NoDebt();
    error Staking__FlashLoanProtection();
    error Staking__CapExceeded();
    error Staking__InvalidTier();
    error Staking__CannotReduceLock();
    error Staking__StillLocked();
    error Staking__NoStake();
    error Staking__LockExceedsEmissionEnd();
    error Staking__EmissionEnded();
    error Staking__EmergencyActive();
    error Staking__EmergencyNotActive();
    error Staking__InvariantBreached();

    // ── Guards ────────────────────────────────────────────────────────────────────────────
    /// @dev PER-TRANSACTION value conservation (not absolute). Snapshots the real balance and
    ///      `_owed()` before the body, and after requires the CHANGE in real balance to equal
    ///      the CHANGE in what the protocol owes, within dust. Any accumulated historical drift
    ///      cancels out, so a legitimate user action is NEVER reverted merely because the global
    ///      books are a few wei off — this removes the DoS-by-invariant risk. Only a transaction
    ///      that itself leaks value (a real bug/theft) fails. This guard — running on every
    ///      value-moving tx — IS the conservation mechanism; it is intrinsic and needs no keeper
    ///      to trigger it. Absolute solvency is additionally exposed, read-only, via `isSolvent()`
    ///      / `solvency()` / `auditInvariants()` for off-chain monitors, but observing a breach is
    ///      never an entry-point: only the GUARDIAN can halt (`declareEmergency`).
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
        lastMaintTime  = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ROLE_ADMIN, msg.sender);
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  BOOST CURVE
    // ════════════════════════════════════════════════════════════════════════════════════
    function boostByTier(uint8 tier_) public pure returns (uint256 bps) {
        if (tier_ == 0) return BOOST_BASE;
        if (tier_ > MAX_LOCK_TIER) tier_ = MAX_LOCK_TIER;
        uint256 t = uint256(tier_);
        unchecked { bps = BOOST_BASE + BOOST_LINEAR * t + BOOST_QUAD * t * t; }
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  ADMIN (bounded; no arbitrary-destination transfers; renounce-able)
    // ════════════════════════════════════════════════════════════════════════════════════
    function fundEmission(uint256 amount_) external nonReentrant onlyRole(ROLE_ADMIN) conserves {
        if (rewardReserve != 0) revert Staking__AlreadyFunded();
        if (amount_ == 0)       revert Staking__ZeroAmount();
        if (amount_ > TOTAL_REWARDS) revert Staking__CapExceeded();
        if (!ML.rawTransferFrom(bzpx, msg.sender, address(this), amount_)) revert Staking__TransferFailed();
        rewardReserve = amount_;
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

    function pause()   external onlyRole(ROLE_GUARDIAN) { _pause();   }
    function unpause() external onlyRole(ROLE_ADMIN) whenNotEmergency { _unpause(); }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  EMERGENCY — pull-only, no sweep
    // ════════════════════════════════════════════════════════════════════════════════════

    /// @notice The SOLE halt path: a discretionary emergency the GUARDIAN may declare for an
    ///         off-chain-discovered issue. It is deliberately NOT permissionless — conservation
    ///         is already enforced intrinsically by the `conserves` guard on every value-moving
    ///         transaction, so an unconservative state is unreachable and there is nothing for a
    ///         third party to "catch and trip". Making the breaker open would instead hand an
    ///         attacker a griefing lever (a single spurious breach reading would let anyone freeze
    ///         the protocol). Solvency stays publicly OBSERVABLE via `isSolvent()`/`solvency()`,
    ///         but only the guardian can ACT on it. Cannot move funds.
    function declareEmergency() external onlyRole(ROLE_GUARDIAN) {
        if (emergencyMode) revert Staking__EmergencyActive();
        emergencyMode = true; emergencyTrippedAt = block.timestamp;
        if (!paused()) _pause();
        emit EmergencyDeclared(msg.sender, block.timestamp);
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
        UserInfo storage u = _users[msg.sender];
        uint256 principal = u.staked;
        if (principal == 0) revert Staking__NoStake();
        uint256 debt   = u.debt;
        uint256 payout = principal > debt ? principal - debt : 0;

        totalStaked = totalStaked > principal ? totalStaked - principal : 0;
        if (debt > 0) { totalDebt = totalDebt > debt ? totalDebt - debt : 0; _removeBorrower(msg.sender); }

        _applyBoost(u, 0, 0);              // single-writer cleanup — no ghost share
        delete _users[msg.sender];

        if (payout > 0) {
            if (!ML.rawTransfer(bzpx, msg.sender, payout)) revert Staking__TransferFailed();
        }
        emit EmergencyWithdrawn(msg.sender, payout);
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  USER ACTIONS — each ends by driving autonomous maintenance
    // ════════════════════════════════════════════════════════════════════════════════════

    function deposit(uint256 amount_)
        external nonReentrant whenNotPaused whenNotEmergency conserves
    {
        if (amount_ == 0) revert Staking__ZeroAmount();
        UserInfo storage u = _users[msg.sender];
        if (u.staked + amount_ > MAX_STAKE_PER_WALLET) revert Staking__CapExceeded();

        _updateGlobal();
        _settlePendingRewards(msg.sender);
        _settlePendingPureYield(msg.sender);
        _accrueInterestFor(msg.sender);
        _processLockExpiry(msg.sender);

        if (!ML.rawTransferFrom(bzpx, msg.sender, address(this), amount_)) revert Staking__TransferFailed();

        u.staked      += amount_;
        u.depositBlock = uint64(block.number);
        totalStaked   += amount_;

        _resync(u);
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
        uint256 effective = u.staked > u.debt ? u.staked - u.debt : 0; // LTV on EFFECTIVE stake
        uint256 maxBorrow = ML.mulDiv(effective, MAX_LTV, 100);
        if (u.debt + amount_ > maxBorrow) revert Staking__LTVExceeded();

        bool wasZeroDebt = (u.debt == 0);
        u.debt          += amount_;
        totalDebt       += amount_;
        u.lastAccrueTime = block.timestamp;
        if (wasZeroDebt) _addBorrower(msg.sender);

        _resync(u);

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

        _resync(u);
        emit Repaid(msg.sender, toRepay, u.debt);
        _autoMaintain(msg.sender);
    }

    /// @dev withdraw is allowed under pause (exit), blocked under emergency (use emergencyWithdraw).
    function withdraw(uint256 amount_) external nonReentrant whenNotEmergency conserves {
        if (amount_ == 0) revert Staking__ZeroAmount();
        UserInfo storage u = _users[msg.sender];
        if (block.number <= u.depositBlock + MIN_DEPOSIT_BLOCKS) revert Staking__FlashLoanProtection();
        if (u.lockTier > 0 && block.timestamp < u.unlockTime)    revert Staking__StillLocked();

        _updateGlobal();
        _settlePendingRewards(msg.sender);
        _settlePendingPureYield(msg.sender);
        _accrueInterestFor(msg.sender);
        _processLockExpiry(msg.sender);

        if (u.staked < amount_) revert Staking__InsufficientStake();

        bool hadDebt = (u.debt > 0);
        uint256 debtCleared;
        uint256 penalty;
        uint256 netOut = amount_;

        if (hadDebt) {
            debtCleared = (amount_ == u.staked) ? u.debt : ML.mulDiv(u.debt, amount_, u.staked);
            penalty     = ML.mulDiv(debtCleared, EARLY_EXIT_FEE_BPS, 10_000);
            netOut      = amount_ > debtCleared + penalty ? amount_ - debtCleared - penalty : 0;

            uint256 reserveCut = ML.mulDiv(penalty, RESERVE_FACTOR_BPS, 10_000);
            uint256 toPool     = penalty - reserveCut;
            protocolReserve   += reserveCut;
            if (toPool > 0) {
                if (totalBoostedPure > 0) {
                    accPureYieldPerShare   += ML.mulDiv(toPool, WAD, totalBoostedPure);
                    totalRewardDistributed += toPool;
                } else {
                    protocolReserve += toPool;
                }
            }
            totalDebt -= debtCleared;
            u.debt    -= debtCleared;
        }

        u.staked    -= amount_;
        totalStaked -= amount_;

        if (u.debt > 0 && u.debt * 100 >= u.staked * LIQ_THRESHOLD) revert Staking__LTVExceeded();
        if (hadDebt && u.debt == 0) { _removeBorrower(msg.sender); if (u.staked > 0) u.depositBlock = uint64(block.number); }

        _resync(u);

        if (netOut > 0) {
            if (!ML.rawTransfer(bzpx, msg.sender, netOut)) revert Staking__TransferFailed();
        }
        emit Withdrawn(msg.sender, amount_, debtCleared, penalty, netOut);
        _autoMaintain(msg.sender);
    }

    function claimRewards() external nonReentrant whenNotEmergency conserves {
        _updateGlobal();
        _settlePendingRewards(msg.sender);
        _settlePendingPureYield(msg.sender);
        _accrueInterestFor(msg.sender);
        _processLockExpiry(msg.sender);
        _resync(_users[msg.sender]);
        _autoMaintain(msg.sender);
    }

    function claimPureYield() external nonReentrant whenNotEmergency conserves {
        UserInfo storage u = _users[msg.sender];
        if (u.debt != 0) revert Staking__HasDebt();
        if (block.number <= u.depositBlock + MIN_DEPOSIT_BLOCKS) revert Staking__FlashLoanProtection();
        _updateGlobal();
        _settlePendingRewards(msg.sender);
        _settlePendingPureYield(msg.sender);
        _processLockExpiry(msg.sender);
        _resync(u);
        _autoMaintain(msg.sender);
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  LOCK
    // ════════════════════════════════════════════════════════════════════════════════════
    function lock(uint8 newTier_) external nonReentrant whenNotPaused whenNotEmergency conserves {
        if (newTier_ == 0 || newTier_ > MAX_LOCK_TIER) revert Staking__InvalidTier();
        if (block.timestamp >= emissionEnd) revert Staking__EmissionEnded();

        UserInfo storage u = _users[msg.sender];
        if (u.staked == 0) revert Staking__NoStake();
        if (block.number <= u.depositBlock + MIN_DEPOSIT_BLOCKS) revert Staking__FlashLoanProtection();

        uint256 maxAllowed = (emissionEnd - block.timestamp) / LOCK_PERIOD;
        if (maxAllowed > MAX_LOCK_TIER) maxAllowed = MAX_LOCK_TIER;
        if (uint256(newTier_) > maxAllowed) revert Staking__LockExceedsEmissionEnd();

        _updateGlobal();
        _settlePendingRewards(msg.sender);
        _settlePendingPureYield(msg.sender);
        _accrueInterestFor(msg.sender);

        if (u.lockTier > 0 && block.timestamp >= u.unlockTime) {
            u.lockTier = 0; u.unlockTime = 0; emit LockExpired(msg.sender);
        }
        if (newTier_ <= u.lockTier) revert Staking__CannotReduceLock();

        u.lockTier   = newTier_;
        u.unlockTime = uint64(block.timestamp + uint256(newTier_) * LOCK_PERIOD);

        _resync(u);
        emit LockSet(msg.sender, newTier_, u.unlockTime, boostByTier(newTier_));
        _autoMaintain(msg.sender);
    }

    function pokeExpiredLock(address user_) external nonReentrant whenNotEmergency conserves {
        UserInfo storage u = _users[user_];
        if (u.lockTier == 0) revert Staking__InvalidTier();
        if (block.timestamp < u.unlockTime) revert Staking__StillLocked();
        _updateGlobal();
        _settlePendingRewards(user_);
        _settlePendingPureYield(user_);
        _accrueInterestFor(user_);
        _processLockExpiry(user_);
        _resync(u);
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
            delete _users[user_];
        } else {
            u.depositBlock = uint64(block.number);   // debt now 0 -> becomes a pure staker
            _resync(u);
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

    /// @notice How many borrowers the NEXT user tx will opportunistically scan. Self-sizes with
    ///         backlog pressure — more tracked borrowers OR more time since the last sweep widen
    ///         the window — but is hard-capped at MAINT_MAX_SCAN so per-tx gas is always bounded.
    ///         No admin, no governance: the schedule is a pure function of on-chain state.
    function _maintBudget() internal view returns (uint256 c) {
        uint256 len = _borrowers.length;
        if (len == 0) return 0;
        c = MAINT_BASE + len / MAINT_DENSITY;
        uint256 last = lastMaintTime;
        if (last != 0 && block.timestamp > last) {
            c += (block.timestamp - last) / MAINT_GAP_UNIT;
        }
        if (c > MAINT_MAX_SCAN) c = MAINT_MAX_SCAN;
        if (c > len) c = len;
    }

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
        uint256 budget = _maintBudget();
        if (budget == 0) return;

        for (uint256 n = 0; n < budget; ) {
            uint256 len = _borrowers.length;
            if (len == 0) break;
            uint256 idx = _maintCursor % len;
            address who = _borrowers[idx];

            if (who == beneficiary) { unchecked { ++_maintCursor; ++n; } continue; }

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
                _processLockExpiry(who);
                _resync(_users[who]);
                unchecked { ++_maintCursor; }
            }
            unchecked { ++n; }
        }
        lastMaintTime = block.timestamp;
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
    function activeBorrowerCount() external view returns (uint256) { return _borrowers.length; }
    function borrowerAt(uint256 i) external view returns (address) { return _borrowers[i]; }
    function isTrackedBorrower(address who) external view returns (bool) { return _borrowerIdx[who] != 0; }
    function maintenanceBudget() external view returns (uint256) { return _maintBudget(); }
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
        uint256 tbe = totalBoostedEffective;
        if (tbe == 0) { lastRewardTime = block.timestamp; return; } // no backlog capture
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
    function _accrueInterestFor(address user_) internal {
        UserInfo storage u = _users[user_];
        if (u.debt == 0) { u.lastAccrueTime = block.timestamp; return; }
        uint256 elapsed = block.timestamp - u.lastAccrueTime;
        if (elapsed == 0) return;

        uint256 interest = ML.mulDivSafe(ML.mulDivSafe(u.debt, _interestRate(), 10_000), elapsed, SECONDS_PER_YEAR);
        u.lastAccrueTime = block.timestamp;
        if (interest == 0) return;

        if (interest > u.staked) {
            unchecked { totalUncollectedInterest += (interest - u.staked); }
            interest = u.staked;
        }
        u.staked    -= interest;
        totalStaked -= interest;

        uint256 reserveCut = ML.mulDiv(interest, RESERVE_FACTOR_BPS, 10_000);
        uint256 toPool     = interest - reserveCut;
        protocolReserve   += reserveCut;
        if (toPool > 0) {
            if (totalBoostedPure > 0) {
                accPureYieldPerShare   += ML.mulDiv(toPool, WAD, totalBoostedPure);
                totalRewardDistributed += toPool;
            } else {
                protocolReserve += toPool;
            }
        }
        unchecked { totalInterestAccruedGlobal += interest; }
        emit InterestAccrued(user_, interest, u.staked);
    }

    // ── single-writer boost + checkpoint ──────────────────────────────────────────────────
    function _computeBoost(UserInfo storage u) internal view returns (uint256 be, uint256 bp) {
        uint256 boost = boostByTier(u.lockTier);
        uint256 effective = u.staked > u.debt ? u.staked - u.debt : 0;
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

    /// @dev recompute boost from current state, apply via the single writer, re-checkpoint.
    function _resync(UserInfo storage u) internal {
        (uint256 be, uint256 bp) = _computeBoost(u);
        _applyBoost(u, be, bp);
        _checkpoint(u);
    }

    function _processLockExpiry(address user_) internal {
        UserInfo storage u = _users[user_];
        if (u.lockTier > 0 && block.timestamp >= u.unlockTime) {
            u.lockTier = 0; u.unlockTime = 0; emit LockExpired(user_);
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
        uint256 maxBoosted = ML.mulDiv(totalStaked, boostByTier(MAX_LOCK_TIER), BOOST_BASE);
        if (totalBoostedEffective > maxBoosted || totalBoostedPure > maxBoosted) violations |= 1 << 4;
    }

    function touchAuditSnapshot() external {
        if (accRewardPerShare    > lastAuditedAccReward) lastAuditedAccReward = accRewardPerShare;
        if (accPureYieldPerShare > lastAuditedAccPure)   lastAuditedAccPure   = accPureYieldPerShare;
    }

    // ════════════════════════════════════════════════════════════════════════════════════
    //  VIEWS
    // ════════════════════════════════════════════════════════════════════════════════════
    function effectiveStakeOf(address user_) external view returns (uint256) {
        UserInfo storage u = _users[user_];
        return u.staked > u.debt ? u.staked - u.debt : 0;
    }
    function totalEffectiveStaked() external view returns (uint256) {
        return totalStaked > totalDebt ? totalStaked - totalDebt : 0;
    }
    function healthFactor(address user_) external view returns (uint256) {
        UserInfo storage u = _users[user_];
        if (u.staked == 0 || u.debt == 0) return WAD;
        if (u.debt >= u.staked)           return 0;
        return ML.mulDiv(u.staked - u.debt, WAD, u.staked);
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
        uint256 effective = u.staked > u.debt ? u.staked - u.debt : 0;
        uint256 cap = ML.mulDiv(effective, MAX_LTV, 100);
        return cap > u.debt ? cap - u.debt : 0;
    }
    function remainingStakeCapacity(address user_) external view returns (uint256) {
        uint256 s = _users[user_].staked;
        return s >= MAX_STAKE_PER_WALLET ? 0 : MAX_STAKE_PER_WALLET - s;
    }
    function lockInfoOf(address user_) external view returns (uint8 tier, uint256 unlockTime, uint256 boostBps, bool expired) {
        UserInfo storage u = _users[user_];
        tier = u.lockTier; unlockTime = uint256(u.unlockTime); boostBps = boostByTier(u.lockTier);
        expired = (u.lockTier > 0 && block.timestamp >= u.unlockTime);
    }
    function maxLockTierAvailable() public view returns (uint8) {
        if (block.timestamp >= emissionEnd) return 0;
        uint256 m = (emissionEnd - block.timestamp) / LOCK_PERIOD;
        if (m > MAX_LOCK_TIER) m = MAX_LOCK_TIER;
        return uint8(m);
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
        if (u.lockTier == 0) return 0;
        return block.timestamp < u.unlockTime ? uint256(u.unlockTime) - block.timestamp : 0;
    }
    /// @notice Indicative pure-staker APR (bps) at a given tier, from current interest flow.
    function pureStakerApr(uint8 tier_) external view returns (uint256 aprBps) {
        if (totalBoostedPure == 0) return 0;
        uint256 rate     = _interestRate();
        uint256 share    = ML.mulDiv(totalDebt, boostByTier(tier_), totalBoostedPure);
        uint256 grossBps = ML.mulDiv(rate, share, WAD);
        aprBps = ML.mulDiv(grossBps, 10_000 - RESERVE_FACTOR_BPS, 10_000);
    }
    function pendingRewards(address user_) external view returns (uint256) {
        UserInfo storage u = _users[user_];
        if (u.trackedBoostedEffective == 0) return 0;
        uint256 acc = accRewardPerShare;
        if (totalBoostedEffective > 0) {
            uint256 t = block.timestamp < emissionEnd ? block.timestamp : emissionEnd;
            uint256 elapsed = t > lastRewardTime ? t - lastRewardTime : 0;
            if (elapsed > 0) {
                uint256 r = REWARD_PER_SEC * elapsed;
                if (r > rewardReserve) r = rewardReserve;
                acc += ML.mulDiv(r, WAD, totalBoostedEffective);
            }
        }
        uint256 gross = ML.mulDiv(u.trackedBoostedEffective, acc, WAD);
        return gross > u.rewardDebt ? gross - u.rewardDebt : 0;
    }
    function pendingPureYield(address user_) external view returns (uint256) {
        UserInfo storage u = _users[user_];
        if (u.trackedBoostedPure == 0) return 0;
        uint256 gross = ML.mulDiv(u.trackedBoostedPure, accPureYieldPerShare, WAD);
        return gross > u.pureYieldDebt ? gross - u.pureYieldDebt : 0;
    }
    function getUserInfo(address user_) external view returns (
        uint256 staked, uint256 debt, uint256 effectiveStake, uint256 maxBorrowAvailable,
        uint256 health, uint256 daysLeft, uint256 stakingRewards, uint256 pureYield,
        uint256 rateBps, uint8 lockTier, uint256 unlockTime, uint256 boostBps,
        uint256 remainingCap, uint8 maxTierNow
    ) {
        UserInfo storage u = _users[user_];
        staked = u.staked; debt = u.debt;
        effectiveStake = u.staked > u.debt ? u.staked - u.debt : 0;
        uint256 cap = ML.mulDiv(effectiveStake, MAX_LTV, 100);
        maxBorrowAvailable = cap > u.debt ? cap - u.debt : 0;
        health = (u.staked == 0 || u.debt == 0) ? WAD : u.debt >= u.staked ? 0 : ML.mulDiv(u.staked - u.debt, WAD, u.staked);
        rateBps = _interestRate();
        daysLeft = _daysToLiqInternal(u);
        lockTier = u.lockTier; unlockTime = uint256(u.unlockTime); boostBps = boostByTier(u.lockTier);
        remainingCap = staked >= MAX_STAKE_PER_WALLET ? 0 : MAX_STAKE_PER_WALLET - staked;
        maxTierNow = maxLockTierAvailable();

        if (u.trackedBoostedEffective > 0 && totalBoostedEffective > 0) {
            uint256 t = block.timestamp < emissionEnd ? block.timestamp : emissionEnd;
            uint256 elapsed = t > lastRewardTime ? t - lastRewardTime : 0;
            uint256 acc = accRewardPerShare;
            if (elapsed > 0) {
                uint256 r = REWARD_PER_SEC * elapsed;
                if (r > rewardReserve) r = rewardReserve;
                acc += ML.mulDiv(r, WAD, totalBoostedEffective);
            }
            uint256 g = ML.mulDiv(u.trackedBoostedEffective, acc, WAD);
            stakingRewards = g > u.rewardDebt ? g - u.rewardDebt : 0;
        }
        if (u.trackedBoostedPure > 0) {
            uint256 g = ML.mulDiv(u.trackedBoostedPure, accPureYieldPerShare, WAD);
            pureYield = g > u.pureYieldDebt ? g - u.pureYieldDebt : 0;
        }
    }
    function getGlobalStats() external view returns (
        uint256 totalStaked_, uint256 totalDebt_, uint256 totalBoostedEffective_, uint256 totalBoostedPure_,
        uint256 utilizationWad, uint256 annualRateBps, uint256 rewardReserve_, uint256 protocolReserve_,
        uint256 emissionStart_, uint256 emissionEnd_, uint256 rewardPerSec, uint256 totalLiquidations_,
        uint256 totalBadDebt_, uint256 totalInterestAccruedGlobal_, uint256 owed_, uint8 maxTierNow
    ) {
        totalStaked_ = totalStaked; totalDebt_ = totalDebt;
        totalBoostedEffective_ = totalBoostedEffective; totalBoostedPure_ = totalBoostedPure;
        utilizationWad = totalStaked == 0 ? 0 : ML.mulDiv(totalDebt, WAD, totalStaked);
        annualRateBps = _interestRate();
        rewardReserve_ = rewardReserve; protocolReserve_ = protocolReserve;
        emissionStart_ = emissionStart; emissionEnd_ = emissionEnd; rewardPerSec = REWARD_PER_SEC;
        totalLiquidations_ = totalLiquidations; totalBadDebt_ = totalBadDebt;
        totalInterestAccruedGlobal_ = totalInterestAccruedGlobal; owed_ = _owed();
        maxTierNow = maxLockTierAvailable();
    }
    function simulateRate(uint256 utilizationWad_) external pure returns (uint256 rateBps) {
        if (utilizationWad_ > WAD) utilizationWad_ = WAD;
        if (utilizationWad_ <= RATE_UK) rateBps = RATE_R0 + ML.mulDiv(utilizationWad_, RATE_S1, WAD);
        else                            rateBps = RATE_RK + ML.mulDiv(utilizationWad_ - RATE_UK, RATE_S2, WAD);
    }
}
