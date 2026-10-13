#!/usr/bin/env python3
"""Coverage matrix of the Foundry suite: area x axis, counted by grep. Feeds docs/assurance/MATRIX.md.

  python3 .github/scripts/assurance_matrix.py            # markdown tables on stdout
  python3 .github/scripts/assurance_matrix.py --tsv      # one line per (area, axis, count)

THE UNIT. One test = one `function test*` / `testFuzz*` / `invariant*` / `check_*` in a `test/**/*.t.sol`
file. Its TEXT is: the `///` / `//` comment lines directly above it, its body, and the bodies of the
helpers it calls by name (one level deep, looked up in the same file first, then in the shared
`Base` file `test/BlazePhoenixStaking.t.sol`).

THE RULE. A test counts in cell (area, axis) when its text matches the area's regex AND the axis's
regex below. Both lists are the definition: change a regex and the matrix changes with it. The
`.mjs` harness is not counted (its checks are not functions).

This is a census of what tests MENTION, not of what they reach: a cell > 0 says some test names
both the area and the axis instrument, not that the property is pinned.
"""
import re, sys, glob, os, collections

AREAS = [
    ("deposit / top-up / lock", r"\.deposit\(|\.lock\("),
    ("withdraw", r"\.withdraw\("),
    ("borrow / repay", r"\.borrow\(|\.repay\(|maxBorrowOf"),
    ("interest", r"totalInterestAccruedGlobal|accInterestPerDebt|currentInterestRateBps|simulateRate|utilizationRate|rateBps"),
    ("emission / rewards", r"claimRewards|pendingRewards|fundEmission|emittedAt|currentRewardPerSec|rewardReserve|totalRewardDistributed|accRewardPerShare|emissionEnd"),
    ("pure yield", r"claimPureYield|pendingPureYield|pureStakerApr|totalBoostedPure|accPureYieldPerShare"),
    ("liquidation", r"\.liquidate\(|healthFactor|daysToLiquidation|LIQ_THRESHOLD|LIQ_BONUS"),
    ("maintenance windows", r"maintStep|maintenanceBudget|activeBorrowerCount|isTrackedBorrower"),
    ("lock sweep / poke", r"pokeExpiredLock|lockStep|lockSweepBudget|expiredLockScan|getLockers|activeLockerCount|isTrackedLocker|hasStaleBoost|lockInfoOf|effectiveLockDaysOf"),
    ("emergency / breaker", r"emergencyWithdraw|declareEmergency|cancelEmergency|tripBreaker|emergencyMode|\.pause\(|\.unpause\("),
    ("admin / reserves", r"withdrawReserve|sweepUndistributedEmission|fundEmission|protocolReserve|grantRole|revokeRole|ROLE_"),
    ("views / solvency", r"\.owed\(|\.backing\(|isSolvent|collateralRatio|\.solvency\(|auditInvariants|touchAuditSnapshot|getGlobalStats|getUserInfo|effectiveStakeOf|totalEffectiveStaked|remainingStakeCapacity"),
]

# The 24 axes. Code axes first, then context axes. A regex of None means the axis has no object in
# a Foundry test of this repository (stated in MATRIX.md), and the cell is reported as "-".
AXES = [
    ("P", "proxy / upgrade", None),
    ("A", "arrays / iteration", r"pokeExpiredLocks|getLockers|expiredLockScan|activeBorrowerCount|activeLockerCount|new address\[\]\("),
    ("D", "dimensions / casts / bits", r"type\(u?int\d*\)\.(max|min)|\bu?int(8|16|32|40|48|64|96|128)\(|>>|<<"),
    ("V", "vectors / hashes", r"keccak256|abi\.encode(Packed|WithSelector|Call)?\("),
    ("Q", "quantities / thresholds", r"MAX_STAKE_PER_WALLET|MAX_LTV|LIQ_THRESHOLD|LIQ_BONUS|RESERVE_FACTOR_BPS|MIN_EMISSION_WEIGHT|TOTAL_REWARDS|HALVING_PERIOD|EMISSION_PERIODS|INITIAL_REWARD_PER_SEC|MIN_DEPOSIT_BLOCKS|MAX_LOCK_DAYS|CONSERVATION_DUST|_LITERAL\b|\bCAP\b|EIP_170"),
    ("S", "seams / dispatch", r"[Rr]eentr|[Hh]ook|[Cc]allback|vm\.mockCall|\.call\(|Malicious|Attacker"),
    ("G", "guards", r"expectRevert"),
    ("T", "time / regime", r"vm\.warp|vm\.roll|\bskip\(|\brewind\("),
    ("E", "events", r"expectEmit|recordLogs|getRecordedLogs"),
    ("Y", "switches (pause / emergency)", r"\.pause\(|\.unpause\(|tripBreaker|declareEmergency|cancelEmergency|emergencyMode|paused\(\)"),
    ("M", "masking (selector-exact refusal)", r"expectRevert\(\s*(abi\.encodeWithSelector\()?\s*[A-Za-z_][A-Za-z0-9_.]*\.selector"),
    ("I", "siblings / mirror direction", r"function \w*(Agree|Equal|Equals|Twin|Mirror|Both|Same|Parity|Symmetr|Split|Twice)\w*\("),
    ("H", "history (fix commit recorded)", r"\b(red at|pre-fix|before the fix|commit [0-9a-f]{7})"),
    ("R", "replication / census", None),
    ("Z", "deployed revision", None),
    ("K", "values / config (constructor, immutables)", r"new BlazePhoenixStaking\(|emissionStart\(\)|emissionEnd\(\)|\.bzpx\(\)|\.treasury\(\)"),
    ("W", "keys / roles", r"grantRole|revokeRole|hasRole|ROLE_|AccessControl|Unauthorized"),
    ("O", "independent oracle (literal)", r"assert(Eq|Approx\w*)\([^;]*\b\d[\d_]{2,}(e\d+)?\b|_LITERAL\b|\bexpected\b"),
    ("X", "artefact (bytecode / size)", r"\.code\.length|extcodesize|codehash|DeployedSize|EIP_170|runtimeCode"),
    ("C", "config / admin posture", r"vm\.(start)?[Pp]rank\(admin\)|ROLE_ADMIN|ROLE_GUARDIAN"),
    ("N", "instrument / verdict (non-vacuity)", r"[Nn]on-?vacuous|[Pp]recondition|assertGt\([^;,]+,\s*0\s*[,)]"),
    ("U", "unmeasured by forge test (check_)", r"function check_"),
    ("L", "live funds", None),
    ("J", "critical window (on-chain history)", None),
]

