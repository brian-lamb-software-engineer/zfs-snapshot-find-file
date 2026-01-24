#!/bin/bash
set -euo pipefail

echo "Running validate_summary test..."
./tests/validate_summary.sh
status=$?

echo
echo "=== test log: tests/test.log ==="
cat tests/test.log || true

if [[ $status -eq 0 ]]; then
  echo
  echo "TESTS PASSED"
else
  echo
  echo "TESTS FAILED (see tests/test.log)"
fi
exit $status
