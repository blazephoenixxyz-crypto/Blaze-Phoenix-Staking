# Known issues, out of scope and by design

This page lists behaviour of the staking engine that is deliberate, limits that are accepted and
documented, and areas outside the scope of the security programme. A report that only restates an
entry below is not awarded, unless it shows an impact beyond what the entry describes. Reporting
rules, scope and awards are in [`SECURITY.md`](../SECURITY.md) and at
<https://blazephoenix.xyz/bounty>.

## By design

- **Recorded bad debt reads as insolvency until it is recapitalised.** A loss the protocol reserve
  cannot cover is booked in `totalBadDebt` and stays counted in what the contract owes, so
  `isSolvent()` returns false and the full-value channels close until `absorbBadDebt` covers it.
  The reserve is consumed before a loss is booked; what reaches it afterwards (an interest slice,
  the pure yield a lapsed boost did not earn, settled by the lock sweep that runs after the
  borrower sweep) is not netted against the booked loss on its own. `absorbBadDebt` applies the
  reserve first, and anyone may call it with `amount_ = 0` to do only that.
  Emission and pure yield deferred under a breach stay owed to their position and are paid by
  that position's first settlement after the breach clears. The deferred credit has one quote,
  `pendingRewards`, whichever channel it came from; `pendingPureYield` quotes the un-settled
  share only, and the two sum to what a claim pays. Documented in `README.md` (section 1),
  `docs/WHITEPAPER.md` (section 2.1) and `src/BlazePhoenixStaking.sol` (contract header and the
  EMIS-DEFER comment in `_settlePendingRewards`).
- **An emergency exit forfeits unpaid rewards.** `emergencyWithdraw` returns net equity, closes the
  position and forfeits unpaid emission and pure yield. Using it is the holder's choice: an
  emergency starts only from an on-chain breach or a guardian decision, and the admin can cancel it
  once no breach remains, after which a holder who did not exit claims as usual. The forfeited
  amount stays in the contract, counted in `totalRewardDistributed - totalRewardsPaid` (a term of
  `owed()`) with no position left to claim it: `sweepUndistributedEmission` reaches only
  `rewardReserve`, and no function pays it out. The stale-weight excess of the exiter's last window
  (the part a settle returns to `rewardReserve` under LOCK-STALE) is not part of the forfeit: the
  hatch reads the window through the same `_settleEmission` the settle uses and moves that excess
  to the reserve, where `sweepUndistributedEmission` reaches it; the hatch mirrors that move on the
  3326 anchor, so `cancelEmergency` stays reachable after solvent exits. Measured on the Monte Carlo
  maximiser (1,21,104): 55,309,813.96 BZPX forfeited by the holder, 127,651.41 BZPX of stale-weight
  excess returned to the reserve, 3.5e7 wei of rounding (`test/montecarlo/ResidueDecomposition.t.sol`).
  The forfeited pure yield keeps its own stale excess (`_settlePendingPureYield` would move it to
  `protocolReserve`); that part is not returned. In a breached emergency the forfeit stays in the balance
  the haircut divides among the exits. The exit moves `backing()` and `owed()` by the same amount,
  so the identity holds and `owed()` reads high by the forfeits, never low. Documented in `README.md`
  (sections 1 and 4), `src/BlazePhoenixStaking.sol` (NatSpec of `emergencyWithdraw`) and
  `test/fix1102/EmergencyForfeitStaysOwed.t.sol`.
- **A breached emergency exit waits until the book is fresh.** In an emergency whose pot is short
  of the positive equity, `emergencyWithdraw` pays `equity · pot / Σ equity` and refuses
  (`Staking__StaleEquity`) while interest already debited from the book has not reached its
  positions. `syncEquity(user)`, permissionless and callable only in an emergency, attributes one
  position; the exit attributes the exiter's own. Once every borrower is attributed the exits go
  through, and what each is paid does not depend on the order of the exits. On a sound book the
  exit pays net equity in full and does not wait. Documented in `src/BlazePhoenixStaking.sol`
  (`emergencyWithdraw`, `syncEquity`, `_attribute`) and
  `test/hardening/AttributionRefreshesEquity.t.sol`
  (`test_EQUITYFRESH_EMG_everySyncAndEveryExitLeavesTheAccumulatorAtTheStoredSum`: sync, refused
  exit, sync, three exits;
  `test_EQUITYFRESH_control_aTripOneSecondAfterThePokeStillWaitsForTheSync`;
  `testFuzz_EQUITYFRESH_EMG_aPokeBeforeTheTripNeverMakesAPayoutDependOnTheExitOrder`: the exit
  orders).
