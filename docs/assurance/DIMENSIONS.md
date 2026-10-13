# Dimensional census — src/BlazePhoenixStaking.sol

Axis D. Every state variable gets a unit; every arithmetic expression that combines units gets its
derivation and a verdict. Line numbers refer to `src/BlazePhoenixStaking.sol` at `cedd80d`.
Every row is tagged `[conferido]`: the expression was read at that line.

## Vocabulary

| unit | meaning |
|---|---|
| `wei` | token-wei of BZPX (18 decimals) |
| `W` | boosted weight: `wei · boost_bps / 10_000`, so dimensionally a `wei` scaled by a pure number |
| `WAD` | 1e18 fixed-point pure number (ratio, utilisation, health) |
| `WAD/W` | per-share accumulator: `wei · WAD / W` |
| `WAD/debt` | per-debt interest index: `wei_interest · WAD / wei_debt` (a pure number in WAD) |
| `bps` | basis points, 10_000 = 1 |
| `bps/yr` | annual rate in basis points |
| `pct` | percent, 100 = 1 (`MAX_LTV`, `LIQ_THRESHOLD`) |
| `s` | seconds (durations and timestamps) |
| `d` | days |
| `blk` | block numbers |
| `n` | count / index |

## Constants

| line | name | unit |
|---|---|---|
| 118 | WAD | WAD (scale) |
| 119 | SECONDS_PER_YEAR | s/yr |
| 137 | TOTAL_REWARDS | wei |
| 138 | HALVING_PERIOD | s |
| 139 | EMISSION_PERIODS | n |
| 140 | EMISSION_LENGTH = PERIODS · PERIOD | s |
| 141 | INITIAL_REWARD_PER_SEC = (TOTAL/2) / PERIOD | wei/s |
| 143 | MAX_STAKE_PER_WALLET | wei |
| 153 | MIN_EMISSION_WEIGHT | W |
| 155 | MAX_LTV | pct |
| 156 | LIQ_THRESHOLD | pct |
| 157 | LIQ_BONUS_BPS | bps |
| 158 | RESERVE_FACTOR_BPS | bps |
| 165 | DAYS_PER_YEAR | d/yr |
| 166-167 | MIN_LOCK_DAYS, MAX_LOCK_DAYS | d |
| 169-171 | BOOST_BASE, BOOST_LINEAR, BOOST_QUAD | bps |
| 173 | MIN_DEPOSIT_BLOCKS | blk |
| 176-177, 179-180 | RATE_R0, RATE_RK, RATE_S1, RATE_S2 | bps/yr |
| 178 | RATE_UK | WAD (utilisation) |
| 187 | MAX_PROTOCOL_UTIL_WAD | WAD (utilisation) |
| 192 | CONSERVATION_DUST | wei |
| 194 | EMERGENCY_GRACE_PERIOD | s |
| 197-198, 200, 208 | MAINT_BASE, MAINT_DENSITY, MAINT_MAX_SCAN, MAINT_MAX_LOCK_ACTIONS | n |
| 199 | MAINT_GAP_UNIT | s |

## State variables

| line | variable | unit |
|---|---|---|
| 213-214 | emissionStart, emissionEnd (immutable) | s |
| 217 | totalStaked | wei |
| 218 | totalDebt | wei |
| 219 | protocolReserve | wei |
| 220 | rewardReserve | wei |
| 221 | totalEmissionFunded | wei |
| 223 | totalBoostedEffective | W |
| 224 | totalBoostedPure | W |
| 234 | totalPositiveEquity | wei |
| 236 | accRewardPerShare | WAD/W |
| 237 | accPureYieldPerShare | WAD/W |
| 238 | lastRewardTime | s |
| 245 | accInterestPerDebt | WAD/debt |
| 246 | lastInterestTime | s |
| 248 | totalRewardsPaid | wei |
| 249 | totalRewardDistributed | wei |
| 250 | totalInterestAccruedGlobal | wei |
| 251 | totalUncollectedInterest | wei |
| 252 | totalBadDebt | wei |
| 253-255 | totalLiquidations, totalAutoLiquidations, totalLockSweeps | n |
| 258-259 | lastAuditedAccReward, lastAuditedAccPure | WAD/W |
| 262 | emergencyMode | bool |
| 263 | emergencyTrippedAt | s |
| 266-268 | _borrowers, _borrowerIdx, _maintCursor | n |
| 269 | lastMaintTime | s |
| 278-280 | _lockers, _lockerIdx, _lockCursor | n |
| 283 | UserInfo.staked | wei |
| 284 | UserInfo.debt | wei |
| 285 | UserInfo.rewardDebt | wei |
| 286 | UserInfo.pureYieldDebt | wei |
| 287 | UserInfo.lastAccrueTime | s |
| 288 | UserInfo.interestIndex | WAD/debt |
| 289-290 | UserInfo.trackedBoostedEffective, trackedBoostedPure | W |
| 291 | UserInfo.trackedEquity | wei |
| 292 | UserInfo.depositBlock | blk |
| 293 | UserInfo.unlockTime | s |
| 294 | UserInfo.lockDays | d |

