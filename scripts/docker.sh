#!/usr/bin/env bash
# docker.sh — N/A for a documentation repo (no Dockerfile; nothing ships as an
# image). Present for parity with the other Atlas repos' build systems; skips
# cleanly.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/lib/colors.sh
source scripts/lib/colors.sh
# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
trap 'on_err "$LINENO" "$?"' ERR

skip "docker build" "documentation repo — no Dockerfile / image to build"
exit 0