- **The borrower sweep credits what it settles.** The borrower window of the maintenance sweep
  settles every position it reaches, a seized one included, and credits the emission to the
  position instead of paying it: a later step of the same window can still book a loss, and
  LOSS-FIRST puts every loss on the books before anything leaves at par in that transaction. The
  credit stays owed (a term of `owed()`), `pendingRewards` quotes it, and the position's next
  settlement outside that window pays it, `claimRewards` included; a position seized in full keeps
  its credit. Like any unpaid emission, `emergencyWithdraw` forfeits it. Documented in
  `docs/WHITEPAPER.md` (sections 3.1 and 3.2), `src/BlazePhoenixStaking.sol`
  (`_settlePendingRewards`, `maintStep`) and `test/hardening/MaintenanceBeforePayment.t.sol`.
- **Batch lock pokes take a list of any length.** `pokeExpiredLocks` takes a list that the caller
  supplies and pays for, so the protocol sets no cap on its length; the block gas limit bounds it,
  and an oversized batch reverts only the caller's own transaction. Entries that are not expired
  are skipped. Documented in `src/BlazePhoenixStaking.sol` (NatSpec of `pokeExpiredLocks`) and
  `docs/WHITEPAPER.md` (section 3.3).
- **Privileged roles act within their documented powers.** The guardian may pause new risk or
  declare an emergency at its discretion, with no cooldown; while paused, liquidations stop and
  interest keeps accruing, and `repay` stays open. The admin resumes the protocol and cancels an
  emergency once no breach remains. Neither role can move principal. Findings that need a role
  holder to use these powers as designed are out of scope. Documented in `README.md` (sections 1
  and 4) and `src/BlazePhoenixStaking.sol` (NatSpec of `pause`, `declareEmergency` and
  `cancelEmergency`).
- **`effectiveStakeOf` reads stored state.** It returns net stake as last written and does not
  project interest accrued since the position was last touched; `maxBorrowOf` is the projected
  limit that `borrow` accepts. Documented in `src/BlazePhoenixStaking.sol` (NatSpec of
  `effectiveStakeOf` and `maxBorrowOf`).
- **Interest is priced at the rate its window starts with.** The interest index accrues in O(1):
  the window since the last update of the book is charged at the rate its starting utilisation
  reads, with no integral of the curve across the window. A book that transacts often follows the
  rate its falling stake raises; an idle one keeps its starting rate until the next transaction.
  A busy book is therefore charged slightly more, never more than the whole period at the final
  rate. Measured with 9.9M BZPX borrowed against 21M staked, over one year: 331,650.00 BZPX of
  interest with no transaction in between, 333,730.36 BZPX with one a day. Documented in
  `docs/INVARIANTS_AND_TIME.md` (R1) and `test/fix1102/InterestStaleWeight.t.sol`.
- **Emission a window does not release is not handed to later windows.** Each window releases
  only the delta of the emission curve over that window (`_windowReward`), damped while the boosted
  weight is below `MIN_EMISSION_WEIGHT` and capped by `rewardReserve`. A window with no weight, or
  one inside an emergency, releases nothing and the clock moves on. What is not released stays in
  `rewardReserve`; after `emissionEnd` only the admin can move it, only to the treasury, with
  `sweepUndistributedEmission`, which first settles everything still payable and is refused in an
  emergency or when the book would read a hard breach after it. Documented in
  `src/BlazePhoenixStaking.sol` (`_updateGlobal`, `_windowReward`, `sweepUndistributedEmission`),
  `README.md` (section 4 and Emission), `docs/WHITEPAPER.md` (section 6.2) and
  `test/hardening/EmissionResidueOrigin.t.sol`.

## Accepted and documented limits