TEST_FN = re.compile(r"function\s+((?:test|testFuzz|invariant|check_)\w*)\s*\(")
ANY_FN = re.compile(r"function\s+(\w+)\s*\(")


def bodies(src):
    """name -> (doc comment above + full text from `function` to the matching `}`)."""
    out = {}
    lines = src.split("\n")
    offs = [0]
    for l in lines:
        offs.append(offs[-1] + len(l) + 1)
    for m in ANY_FN.finditer(src):
        i = src.find("{", m.end()); semi = src.find(";", m.end())
        if i < 0 or (0 <= semi < i):
            continue
        depth, j = 0, i
        while j < len(src):
            c = src[j]
            if c == "{": depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0: break
            j += 1
        ln = src.count("\n", 0, m.start())
        k = ln - 1; doc = []
        while k >= 0 and lines[k].strip().startswith("//"):
            doc.insert(0, lines[k]); k -= 1
        out.setdefault(m.group(1), "\n".join(doc) + "\n" + src[m.start():j + 1])
    return out


def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
    files = sorted(glob.glob(os.path.join(root, "test", "**", "*.t.sol"), recursive=True))
    base = bodies(open(os.path.join(root, "test", "BlazePhoenixStaking.t.sol")).read())
    tests = []
    for f in files:
        b = bodies(open(f).read())
        for name, text in b.items():
            if not TEST_FN.match("function " + name + "("):
                continue
            expanded = [text]
            for callee in set(re.findall(r"\b(\w+)\s*\(", text)):
                if callee == name or TEST_FN.match("function " + callee + "("):
                    continue
                h = b.get(callee) or base.get(callee)
                if h: expanded.append(h)
            tests.append((os.path.relpath(f, root), name, "\n".join(expanded)))
    cnt = collections.Counter()
    for _, _, text in tests:
        ain = [a for a, rx in AREAS if re.search(rx, text)]
        for ax, _, rx in AXES:
            if rx and re.search(rx, text):
                for a in ain: cnt[(a, ax)] += 1
    if "--tsv" in sys.argv:
        print("area\taxis\tcount")
        for a, _ in AREAS:
            for ax, _, rx in AXES:
                print(f"{a}\t{ax}\t{cnt[(a, ax)] if rx else '-'}")
        return
    print(f"tests counted: {len(tests)} in {len(files)} files\n")
    print("| area | " + " | ".join(ax for ax, _, _ in AXES) + " |")
    print("|---" * (len(AXES) + 1) + "|")
    for a, _ in AREAS:
        cells = [("-" if rx is None else (f"**{cnt[(a, ax)]}**" if cnt[(a, ax)] == 0 else str(cnt[(a, ax)])))
                 for ax, _, rx in AXES]
        print(f"| {a} | " + " | ".join(cells) + " |")
    print("\nCells ordered empty-first (axes without object excluded):\n")
    by = collections.defaultdict(list)
    for a, _ in AREAS:
        for ax, _, rx in AXES:
            if rx: by[cnt[(a, ax)]].append(f"{ax}·{a}")
    for n in sorted(by):
        print(f"- **{n}** ({len(by[n])}): " + ", ".join(by[n]))


if __name__ == "__main__":
    main()
