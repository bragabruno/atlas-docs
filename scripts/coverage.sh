#!/usr/bin/env bash
# coverage.sh — N/A for a documentation repo (no application code to cover).
# Present for parity with the other Atlas repos' build systems; skips cleanly.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/lib/colors.sh
source scripts/lib/colors.sh
# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
trap 'on_err "$LINENO" "$?"' ERR

skip "coverage" "documentation repo — no application code to cover"
exit 0