- **The guardian role is granted by hand after deployment.** The deploy script does not grant
  `GUARDIAN_ROLE`; until the deployer does, `pause` and `declareEmergency` revert. Documented in
  `script/Deploy.s.sol` (header).
- **The token must be a standard ERC-20.** The design assumes no fee on transfer, no rebasing, no
  receiver blacklist and no transfer pause; a fee-on-transfer token is rejected by the
  conservation guard. Reports that rely on a token breaking these assumptions are outside the
  design. Documented in `README.md` (Token assumption) and `docs/INVARIANTS_AND_TIME.md`
  (Asset boundary).
- **A lapsed lock keeps its boosted weight in the reward denominators until it is touched.** From
  `unlockTime` the position's own payout follows 1.00x: every settle splits its window at the
  unlock, on the emission curve for emission and on time for pure yield, pays the part after it at
  1.00x (`_postUnlockAtBase`), and returns the part its lapsed boost did not earn to the reserve
  that funded it (`rewardReserve` for emission, `protocolReserve` for pure yield). Its weight
  leaves the global denominators when the position is touched: by its own transaction, by the
  lock sweep that every transaction carries (a borrower whose interest the transaction has not
  attributed by the borrower sweep instead: the lock sweep passes over it, so that its settle books
  no loss after the sweep has paid), or by the permissionless `pokeExpiredLock` and
  `pokeExpiredLocks`. Until then, positions whose lock is still running share each window with
  that weight and are paid slightly less; the difference stays in the reserve and is not paid to
  the lapsed position. Measured with ten lapsing positions beside a seven-year staker: 84.74 BZPX
  less for the staker with one transaction a day (every lapsed weight normalised within
  43,200 s), 11,498.79 BZPX with no traffic at all.
  The split reads the curve, not the accumulator, so it is exact only where the flow inside the
  window followed the curve over an unchanged book. A book that shrank inside the window, a
  reserve that ran dry, an emergency halt (nothing flowed while the curve moved on) or a position
  that is a large part of its own denominator (normalising it would have shrunk the denominator
  too) moves the split. The payout stays between the 1.00x share and the lapsed share it replaces,
  and what is not paid stays in the reserve. Measured: a single 730-day position left untouched to
  the end of the programme collects 76,800,000 of the 90,000,000 BZPX emitted, and the other
  13,200,000 stay in `rewardReserve`; a 90-day lock that lapses inside a 30-day halt collects
  2,620,806.35 BZPX instead of 2,630,136.99. Normalised at `unlockTime`, the same positions collect
  everything. Removing the weight at the exact instant needs per-day expiry buckets, which do not
  fit the EIP-170 size limit. Documented in `src/BlazePhoenixStaking.sol` (`_postUnlockAtBase`,
  `_flowEnd`, `_resync`), `docs/INVARIANTS_AND_TIME.md` (section 2 and R3),
  `test/fix1102/LockExpiryStaleWeight.t.sol`, `test/assurance/DeliveryIndex.t.sol` and
  `test/fix1027/StaleQuantityFamily.t.sol`.
- **A borrower's weight follows its interest when it is touched.** Interest lowers a borrower's
  net stake continuously, while its tracked weight keeps the equity of its last resync until a
  transaction reaches it: its own, or the borrower sweep that every transaction carries. Its own
  settle pays the live weight and returns the stale excess to `rewardReserve`; until the resync,
  debt-free positions share each window with the stale weight and are paid slightly less.
  Measured over one year with an idle 20M position at 9.9M of debt beside a 1M debt-free position:
  the debt-free position collects 1,081,081.08 BZPX of emission when nothing else transacts and
  1,097,587.96 BZPX when it claims daily. Documented in `src/BlazePhoenixStaking.sol`
  (`_autoMaintain`, `_atLiveWeight`) and `test/fix1102/InterestStaleWeight.t.sol`.
- **Bit 4 of `auditInvariants` is an upper bound, not an equality.** A position's weight keeps
  the equity of its last resync, while interest is debited from `totalStaked` as it accrues, so
  no stored total equals the equity the weights were built on. The bit therefore reads
  `totalBoostedEffective × 1e4 > (totalStaked + totalInterestAccruedGlobal) × boostByDays(2555)`
  or `totalBoostedPure > totalBoostedEffective`: stored stake plus all interest ever debited
  covers the stake of every build, on an idle book and in an emergency alike. It cannot read set
  on a correct book, and its first term widens as interest accrues: an excess of weight smaller
  than `maxBoost ×` (debt plus interest accrued) passes it. `totalPositiveEquity` is not a bound
  for the effective weight: an attribution that no resync follows lowers it while the weight
  stays. Pinned in `test/hardening/AuditBit4Clock.t.sol`.