## Expressions

| # | line | expression | derivation | verdict |
|---|---|---|---|---|
| 1 | 389-390 | conservation snapshot | `wei + wei + wei` vs `wei + wei + wei + wei` | consistent [conferido] |
| 2 | 394-396 | conservation check | sums of `wei`; `|Δ| > CONSERVATION_DUST [wei]` | consistent [conferido] |
| 3 | 433 | `BOOST_LINEAR · d / DAYS_PER_YEAR` | `bps · d / (d/yr)·yr` → bps (d/365 is years) | consistent [conferido] |
| 4 | 434 | `BOOST_QUAD · d · d / (365 · 365)` | `bps · d² / d²` → bps | consistent [conferido] |
| 5 | 448 | `totalEmissionFunded + amount > TOTAL_REWARDS` | wei vs wei | consistent [conferido] |
| 6 | 466 | `min(amount, protocolReserve)` | wei | consistent [conferido] |
| 7 | 591 | `eCorr = totalPositiveEquity − trackedEquity + payout` | wei − wei + wei | consistent [conferido] |
| 8 | 592 | `mulDiv(payout, pot, eCorr)` | `wei · wei / wei` → wei | consistent [conferido] |
| 9 | 601-605 | bad debt on emergency exit | `debt − principal`, `min(·, protocolReserve)`: wei | consistent [conferido] |
| 10 | 646 | `u.staked + amount > MAX_STAKE_PER_WALLET` | wei vs wei | consistent [conferido] |
| 11 | 649, 846, 1841 | `(emissionEnd − now) / 1 days` | `s / (s/d)` → d, compared with lockDays (d) | consistent [conferido] |
| 12 | 669, 859 | `now + lockDays · 1 days` | `s + d · (s/d)` → s | consistent [conferido] |
| 13 | 695 | `(unlockTime − now) / 1 days` | s / (s/d) → d, stored in lockDays | consistent [conferido] |
| 14 | 719 | `u.debt + amount > _ltvCap(u)` | wei vs wei (row 40) | consistent [conferido] |
| 15 | 724 | `mulDiv(totalDebt + amount, WAD, totalStaked) > MAX_PROTOCOL_UTIL_WAD` | `wei · WAD / wei` → WAD vs WAD | consistent [conferido] |
| 16 | 754-758 | `toRepay = min(amount, debt)`; `debt −= toRepay` | wei | consistent [conferido] |
| 17 | 774, 821, 843 | `block.number <= depositBlock + MIN_DEPOSIT_BLOCKS` | blk vs blk + blk | consistent [conferido] |
| 18 | 775, 883, 1521, 1589 | `now < unlockTime` | s vs s | consistent [conferido] |
| 19 | 799, 971 | `totalStaked − amount`, `totalStaked − seized` (saturating) | wei | consistent [conferido] |
| 20 | 942 | `protocolReserve += bonus` | wei | consistent [conferido] |
| 21 | 955 | `mulDiv(debt, LIQ_BONUS_BPS, 10_000)` | `wei · bps / bps` → wei | consistent [conferido] |
| 22 | 956-968 | seized, leftover, keeperBonus, badDebt, covered, uncovered | min / saturating differences of wei | consistent [conferido] |
| 23 | 997, 1706, 1772 | `debt · 100 >= staked · LIQ_THRESHOLD` | `wei · pct` vs `wei · pct` | consistent [conferido] |
| 24 | 1011 | `MAINT_BASE + len / MAINT_DENSITY` | n + n / n → n | consistent [conferido] |
| 25 | 1014 | `(now − last) / MAINT_GAP_UNIT` | s / s → n | consistent [conferido] |
| 26 | 1293, 1888 | `reward = emittedAt(t) − emittedAt(lastRewardTime)` | wei − wei | consistent [conferido] |
| 27 | 1294, 1889 | `mulDiv(reward, tbe, MIN_EMISSION_WEIGHT)` | `wei · W / W` → wei | consistent [conferido] |
| 28 | 1295, 1890 | `min(reward, rewardReserve)` | wei | consistent [conferido] |
| 29 | 1297, 1891 | `acc += mulDiv(reward, WAD, tbe)` | `wei · WAD / W` → WAD/W | consistent [conferido] |
| 30 | 1313 | `TOTAL − (TOTAL >> 8)` | wei | consistent [conferido] |
| 31 | 1316 | `p = dt / HALVING_PERIOD` | s / s → n | consistent [conferido] |
| 32 | 1317-1318 | `(TOTAL − TOTAL>>p) + (R0 >> p) · (dt − p · PERIOD)` | `wei + (wei/s) · (s − n · s)` → wei | consistent [conferido] |
| 33 | 1333 | `R0 >> ((now − start) / PERIOD)` | wei/s shifted by n | consistent [conferido] |
| 34 | 1340, 1352, 1566-1567 | `mulDiv(tracked, acc, WAD)` | `W · (WAD/W) / WAD` → wei, compared with rewardDebt / pureYieldDebt (wei) | consistent [conferido] |
| 35 | 1391 | `elapsed = now − lastInterestTime` | s | consistent [conferido] |
| 36 | 1433 | `delta = mulDivSafe(mulDivSafe(WAD, rate, 10_000), elapsed, SECONDS_PER_YEAR)` | `WAD · (bps/yr) / bps` → WAD/yr; `· s / (s/yr)` → WAD (per unit debt) | consistent [conferido] |
| 37 | 1438, 1458 | `slice = mulDivSafe(debtNow, delta, WAD)` | `wei · WAD / WAD` → wei | consistent [conferido] |
| 38 | 1439 | `slice > totalStaked` | wei vs wei | consistent [conferido] |
| 39 | 1448 | `delta = mulDiv(totalStaked, WAD, debtNow)` | `wei · WAD / wei` → WAD per unit debt, added to accInterestPerDebt (row 41) | consistent [conferido] |
| 40 | 1729 | `_ltvCap = mulDiv(staked − debt, MAX_LTV, 100)` | `wei · pct / pct` → wei | consistent [conferido] |
| 41 | 1400 | `accInterestPerDebt += delta` | WAD/debt + WAD/debt | consistent [conferido] |
| 42 | 1401 | `totalStaked −= slice` | wei | consistent [conferido] |
| 43 | 1403, 1907 | `reserveCut = mulDiv(slice, RESERVE_FACTOR_BPS, 10_000)` | `wei · bps / bps` → wei | consistent [conferido] |
| 44 | 1404, 1421 | `toPool = slice − reserveCut`; `protocolReserve += toPool − share` | wei | consistent [conferido] |
| 45 | 1418, 1910 | `accPureYieldPerShare += mulDiv(share, WAD, tbp)` | `wei · WAD / W` → WAD/W | consistent [conferido] |
| 46 | 1465 | `_dampPure: mulDiv(amount, tbp, MIN_EMISSION_WEIGHT)` | `X · W / W` → unit of X (wei at 1416/1909, bps/yr at 1873) | consistent [conferido] |
| 47 | 1474 | `idxDelta = accInterestPerDebt − u.interestIndex` | WAD/debt | consistent [conferido] |
| 48 | 1479, 1745 | `interest = mulDivSafe(u.debt, idxDelta, WAD)` | `wei · WAD / WAD` → wei | consistent [conferido] |
| 49 | 1495-1506 | shortfall restore; `u.staked −= interest` | wei on both sides (totalStaked and totalBadDebt grow together) | consistent [conferido] |
| 50 | 1527 | `be = mulDiv(staked − debt, boost, BOOST_BASE)` | `wei · bps / bps` → W | consistent [conferido] |
| 51 | 1528 | `bp = mulDiv(staked, boost, BOOST_BASE)` | `wei · bps / bps` → W | consistent [conferido] |
| 52 | 1556-1557 | `total − tracked + new` (boosted totals) | W | consistent [conferido] |
| 53 | 1558-1559 | `newEq = staked − debt`; `totalPositiveEquity − trackedEquity + newEq` | wei | consistent [conferido] |
| 54 | 1606, 1803 | `util = mulDiv(totalDebt, WAD, totalStaked)` | `wei · WAD / wei` → WAD | consistent [conferido] |
| 55 | 1609, 1958 | `R0 + mulDiv(util, S1, WAD)` | `bps/yr + WAD · (bps/yr) / WAD` → bps/yr | consistent [conferido] |
| 56 | 1610, 1959 | `RK + mulDiv(util − UK, S2, WAD)` | `bps/yr + (WAD − WAD) · (bps/yr) / WAD` → bps/yr | consistent [conferido] |
| 57 | 1621-1625 | `_owed = (totalStaked + rewardReserve + protocolReserve − totalDebt) + (distributed − paid) − badDebt` | wei throughout | consistent [conferido] |
| 58 | 1637, 1686 | `balance + CONSERVATION_DUST < owed` | wei vs wei | consistent [conferido] |
| 59 | 1657, 1687 | `mulDiv(balance, WAD, owed)` | `wei · WAD / wei` → WAD | consistent [conferido] |
| 60 | 1707 | `rewardReserve > TOTAL_REWARDS` | wei vs wei | consistent [conferido] |
| 61 | 1710-1711 | `maxBoosted = mulDiv(totalStaked, boost(MAX), BOOST_BASE)` vs boosted totals | `wei · bps / bps` → W vs W | consistent [conferido] |
| 62 | 1739-1742 | `_projected`: `elapsed`, `acc += d`, `ts −= sl` | s; WAD/debt; wei | consistent [conferido] |
| 63 | 1767 | `mulDiv(s − debt, MAX_LTV, 100) − debt` | `wei · pct / pct − wei` → wei | consistent [conferido] |
| 64 | 1768 | `mulDiv(ts, MAX_PROTOCOL_UTIL_WAD, WAD) − totalDebt` | `wei · WAD / WAD − wei` → wei | consistent [conferido] |
| 65 | 1771 | `h = mulDiv(s − debt, WAD, s)` | `wei · WAD / wei` → WAD | consistent [conferido] |
| 66 | 1773 | `stakeAtLiq = mulDiv(debt, 100, LIQ_THRESHOLD) + 1` | `wei · pct / pct + wei` → wei | consistent [conferido] |
| 67 | 1775 | `daily = mulDivSafe(mulDivSafe(debt, rate, 10_000), 1 days, SECONDS_PER_YEAR)` | `wei · (bps/yr) / bps` → wei/yr; `· (s/d) / (s/yr)` → wei/d | consistent [conferido] |
| 68 | 1776 | `(s − stakeAtLiq) / daily` | `wei / (wei/d)` → d | consistent [conferido] |
| 69 | 1809, 1934 | `MAX_STAKE_PER_WALLET − staked` | wei | consistent [conferido] |
| 70 | 1850 | `mulDiv(emittedAt(now), WAD, TOTAL_REWARDS)` | `wei · WAD / wei` → WAD | consistent [conferido] |
| 71 | 1853, 1856, 1861 | time differences | s | consistent [conferido] |
| 72 | 1871 | `mulDiv(mulDiv(totalDebt, rate, tbp), boost, BOOST_BASE)` | `wei · (bps/yr) / W` → bps/yr (W is a scaled wei); `· bps / bps` → bps/yr | consistent [conferido] |
| 73 | 1873 | `mulDiv(_dampPure(base, tbp), 10_000 − RESERVE_FACTOR_BPS, 10_000)` | `bps/yr · bps / bps` → bps/yr; the damper is linear, so damping the rate equals damping the flow (row 46) | consistent [conferido] |
| 74 | 1893, 1912 | `mulDiv(tracked, acc, WAD)` in the quotes | `W · (WAD/W) / WAD` → wei | consistent [conferido] |
| 75 | 1259-1260 | excess weight `tracked − computed` | W | consistent [conferido] |

## Result

75 expression rows, 0 dimensional inconsistencies. The per-share accumulators divide `wei` by a
boosted weight `W` (rows 29, 45) and multiply back by the same `W` class at settlement (row 34), so
the boost scale cancels; the interest index is a WAD-scaled pure number per unit of debt (rows 36,
39, 41, 47) and every consumer multiplies it by a debt in `wei` and divides by WAD (rows 37, 48).
