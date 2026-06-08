#!/usr/bin/env bash
# build.sh — N/A for a documentation repo (no package to build/publish; the docs
# render via Markdown and the diagram gate lives in scripts/test.sh). Present for
# parity with the other Atlas repos' build systems; skips cleanly.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/lib/colors.sh
source scripts/lib/colors.sh
# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
trap 'on_err "$LINENO" "$?"' ERR

skip "build" "documentation repo — nothing to compile or package"
exit 0
