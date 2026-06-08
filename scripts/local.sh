#!/usr/bin/env bash
# local.sh — N/A for a documentation repo (no server to run). The docs are plain
# Markdown; preview them in your editor or any Markdown viewer, and validate the
# diagrams with `make test` (scripts/test.sh → scripts/validate_diagrams.sh).
# Present for parity with the other Atlas repos' build systems; skips cleanly.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/lib/colors.sh
source scripts/lib/colors.sh
# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
trap 'on_err "$LINENO" "$?"' ERR

skip "local" "documentation repo — no server; open the Markdown, run 'make test' for diagrams"
exit 0
