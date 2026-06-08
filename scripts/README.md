# atlas-docs — build scripts

Single source of truth for lint & validation. Developers and CI run the **same**
scripts; `make ci` (or `./scripts/ci.sh`) runs the full gate locally, and the
Bitbucket pipeline calls the same per-stage scripts. atlas-docs is a Markdown +
diagrams repo (no application code), so the active gates are **lint**
(markdownlint) and **test** (diagram validation); the remaining stages exist for
parity with the other Atlas repos and skip cleanly.

| Script | Make target | What it does |
|---|---|---|
| `lint.sh` | `make lint` | Trunk → markdownlint (+ git-diff-check); markdownlint pinned in `.trunk/trunk.yaml` |
| `test.sh` | `make test` | diagram validation (XCUT-6) via `validate_diagrams.sh` — Mermaid (mmdc) + PlantUML |
| `coverage.sh` | `make coverage` | N/A — docs repo, no code to cover (skip) |
| `build.sh` | `make build` | N/A — docs repo, nothing to compile/package (skip) |
| `docker.sh` | `make docker` | N/A — docs repo, no Dockerfile (skip) |
| `infra.sh` | `make infra` | N/A — docs repo, no deploy chart / Terraform (skip) |
| `security.sh` | `make security` | secret scan (gitleaks via Trunk; advisory, `ATLAS_SECURITY_STRICT=1`) |
| `ci.sh` | `make ci` | runs all of the above, in order |
| `local.sh` | `make local` | N/A — docs repo, no server (skip) |
| `validate_diagrams.sh` | — | the diagram checker invoked by `test.sh` (also runs standalone) |

`lib/common.sh` + `lib/colors.sh` hold the shared helpers (logging, timing,
command checks, error trap). All scripts are bash with `set -Eeuo pipefail`,
shellcheck-clean, idempotent, and run on Linux + macOS. Stages that are N/A for
this repo, or whose tools are absent, print `↷ skip` and exit 0 — so the same
command works on a laptop and in CI.

## Diagram tooling

`test.sh` → `validate_diagrams.sh` validates every `` ```mermaid `` block (in
`.md`), every standalone `.mmd`, and every `.puml` under `diagrams/`:

- **Mermaid** — rendered with mermaid-cli (`mmdc`, or `npx -y @mermaid-js/mermaid-cli@<ver>`).
- **PlantUML** — syntax-checked with the PlantUML jar (`PLANTUML_JAR`) or a
  `plantuml` binary on `PATH` (both need a JRE). When PlantUML is absent,
  `validate_diagrams.sh` fails only on `.puml` files; when *no* diagram tooling is
  present at all, `test.sh` skips cleanly.

CI installs the pinned tool versions (JRE + Chromium for headless mmdc, pinned
PlantUML jar) in `bitbucket-pipelines.yml`, then invokes `scripts/test.sh`.
