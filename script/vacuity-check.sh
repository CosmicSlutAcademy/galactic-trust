#!/usr/bin/env bash
# Non-vacuity check. A property the code already enforces cannot fail, so each fix is reverted
# on its own and the test that claims to cover it must go red.
#
# Replacements are exact multi-line strings, not regexes, and each one is verified to have
# changed the file before its result is trusted. A regex that silently matches nothing leaves
# the fix in place, the test passes, and the result reads as "vacuous" when the truth is
# "nothing was reverted" -- the same false negative this exercise exists to catch.
#
# Run from the repo root.
set -uo pipefail
cd ~/galactic-trust || exit 1
FORGE=/home/alexa/.foundry/bin/forge
FIXED=/tmp/glt.fixed.sol
cp src/GalacticTrust.sol "$FIXED"

# revert <label> <python-old-literal> <python-new-literal> <test-regex>
revert() {
  local label="$1" old="$2" new="$3" tests="$4"
  cp "$FIXED" src/GalacticTrust.sol
  OLD="$old" NEW="$new" python3 - <<'PY'
import os, pathlib
p = pathlib.Path("src/GalacticTrust.sol")
s = p.read_text()
old, new = os.environ["OLD"], os.environ["NEW"]
assert old in s, "PATTERN NOT FOUND -- nothing was reverted"
p.write_text(s.replace(old, new, 1))
PY
  if [ $? -ne 0 ]; then
    echo "  NO-OP REVERT : $label"
    return
  fi
  if cmp -s src/GalacticTrust.sol "$FIXED"; then
    echo "  NO-OP REVERT : $label -- replacement was a no-op"
    return
  fi
  printf '  revert applied: %s\n' "$label"
  local out
  out=$($FORGE test --match-path test/Adversarial.t.sol --match-test "$tests" 2>&1)
  if grep -q '\[FAIL' <<<"$out"; then
    echo "    RED    -> the property is real, a test fails without this fix"
  else
    echo "    *** GREEN -> VACUOUS: nothing fails without this fix ***"
  fi
}

echo "A. _forfeitChallengeBonds takes the account total instead of the pledge"
revert "a rejected challenge burns the challenger's whole balance" \
'            uint256 amount = challengeLock[id][c];
            _releaseLock(id, c);
            if (amount > 0) {
                challengeBond[c] -= amount;' \
'            uint256 amount = challengeBond[c];
            _releaseLock(id, c);
            if (amount > 0) {
                challengeBond[c] = 0;' \
'ForfeitTakesTheCommittedBond'

echo "B. _penalise sums the account total instead of the per-challenge pledge"
revert "an upheld challenge sizes the pool from the account total" \
'            forfeited += challengeLock[id][ch[i]];' \
'            forfeited += challengeBond[ch[i]];' \
'ForfeitTakesTheCommittedBond|ForfeitingNothing'

echo "C. panelOverride set without the snapshotted quorum check"
revert "a sub-quorum reject majority records an override" \
'                    && upholdWeight[id] + rejectWeight[id] >= att.curatorQuorumWeight
' '' \
'SubQuorumPanelDoesNotOverride'

echo "D. expireReview does not treat a sub-quorum panel as having left a refutation standing"
revert "a sub-quorum acquittal of a refutation falls through to no-override" \
'if (_verdict(att) == EvidenceVerdict.REFUTED && (up + down < att.curatorQuorumWeight || up >= down)) {' \
'if (_verdict(att) == EvidenceVerdict.REFUTED && up >= down) {' \
'SubQuorumExpiryLeavesARefutationStanding'

cp "$FIXED" src/GalacticTrust.sol
echo
echo "E. control -- every fix in place:"
$FORGE test --match-path test/Adversarial.t.sol --match-test 'Forfeit|SubQuorum|FullQuorum' 2>&1 | grep -E 'Suite result'
echo "F. source restored: $(cmp -s src/GalacticTrust.sol "$FIXED" && echo yes || echo NO)"