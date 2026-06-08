#!/usr/bin/env bash
# ci.sh — the single source of truth. Devs run this locally; CI runs the same
# stage scripts (parallelized per stage in bitbucket-pipelines.yml). Stages that
# are N/A for this docs repo, or whose tools are absent, skip cleanly — so the
# same command works on a laptop and in CI.
#
# Active gates for atlas-docs: lint (Trunk → markdownlint) + test (XCUT-6 diagram
# validation). coverage/build/infra/docker are N/A and skip; security is advisory.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/lib/colors.sh
source scripts/lib/colors.sh
# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
trap 'on_err "$LINENO" "$?"' ERR

log_step "atlas-docs — full CI gate"
start=$(date +%s)
scripts/lint.sh
scripts/test.sh
scripts/coverage.sh
scripts/build.sh
scripts/infra.sh
scripts/docker.sh
scripts/security.sh
log_ok "CI passed ($(( $(date +%s) - start ))s)"
