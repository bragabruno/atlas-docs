#!/usr/bin/env bash
# test.sh — Gate 2 (XCUT-6): diagram validation. Every Mermaid (```mermaid in .md
# plus standalone .mmd) and PlantUML (.puml) source must render/parse, or the gate
# fails. Delegates to scripts/validate_diagrams.sh. Extra args are passed through
# as scan roots (default: diagrams). This is the "test" stage for a docs repo.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/lib/colors.sh
source scripts/lib/colors.sh
# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
trap 'on_err "$LINENO" "$?"' ERR

# Roots default to "diagrams"; callers may override (e.g. scripts/test.sh docs/diagrams).
roots=("$@")
[[ "${#roots[@]}" -eq 0 ]] && roots=(diagrams)

# mermaid-cli (mmdc, or npx that fetches it) renders ```mermaid + .mmd; PlantUML
# (jar via PLANTUML_JAR, or a `plantuml` binary, both needing java) checks .puml.
# validate_diagrams.sh already fails per-.puml when PlantUML is absent; if NO
# diagram tooling is present at all, skip cleanly rather than fail spuriously.
have_mermaid=0; have_plantuml=0
{ has_cmd mmdc || has_cmd npx; } && have_mermaid=1
{ [[ -n "${PLANTUML_JAR:-}" ]] || has_cmd plantuml; } && has_cmd java && have_plantuml=1
if [[ "$have_mermaid" -eq 0 && "$have_plantuml" -eq 0 ]]; then
  skip "diagram validation" "no diagram tooling (mermaid-cli/npx or plantuml+java) on PATH"
  exit 0
fi

run "diagram validation (XCUT-6: mermaid + plantuml)" \
  ./scripts/validate_diagrams.sh "${roots[@]}"
log_ok "diagram validation passed"
