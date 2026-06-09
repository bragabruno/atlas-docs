#!/usr/bin/env bash
# security.sh — secret scan only (gitleaks via Trunk), ADVISORY by default: a
# missing tool skips, findings warn. Set ATLAS_SECURITY_STRICT=1 to fail the gate
# on findings. A docs repo has no dependency manifests / image, so CVE & fs scans
# (pip-audit / trivy) are N/A here.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/lib/colors.sh
source scripts/lib/colors.sh
# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
trap 'on_err "$LINENO" "$?"' ERR

strict="${ATLAS_SECURITY_STRICT:-0}"
failures=0

# soft <label> <cmd...> — run a scanner; under non-strict a failure only warns.
soft() {
  local label="$1"; shift
  if run "$label" "$@"; then
    return 0
  fi
  if [[ "$strict" == "1" ]]; then
    failures=$((failures + 1))
  else
    log_warn "${label}: findings (advisory; set ATLAS_SECURITY_STRICT=1 to enforce)"
  fi
}

if ! has_cmd trunk; then
  skip "secret scan" "trunk not installed (recommended: gitleaks via Trunk)"
elif ! grep -qE '^[[:space:]]*-[[:space:]]*gitleaks([@[:space:]]|$)' .trunk/trunk.yaml 2>/dev/null; then
  # gitleaks is available in Trunk but not enabled in .trunk/trunk.yaml (which is
  # tuned for the markdownlint prose gate and intentionally left unchanged). Skip
  # cleanly rather than fail on `--filter=gitleaks` for a non-enabled linter.
  skip "secret scan" "gitleaks not enabled in .trunk/trunk.yaml (advisory; add it to lint.enabled to activate)"
else
  soft "secret scan (trunk → gitleaks)" trunk check --all --no-progress --filter=gitleaks
fi

if [[ "$failures" -gt 0 ]]; then
  log_error "security: ${failures} scanner(s) reported findings (strict mode)"
  exit 1
fi
log_ok "security stage complete"
