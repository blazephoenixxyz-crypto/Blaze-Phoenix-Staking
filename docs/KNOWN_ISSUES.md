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
  Emission deferred under a breach stays owed to its position and is paid by that position's first
  settlement after the breach clears. Documented in `README.md` (section 1),
  `docs/WHITEPAPER.md` (section 2.1) and `src/BlazePhoenixStaking.sol` (contract header and the
  EMIS-DEFER comment in `_settlePendingRewards`).
- **An emergency exit forfeits unpaid rewards.** `emergencyWithdraw` returns net equity, closes the
  position and forfeits unpaid emission and pure yield. Using it is the holder's choice: an
  emergency starts only from an on-chain breach or a guardian decision, and the admin can cancel it
  once no breach remains, after which a holder who did not exit claims as usual. Documented in `README.md`
  (sections 1 and 4) and `src/BlazePhoenixStaking.sol` (NatSpec of `emergencyWithdraw`).
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

## Accepted and documented limits

- **The guardian role is granted by hand after deployment.** The deploy script does not grant
  `GUARDIAN_ROLE`; until the deployer does, `pause` and `declareEmergency` revert. Documented in
  `script/Deploy.s.sol` (header).
- **The token must be a standard ERC-20.** The design assumes no fee on transfer, no rebasing, no
  receiver blacklist and no transfer pause; a fee-on-transfer token is rejected by the
  conservation guard. Reports that rely on a token breaking these assumptions are outside the
  design. Documented in `README.md` (Token assumption) and `docs/INVARIANTS_AND_TIME.md`
  (Asset boundary).

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
