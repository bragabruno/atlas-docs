#!/usr/bin/env bash
# infra.sh — N/A for a documentation repo (no deploy/ Helm chart or Terraform to
# validate; infra manifests live in atlas-infra and the per-service repos).
# Present for parity with the other Atlas repos' build systems; skips cleanly.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/lib/colors.sh
source scripts/lib/colors.sh
# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
trap 'on_err "$LINENO" "$?"' ERR

skip "infra" "documentation repo — no deploy chart / Terraform in this repo"
exit 0