- **A seizure's keeper bonus is paid at par inside the borrower sweep.** It is the one payment the
  maintenance sweep makes ahead of a loss it may still book: when the borrower window seizes a
  position, the caller's bonus (`LIQ_BONUS_BPS`, at most 5% of the seized debt) leaves at once,
  and a later step of the same window can still book a loss. No bonus is paid into a pot that
  already reads as breached (`_hardBreach()`), by the caller's own loss too: every entry that
  carries the borrower window, the batch `pokeExpiredLocks` included, books its caller's own
  loss before the window starts, and `liquidate` books its caller's own loss before the
  seizure it makes; the bonus then stays in `protocolReserve`. Deferring it would need value
  held in flight across the window, outside every owed quantity the contract keeps. Documented
  in `docs/WHITEPAPER.md` (section 3.1), `src/BlazePhoenixStaking.sol`
  (`_autoMaintain`, `pokeExpiredLocks`, `liquidate`, `_executeLiquidation`) and
  `test/hardening/MaintenanceBeforePayment.t.sol`
  (`test_LOSSFIRST_documents_theSeizureBonusIsPaidAtParAheadOfTheWindowsLoss`: the caller is
  paid the seized position's equity, never more than its own collateral, and the window then
  books a loss that leaves the pot short; `test_LOSSFIRST_theCarriersOwnLossIsBookedBeforeTheSeizureBonus`,
  `test_LOSSFIRST_theCarriersOwnLossIsBookedBeforeTheBatchPokesSeizureBonus` and
  `test_LOSSFIRST_theCarriersOwnLossIsBookedBeforeItsOwnLiquidationsBonus`: a caller whose own
  loss leaves the pot short is paid no bonus by the window its transaction or its batch carries,
  nor by the seizure it makes itself).
- **A loss not yet recorded is read only in part.** `owed()` and the `owed` and `deficit` of
  `solvency()` are lower bounds (its `surplus` and `collateralRatio()` upper bounds), and
  `isSolvent()` reads through them: a borrower whose accrued debt has passed her stake carries a
  loss nothing has recorded yet, and the read nets it against the other claims, so it can read
  solvent with no deficit while the claims exceed the backing; past the other positions' stakes net
  of their debts and the reserves, the floors of `_owed()` cap the netting, and the deficit read is
  never above the real one. Until the borrower window's next sweep reaches the position (each user
  transaction outside a pause scans `_maintBudget()` borrowers from a rotating cursor, at most
  `MAINT_MAX_SCAN`, skipping its caller), or a keeper liquidates it, or the borrower exits in an
  emergency, withdrawals and claims are paid at par in arrival order. Documented in
  `src/BlazePhoenixStaking.sol` (`_owed`, `owed`, `isSolvent`, `solvency`) and
  `test/hardening/UnbookedLossReadIsALowerBound.t.sol` (the read deficit is bounded by the real one;
  `test_OWEDREAD_documents_anUnbookedLossReadsSolventUntilTheSweepBooksIt`: the loss reads solvent
  until the sweep a pure staker's own claim carries books it).

## Out of scope

- **The BZPX token itself.** How this contract consumes the token is in scope. Documented in
  `SECURITY.md` (Scope).
- **Deployed addresses.** The staking contract is not deployed and no address is published, so a
  report about any address presented as this contract, or about an earlier version, does not
  apply. Documented in `README.md` (Status) and `docs/WHITEPAPER.md` (header).
- **Code outside the current source.** Reports must target the source in this repository; where
  any other text differs from it, the source wins. Documented in `README.md` (Status) and
  `docs/VERSION_HISTORY.md`.
- **Issues already fixed.** A finding fixed on the default branch before the report arrives is
  already known. Duplicates are settled as `SECURITY.md` (Bounty programme) sets out.
