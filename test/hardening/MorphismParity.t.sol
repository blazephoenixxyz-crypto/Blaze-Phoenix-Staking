// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Base} from "../BlazePhoenixStaking.t.sol";

/// @notice MORPH-1103. Three readings that each reader used to write for itself are now one
///         primitive each, the reader being the only coordinate: the page of the locker
///         registry (`getLockers`, `expiredLockScan`), the elapsed-commitment class
///         (`lockInfoOf`, `hasStaleBoost`, `expiredLockScan`) and backing / owed
///         (`collateralRatio`, `solvency`). Each test pins the readers to one another, and the
///         elapsed class also to the processor that acts on it (`_processLockExpiry` keeps its
///         own trigger: a measured coincidence, pinned here, not fused). A reader that grows its
///         own copy again and drifts turns its test red (mutants.py, MORPH entries).
contract MorphismParityTest is Base {
    address internal dave = address(0xD4);

    /// Five lockers in registry order alice, bob, carol, keeper, dave. After the warp the
    /// 90-day commitments (alice, carol, dave) have elapsed and the 365-day ones have not.
    /// Only views run after the warp, so nothing processes the lapsed locks.
    function _mixedLockers() internal {
        _fund(dave);
        address[5] memory m = [alice, bob, carol, keeper, dave];
        uint256[5] memory d = [uint256(90), 365, 90, 365, 90];
        for (uint256 i; i < 5; ++i) {
            vm.prank(m[i]);
            staking.deposit(1_000e18, d[i]);
        }
        vm.warp(block.timestamp + 91 days);
        (address[] memory all,) = staking.getLockers(0, type(uint256).max);
        assertEq(all.length, 5, "setup: five lockers");
        for (uint256 i; i < 5; ++i) assertEq(all[i], m[i], "setup: registry order is deposit order");
    }

    /// One page, both readers: the same registry size, and `expiredLockScan` lists exactly the
    /// elapsed entries of the page `getLockers` returns, in the same order.
    function _samePage(uint256 offset, uint256 limit) internal view {
        (address[] memory page, uint256 t1) = staking.getLockers(offset, limit);
        (address[] memory users,,, uint256 t2) = staking.expiredLockScan(offset, limit);
        assertEq(t1, 5, "getLockers: registry size");
        assertEq(t2, 5, "expiredLockScan: registry size");
        uint256 want = offset >= 5 ? 0 : (limit < 5 - offset ? limit : 5 - offset);
        assertEq(page.length, want, "getLockers: the page is [offset, offset + min(limit, rest))");
        uint256 n;
        for (uint256 k; k < page.length; ++k) {
            (,,, bool expired) = staking.lockInfoOf(page[k]);
            if (!expired) continue;
            assertLt(n, users.length, "expiredLockScan: an elapsed entry of the page is missing");
            assertEq(users[n], page[k], "expiredLockScan: the page's elapsed entries, in order");
            ++n;
        }
        assertEq(users.length, n, "expiredLockScan: an entry outside the page was reported");
    }

    function test_MORPH_bothLockerReadersWalkTheSamePage() public {
        _mixedLockers();
        uint256 max = type(uint256).max;
        uint256[7] memory offs = [uint256(0), 1, 2, 4, 5, 6, max];
        uint256[7] memory lims = [uint256(0), 1, 2, 3, 5, 6, max];
        for (uint256 i; i < 7; ++i) {
            for (uint256 j; j < 7; ++j) _samePage(offs[i], lims[j]);
        }
    }

    /// The three views read the elapsed class at the same second the processor clears it:
    /// one second before the unlock, at it, and one second after it. The processor runs in the
    /// position's own transaction (its sweep, then `_processLockExpiry`).
    function test_MORPH_theLockViewsReadTheClassTheProcessorClears() public {
        vm.prank(alice);
        staking.deposit(1_000e18, 90);
        (, uint256 unlock,,) = staking.lockInfoOf(alice);
        uint256[3] memory at = [unlock - 1, unlock, unlock + 1];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            vm.warp(at[i]);
            (,,, bool expired) = staking.lockInfoOf(alice);
            assertEq(expired, i > 0, "setup: the commitment elapses at unlockTime");
            assertEq(staking.hasStaleBoost(alice), expired, "hasStaleBoost reads the class lockInfoOf reads");
            (address[] memory scan,,,) = staking.expiredLockScan(0, type(uint256).max);
            assertEq(scan.length == 1 && scan[0] == alice, expired, "expiredLockScan lists the class lockInfoOf reads");
            vm.prank(alice);
            staking.claimRewards();
            (uint256 lockDays,,,) = staking.lockInfoOf(alice);
            assertEq(lockDays == 0, expired, "the processor clears exactly the class the views read");
            vm.revertToState(snap);
        }
    }

    function _sameRatio() internal view {
        assertEq(staking.collateralRatio(), staking.solvency().collateralRatioWad,
            "collateralRatio is the solvency report's ratio");
    }

    /// Both readers of backing / owed, on an empty book, a matched one, an over-collateralised
    /// one, a short pot and an empty balance.
    function test_MORPH_collateralRatioIsTheSolvencyReportsRatio() public {
        assertEq(staking.owed(), 0, "setup: an empty book owes nothing");
        _sameRatio();
        vm.prank(alice);
        staking.deposit(1_000e18, 90);
        _sameRatio();
        token.mint(address(staking), 7e18);
        _sameRatio();
        bytes memory balCall = abi.encodeWithSelector(token.balanceOf.selector, address(staking));
        vm.mockCall(address(token), balCall, abi.encode(staking.owed() / 3));
        assertFalse(staking.isSolvent(), "setup: the pot reads short");
        _sameRatio();
        vm.mockCall(address(token), balCall, abi.encode(uint256(0)));
        _sameRatio();
    }
}
