#!/usr/bin/env bash
# Non-vacuity check. A property the code already enforces cannot fail, so each fix is reverted
# on its own and the test that claims to cover it must go red.
#
# Two failure modes have bitten this script, and both produced a confident wrong answer:
#
#   1. A revert pattern that no longer matched (forge fmt reflowed a multi-line condition).
#      The fix stayed in, the test passed, and the output said VACUOUS. So every pattern is
#      matched with `\s+` for any whitespace run, and the match count is asserted to be exactly 1.
#   2. A revert that wrote garbage instead of the buggy code. Compilation then fails, no
#      `[FAIL` appears in the output, and "no test failed" is misread as VACUOUS. So each
#      reverted tree is compiled before its tests are trusted, and a build failure is reported
#      as a broken harness rather than as a verdict about the property.
#
# Run from the repo root.
set -uo pipefail
cd ~/galactic-trust || exit 1
FORGE=/home/alexa/.foundry/bin/forge
SRC=src/GalacticTrust.sol
FIXED=/tmp/glt.fixed.sol
cp "$SRC" "$FIXED"

restore() { cp "$FIXED" "$SRC"; }

# revert <label> <old-literal> <new-literal> <test-regex>
#
# Both literals are matched whitespace-insensitively. A newline in a literal means "a line
# break here"; the surrounding indentation is taken from the original match so the reverted file
# stays readable and stays valid Solidity.
revert() {
  local label="$1" old="$2" new="$3" tests="$4"
  restore
  OLD="$old" NEW="$new" python3 - <<'PY'
import os, pathlib, re

p = pathlib.Path("src/GalacticTrust.sol")
s = p.read_text()
old_lit, new_lit = os.environ["OLD"], os.environ["NEW"]


def to_re(literal):
    return r"\s*\n\s*".join(re.escape(part) for part in literal.split("\n"))


pattern = to_re(old_lit)
hits = re.findall(pattern, s)
if len(hits) != 1:
    raise SystemExit(f"expected exactly 1 match, found {len(hits)} -- no trustworthy revert")

new_lines = new_lit.split("\n")


def repl(m):
    seps = re.findall(r"\s*\n\s*", m.group(0))
    out = new_lines[0]
    for i, sep in enumerate(seps):
        out += sep + (new_lines[i + 1] if i + 1 < len(new_lines) else "")
    return out


s2 = re.sub(pattern, repl, s, count=1)
if s2 == s:
    raise SystemExit("replacement was a no-op")
p.write_text(s2)
PY
  if [ $? -ne 0 ]; then
    echo "  NO-OP REVERT : $label -- pattern did not match, result would be meaningless"
    return
  fi
  printf '  revert applied: %s\n' "$label"

  if ! $FORGE build > /tmp/vacuity-build.log 2>&1; then
    echo "    *** HARNESS BROKEN: the reverted tree does not compile, so no verdict is possible ***"
    grep -m3 -E 'Error|error\[' /tmp/vacuity-build.log | sed 's/^/      /'
    restore
    return
  fi

  local out
  out=$($FORGE test --match-test "$tests" 2>&1)
  if grep -q '\[FAIL' <<<"$out"; then
    echo "    RED    -> the property is real, a test fails without this fix"
  else
    echo "    *** GREEN -> VACUOUS: nothing fails without this fix ***"
  fi
}

echo "A. _forfeitChallengeBonds takes the account total instead of the pledge"
revert "a rejected challenge burns the challenger's whole balance" \
'uint256 amount = challengeLock[id][c];
_releaseLock(id, c);
if (amount > 0) {
challengeBond[c] -= amount;' \
'uint256 amount = challengeBond[c];
_releaseLock(id, c);
if (amount > 0) {
challengeBond[c] = 0;' \
'ForfeitTakesTheCommittedBond'

echo "B. _penalise sums the account total instead of the per-challenge pledge"
revert "an upheld challenge sizes the pool from the account total" \
'forfeited += challengeLock[id][ch[i]];' \
'forfeited += challengeBond[ch[i]];' \
'ForfeitTakesTheCommittedBond|ForfeitingNothing'

echo "C. panelOverride set without the snapshotted quorum check"
revert "sub-quorum reject majority records an override" \
'&& upholdWeight[id] + rejectWeight[id] >= att.curatorQuorumWeight
' '' \
'SubQuorumPanelDoesNotOverride'

echo "D. expireReview does not treat a sub-quorum panel as having left a refutation standing"
revert "sub-quorum acquittal of a refutation falls through to no-override" \
'&& (up + down < att.curatorQuorumWeight || up >= down)' \
'&& up >= down' \
'SubQuorumExpiryLeavesARefutationStanding'

echo "E. the EXPIRED terminal state -- removing the release re-strands the stake"
revert "no release, so an unfinalizable attestation stays PENDING" \
'if (verdict != EvidenceVerdict.CONFIRMED && !att.panelOverride) {
att.status = AttestationStatus.EXPIRED;
if (att.stake > 0) {
totalStaked -= att.stake;
_update(address(this), att.submitter, att.stake);' \
'if (verdict == EvidenceVerdict.CONFIRMED && !att.panelOverride) {
att.status = AttestationStatus.EXPIRED;
if (att.stake > 0) {
totalStaked -= att.stake;
_update(address(this), att.submitter, att.stake);' \
'Expiry|TiedPanel|Unattended|BrokenVerifier|SubQuorumPanel|testFuzz_ExpiryAlwaysTerminates'

restore
echo
echo "F. control -- every fix in place:"
$FORGE test --match-path test/Expiry.t.sol 2>&1 | grep -E 'Suite result'
$FORGE test --match-test 'testFuzz_ExpiryAlwaysTerminates' 2>&1 | grep -E 'Suite result'
$FORGE test --match-path test/Adversarial.t.sol 2>&1 | grep -E 'Suite result'
echo "G. source restored: $(cmp -s "$SRC" "$FIXED" && echo yes || echo NO)"