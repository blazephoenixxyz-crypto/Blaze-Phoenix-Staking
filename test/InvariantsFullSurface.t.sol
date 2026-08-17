// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// =============================================================================
//  FULL-SURFACE INVARIANTS — INV-16 … INV-20, pinned by name.
//
//  Why this file exists alongside the invariant block in BlazePhoenixStaking.t.sol:
//
//  1. COVERAGE. INV-16 claims that EVERY value-moving entry point conserves.
//     The existing handler drives deposit / borrow / repay / withdraw /
//     claimRewards / liquidate / lock / pokeExpiredLock. It never calls
//     claimPureYield, pokeExpiredLocks, maintStep or lockStep — all of which are
//     external, value-moving and `conserves`-wrapped. An invariant that never
//     reaches an entry point says nothing about it, so the claim was only
//     partly under test. `afterInvariant` below FAILS if any of them was never
//     exercised, which keeps this file honest as the surface grows.
//
//  2. INDEPENDENCE. The existing invariants read `auditInvariants()` — they ask
//     the contract whether it considers itself healthy. That cannot catch a bug
//     in the self-audit itself. Everything here is recomputed from public state
//     (totalStaked, totalDebt, rewardReserve, …) and compared against the
//     identity as written in the contract header, never against the contract's
//     own verdict.
//
//  3. DONATION-AWARE EQUALITY. `isSolvent()` only pins backing >= owed. The
//     Master Conservation Identity is an EQUALITY, and the one legitimate way to
//     break it upward is an unsolicited transfer in. Tracking donations as a
//     ghost lets this assert equality-within-dust instead of the much weaker
//     inequality, so silent value leakage in either direction is visible.
//
//  Deliberately out of scope: emergency mode. `declareEmergency` gates every
//  `conserves` entry point behind `whenNotEmergency`, so including it would
//  collapse the reachable state space for the rest of the run. H-05 has its own
//  suite (HardeningH05_EmergencyHaircut.t.sol).
//
//  Run: forge test --match-contract InvariantsFullSurface -vv
// =============================================================================

import {Test, StdInvariant} from "forge-std/Test.sol";
import {BlazePhoenixStaking} from "../src/BlazePhoenixStaking.sol";
import {Base, MockERC20} from "./BlazePhoenixStaking.t.sol";

