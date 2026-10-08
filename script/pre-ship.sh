#!/usr/bin/env bash
# Post-change gate. The invariant suite is only trustworthy if no handler is passing by
# reverting on every call, so this reads the revert column rather than the suite result.
set -uo pipefail
cd ~/galactic-trust || exit 1
FORGE=/home/alexa/.foundry/bin/forge

echo "--- deep profile ---"
FOUNDRY_PROFILE=deep $FORGE test 2>&1 | grep -E 'FAIL|tests passed'

echo
echo "--- invariant handler revert column ---"
# Table columns are `| Handler | op | calls | reverts |`, and awk -F'|' puts the empty
# leading segment in $1 -- so calls is $4 and reverts is $5. Getting this wrong once summed
# the calls column and reported 1,280,000 reverts on a suite that has none.
FOUNDRY_PROFILE=deep $FORGE test --match-path test/Invariant.t.sol 2>&1 \
  | grep -E '^\| [A-Za-z]+ ' \
  | awk -F'|' 'NF>=6 { calls+=$4; rev+=$5 } END {
      printf "handler calls: %d\n", calls
      printf "handler reverts: %d\n", rev
      if (rev > 0) print "  *** a handler is reverting; read the column, not the result ***"
      else print "  clean: no handler is passing by reverting on every call"
    }'

echo
echo "--- EIP-170 ---"
$FORGE build --sizes 2>&1 | grep -E '^\| (GalacticTrust|CircomVerifier)'