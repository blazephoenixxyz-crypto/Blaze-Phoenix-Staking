#!/usr/bin/env bash
# shared-quantities.sh — keeps SHARED_QUANTITIES.md from lying.
#
# The register claims, per row, that a shared quantity is bound by something.
# This script checks the claim is real. It does NOT discover new shared
# quantities: deciding that two consumers ask the same question is a human job.
#
# Rules enforced:
#   1. a PINNED row must name a test file that EXISTS
#   2. a PINNED row's test file must MENTION the quantity  <- this is the one that bites
#   3. a SINGLE row that names a CI guard must find that guard in ci.yml
#
# A pin that does not name its quantity is a green test in front of a hole.
#
# Port of bp-dex .github/scripts/shared-quantities.sh, with ONE change: the pin
# may be a Foundry `.t.sol` OR a real-EVM `.mjs` suite. Both gate this repo
# (`ci.yml` jobs `foundry` and `node-evm`), and two of the parity pins live in
# the `.mjs` harness (`final.mjs`, `selfaudit.mjs`).
set -uo pipefail

REG="${1:-SHARED_QUANTITIES.md}"
CI=".github/workflows/ci.yml"
fail=0

if [[ ! -r "$REG" ]]; then
  echo "::error::$REG not found — the register is the contract, it cannot be optional."
  exit 1
fi

# Table rows only. Written to a temp file rather than read from a process
# substitution: the loop must run in THIS shell (it sets `fail`), and `< <(...)`
# is unavailable under some sandboxes where this also gets run by hand.
ROWS="$(mktemp)"
grep '^|' "$REG" > "$ROWS" 2>/dev/null || true

while IFS= read -r row; do
  case "$row" in
    '|---'*|'| ---'*|'| Quantity'*|'| Status'*) continue ;;
  esac

  status=""
  for s in SINGLE PINNED WEAK OPEN UNVERIFIED; do
    if [[ "$row" == *"\`$s\`"* ]]; then status="$s"; break; fi
  done
  [[ -n "$status" ]] || continue

  # The quantity is the first backticked token of the row.
  qty="$(printf '%s' "$row" | sed -n 's/^|[^`]*`\([^`]*\)`.*/\1/p')"
  # Strip markdown emphasis and parenthetical qualifiers, keep an identifier.
  qty="$(printf '%s' "$qty" | sed 's/[^A-Za-z0-9_.]//g')"
  [[ -n "$qty" ]] || continue

  # Skip the legend table, where the quantity column IS the status keyword.
  case "$qty" in SINGLE|PINNED|WEAK|OPEN|UNVERIFIED) continue ;; esac

  case "$status" in
    PINNED)
      tests="$(printf '%s' "$row" | grep -oE 'test/[A-Za-z0-9_/.-]+\.(t\.sol|mjs)' | sort -u)"
      if [[ -z "$tests" ]]; then
        echo "::error::PINNED row for '$qty' names no test file. A pin with no test is an OPEN row wearing a badge."
        fail=1
        continue
      fi
      for t in $tests; do
        if [[ ! -r "$t" ]]; then
          echo "::error::PINNED row for '$qty' cites $t, which does not exist."
          fail=1
          continue
        fi
        # The quantity may be a method (`Core.foo`) — match the last segment.
        needle="${qty##*.}"
        if ! grep -q "$needle" "$t"; then
          echo "::error::PINNED row for '$qty' cites $t, but that file never mentions '$needle'. Demote the row to WEAK and say what escapes, or make the test name what it pins."
          fail=1
        fi
      done
      ;;
    SINGLE)
      guard="$(printf '%s' "$row" | grep -oE '\*[A-Z][a-z]+ [a-z]+ guard\*' | tr -d '*' | head -1)"
      if [[ -n "$guard" ]] && [[ -r "$CI" ]]; then
        if ! grep -qi "$guard" "$CI"; then
          echo "::error::SINGLE row for '$qty' relies on the CI job \"$guard\", which is not in $CI."
          fail=1
        fi
      fi
      ;;
  esac
done < "$ROWS"
rm -f "$ROWS"

if (( fail )); then
  echo
  echo "The register disagrees with the repository. Fix the code, or fix the row — never delete the row."
  exit 1
fi

echo "shared-quantities: every PINNED row names a test that names its quantity."