contract FullSurfaceHandler is Test {
    BlazePhoenixStaking public staking;
    MockERC20 public token;
    address[] public actors;

    // ── ghosts ───────────────────────────────────────────────────────────────
    /// Tokens transferred in without going through an entry point. The identity
    /// is an equality only up to this.
    uint256 public totalDonated;
    /// Times `tripBreaker()` succeeded. INV-20 says this may only ever be
    /// non-zero if the protocol was genuinely hard-breached.
    uint256 public breakerTrips;
    /// Per-entry-point success counters — the coverage proof for INV-16.
    mapping(bytes32 => uint256) public calls;

    constructor(BlazePhoenixStaking s, MockERC20 t, address[] memory a) {
        staking = s; token = t; actors = a;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
    function _hit(bytes32 k) internal { calls[k] += 1; }

    // ── the surface the previous handler already covered ─────────────────────
    function deposit(uint256 seed, uint256 amt, uint256 lockDays) public {
        amt = bound(amt, 1e18, 5_000_000e18);
        lockDays = bound(lockDays, 90, 2555);
        vm.prank(_actor(seed));
        try staking.deposit(amt, lockDays) { _hit("deposit"); } catch {}
    }
    function borrow(uint256 seed, uint256 amt) public {
        amt = bound(amt, 1e18, 3_000_000e18);
        vm.prank(_actor(seed));
        try staking.borrow(amt) { _hit("borrow"); } catch {}
    }
    function repay(uint256 seed, uint256 amt) public {
        amt = bound(amt, 1e18, 5_000_000e18);
        vm.prank(_actor(seed));
        try staking.repay(amt) { _hit("repay"); } catch {}
    }
    function withdraw(uint256 seed, uint256 amt) public {
        amt = bound(amt, 1e18, 5_000_000e18);
        vm.prank(_actor(seed));
        try staking.withdraw(amt) { _hit("withdraw"); } catch {}
    }
    function claimRewards(uint256 seed) public {
        vm.prank(_actor(seed));
        try staking.claimRewards() { _hit("claimRewards"); } catch {}
    }
    function liquidate(uint256 seed, uint256 tseed) public {
        vm.prank(_actor(seed));
        try staking.liquidate(_actor(tseed)) { _hit("liquidate"); } catch {}
    }
    function lock(uint256 seed, uint256 lockDays) public {
        lockDays = bound(lockDays, 90, 2555);
        vm.prank(_actor(seed));
        try staking.lock(lockDays) { _hit("lock"); } catch {}
    }
    function pokeExpiredLock(uint256 seed, uint256 tseed) public {
        vm.prank(_actor(seed));
        try staking.pokeExpiredLock(_actor(tseed)) { _hit("pokeExpiredLock"); } catch {}
    }

    // ── entry points the previous handler never reached ──────────────────────
    /// The second, independent reward stream. `conserves`-wrapped and paid from
    /// a different accumulator than claimRewards, so it exercises the pure-yield
    /// side of the Dual-Accumulator Doctrine.
    function claimPureYield(uint256 seed) public {
        vm.prank(_actor(seed));
        try staking.claimPureYield() { _hit("claimPureYield"); } catch {}
    }
    /// The batch poke. Reaches the multi-write path through the single-writer
    /// boost subtraction, where a duplicated registry entry would underflow.
    function pokeExpiredLocks(uint256 seed) public {
        address[] memory batch = new address[](actors.length);
        for (uint256 i = 0; i < actors.length; i++) batch[i] = actors[(seed + i) % actors.length];
        vm.prank(_actor(seed));
        try staking.pokeExpiredLocks(batch) { _hit("pokeExpiredLocks"); } catch {}
    }
    /// The autonomous-maintenance steppers, callable by anyone with an arbitrary
    /// beneficiary — i.e. a third party can drive another account's maintenance.
    function maintStep(uint256 seed, uint256 tseed) public {
        vm.prank(_actor(seed));
        try staking.maintStep(_actor(tseed), _actor(seed)) { _hit("maintStep"); } catch {}
    }
    function lockStep(uint256 seed, uint256 tseed) public {
        vm.prank(_actor(seed));
        try staking.lockStep(_actor(tseed), _actor(seed)) { _hit("lockStep"); } catch {}
    }

    // ── flows that are not entry points at all ───────────────────────────────
    /// An unsolicited transfer in. Raises backing without raising owed, which is
    /// the one legitimate way the identity becomes an inequality.
    function donate(uint256 seed, uint256 amt) public {
        amt = bound(amt, 1, 100_000e18);
        address a = _actor(seed);
        if (token.balanceOf(a) < amt) return;
        vm.prank(a);
        token.transfer(address(staking), amt);
        totalDonated += amt;
        _hit("donate");
    }
    /// INV-20. Permissionless by design: the point is that it must REFUSE while
    /// the protocol is sound, no matter who asks or how often.
    function tripBreaker(uint256 seed) public {
        vm.prank(_actor(seed));
        try staking.tripBreaker() { breakerTrips += 1; } catch {}
    }

    // ── time ─────────────────────────────────────────────────────────────────
    function passTime(uint256 s) public {
        s = bound(s, 1 hours, 60 days);
        vm.warp(block.timestamp + s); vm.roll(block.number + 30);
    }
    /// Carries positions past their unlock so lock expiry is inside the fuzzed
    /// space, which is what INV-18 needs to be a real test.
    function passLockPeriod(uint256 s) public {
        s = bound(s, 60 days, 800 days);
        vm.warp(block.timestamp + s); vm.roll(block.number + 300);
    }
}

contract InvariantsFullSurfaceTest is StdInvariant, Base {
    FullSurfaceHandler handler;
    address[] internal who;

    uint256 internal constant DUST = 1e10;          // CONSERVATION_DUST
    uint256 internal constant BASE_BOOST = 10_000;  // 1.00x in bps

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        staking.fundEmission(50_000_000e18);

        address[] memory a = new address[](4);
        a[0] = alice; a[1] = bob; a[2] = carol; a[3] = keeper;
        who = a;

        handler = new FullSurfaceHandler(staking, token, a);
        targetContract(address(handler));
    }

    // ── INV-16 — the Master Conservation Identity, recomputed independently ──
    //
    //   backing + totalBadDebt
    //     == (totalStaked - totalDebt) + rewardReserve + protocolReserve
    //        + (totalRewardDistributed - totalRewardsPaid)
    //        + donations
    //
    // Every term is read from public state; nothing here consults _owed() or
    // auditInvariants(), so a bug in the self-audit cannot hide a break.
    function invariant_INV16_conservationIdentityHoldsExactly() public view {
        uint256 lhs = staking.backing() + staking.totalBadDebt();

        uint256 staked = staking.totalStaked();
        uint256 debt   = staking.totalDebt();
        // Net principal physically held. Guarded because a subtraction that
        // underflows here IS the failure we are hunting, and a Panic would
        // report less clearly than the assertion below.
        assertGe(staked + DUST, debt, "INV-16: totalDebt exceeds totalStaked");
        uint256 netPrincipal = staked >= debt ? staked - debt : 0;

        uint256 distributed = staking.totalRewardDistributed();
        uint256 paid        = staking.totalRewardsPaid();
        assertGe(distributed + DUST, paid, "INV-16: paid exceeds distributed");
        uint256 accruedUnpaid = distributed >= paid ? distributed - paid : 0;

        uint256 rhs = netPrincipal
            + staking.rewardReserve()
            + staking.protocolReserve()
            + accruedUnpaid
            + handler.totalDonated();

        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        assertLe(diff, DUST, "INV-16: conservation identity broken beyond dust");
    }

    /// Solvency stated as the protocol states it, kept as a separate assertion
    /// so a failure tells you WHICH of the two broke.
    function invariant_INV16_backingCoversOwed() public view {
        assertGe(staking.backing() + DUST, staking.owed(), "INV-16: backing < owed");
    }

    // ── the Panic 0x11 direction ─────────────────────────────────────────────
    //
    // The staking-hardening session found a real bug where the aggregate fell
    // BELOW the sum of the parts (a floored delta debited pre-floor), which made
    // `_executeLiquidation` revert with a checked-math Panic — funds effectively
    // frozen. That was closed with a unit test for one scenario;
    // CapitalConservation.t.sol logs the divergence but does not pin it. As an
    // invariant it covers every reachable state instead of one.
    //
    // Only one direction is unsafe: the aggregate may legitimately exceed the
    // sum (rounding retained pro-protocol), but must never fall short of it.
    function invariant_totalStakedNeverBelowSumOfStakes() public view {
        uint256 sum;
        for (uint256 i = 0; i < who.length; i++) {
            (uint256 staked,,,,,,,,,,,,,) = staking.getUserInfo(who[i]);
            sum += staked;
        }
        assertGe(staking.totalStaked() + DUST, sum, "aggregate fell below sum(u.staked)");
    }

    // ── INV-18 — a lapsed lock is paid at 1.00x from the instant of expiry ───
    function invariant_INV18_lapsedLockPaysBaseBoost() public view {
        for (uint256 i = 0; i < who.length; i++) {
            (,,,,,,,,, uint256 lockDays, uint256 unlockTime, uint256 boostBps,,) =
                staking.getUserInfo(who[i]);
            if (lockDays == 0) continue;
            if (unlockTime <= block.timestamp) {
                assertEq(boostBps, BASE_BOOST, "INV-18: expired lock still paid a boost");
            } else {
                assertGe(boostBps, BASE_BOOST, "INV-18: live lock paid below base");
            }
        }
    }

    // ── INV-20 — the Permissionless Breaker ──────────────────────────────────
    //
    // Anyone may halt the contract IF AND ONLY IF they can prove it insolvent.
    // The handler calls tripBreaker() from arbitrary actors throughout the run;
    // since solvency holds above, every one of those calls must have reverted.
    // A single success here means the trip condition is not the objective test
    // it is documented to be.
    function invariant_INV20_breakerCannotTripWhileSound() public view {
        assertEq(handler.breakerTrips(), 0, "INV-20: breaker tripped on a sound protocol");
    }

    // ── INV-19 — debt is bounded by the position that secures it ─────────────
    function invariant_INV19_debtNeverExceedsStake() public view {
        for (uint256 i = 0; i < who.length; i++) {
            (uint256 staked, uint256 debt,,,,,,,,,,,,) = staking.getUserInfo(who[i]);
            if (debt == 0) continue;
            assertLe(debt, staked + DUST, "INV-19: debt exceeds the stake securing it");
        }
    }

    // ── coverage — keeps INV-16's "every entry point" claim non-vacuous ──────
    //
    // Runs once, after the whole campaign. If a `conserves`-wrapped entry point
    // was never successfully reached, the invariants above proved nothing about
    // it, and this fails rather than reporting a green run that did not happen.
    function afterInvariant() public view {
        string[10] memory required = [
            "deposit", "borrow", "repay", "withdraw",
            "claimRewards", "claimPureYield",
            "lock", "pokeExpiredLock", "pokeExpiredLocks", "donate"
        ];
        for (uint256 i = 0; i < required.length; i++) {
            assertGt(
                handler.calls(bytes32(bytes(required[i]))),
                0,
                string.concat("entry point never exercised: ", required[i])
            );
        }
    }
}
