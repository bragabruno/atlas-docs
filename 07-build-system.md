# 07 — Build System

> **Status:** Living document — update when the script set or a per-repo gate changes.
> **Last reviewed:** 2026-06-08

A single source of truth for build and validation across all eight Atlas repos:
**developers and CI run the exact same commands.** Every repo exposes the same
`make` targets and the same `scripts/` entrypoints; CI is orchestration-only and
calls those scripts, so "works on my machine" and "passes CI" converge.

---

## 1. Philosophy

- **One command, everywhere.** `make ci` runs the full gate locally and is what
  CI runs. No logic lives in pipeline YAML — only environment prep + a call to a
  versioned script.
- **Polyrepo-consistent.** Atlas is a polyrepo (ADR-013), not a monorepo, so there
  is no shared package to import. Each repo carries the **same script filenames**
  and a verbatim copy of `scripts/lib/`. A stage that is not applicable to a repo
  (or whose tool is absent) prints `↷ skip` and exits 0 — so the same `make ci`
  works on a laptop and in CI regardless of stack.
- **Fail fast, log clearly.** All scripts are bash with `set -Eeuo pipefail`, an
  `ERR` trap, timed/labelled stages, and explicit exit codes. They are
  shellcheck-clean and idempotent, and run on Linux + macOS (bash 3.2+).
- **Recommended gates are advisory until opted in.** Security/coverage/manifest
  scanners that need extra tooling skip cleanly when absent and warn (not fail) on
  findings, unless a strictness flag is set. This keeps the green pipeline green
  while surfacing the gap.

---

## 2. Layout (per repo)

```text
<repo>/
├── Makefile                    # make lint|test|coverage|build|docker|infra|security|ci|local
├── scripts/
│   ├── ci.sh                   # orchestrates every stage (the single source of truth)
│   ├── lint.sh                 # static checks (lint + typecheck + dep/age audit)
│   ├── test.sh                 # unit/validation tests
│   ├── coverage.sh             # coverage gate (recommended; advisory)
│   ├── build.sh                # build verification / contract export
│   ├── docker.sh               # container image build (when a Dockerfile exists)
│   ├── infra.sh                # deploy-manifest validation (helm/terraform)
│   ├── security.sh             # secret / CVE / config scans (advisory)
│   ├── local.sh                # run the component locally
│   └── lib/
│       ├── common.sh           # logging, timing, run/skip/require_cmd, error trap
│       └── colors.sh           # TTY/NO_COLOR-aware ANSI colors
└── bitbucket-pipelines.yml     # orchestration-only — steps call ./scripts/*.sh
```

`scripts/lib/common.sh` and `colors.sh` are **byte-identical across all repos**.
`common.sh` auto-prepends a project virtualenv (`.venv/bin`) to `PATH` when one
exists (local dev), and is inert where there is none (CI / non-Python repos).

---

## 3. Script responsibilities

| Script | Make target | Responsibility |
|---|---|---|
| `lint.sh` | `make lint` | Static correctness: linter + formatter + typecheck (+ dependency age/pin audit on Python repos). |
| `test.sh` | `make test` | The repo's test/validation suite. |
| `coverage.sh` | `make coverage` | Coverage gate (recommended). Skips when the coverage provider is absent. |
| `build.sh` | `make build` | Build verification (import/compile) and contract export where applicable. |
| `docker.sh` | `make docker` | Build the container image (skips when no Dockerfile or no daemon). |
| `infra.sh` | `make infra` | Validate deploy manifests (`helm lint`/`template`, `terraform validate`). |
| `security.sh` | `make security` | Secret + dependency-CVE + config scans (advisory; see §6). |
| `ci.sh` | `make ci` | Run every stage in order. What CI runs. |
| `local.sh` | `make local` | Run the component locally for inner-loop dev. |

Helpers in `lib/common.sh`: `log_info/step/ok/warn/error`, `run <label> <cmd…>`
(timed, pass/fail), `skip <stage> <reason>`, `require_cmd` (fail fast), `has_cmd`
(optional stages), `on_err` (trap reporter).

---

## 4. Per-repo stage matrix

Linters are run through **Trunk** (the single source of truth for tool versions;
see ADR-021 context and the repo `.trunk/trunk.yaml`). `✓` = active, `↷` = skips.

| Repo | lint | test | coverage | build | docker | infra | security | extras |
|---|---|---|---|---|---|---|---|---|
| `atlas-gateway` | ruff + pyright + dep-audit | pytest | ↷ (pytest-cov) | import + OpenAPI export/drift | ✓ Dockerfile | helm render | ✓ | — |
| `atlas-agent-runtime` | ruff + pyright + dep-audit | pytest | ↷ | import | ✓ Dockerfile | helm render | ✓ | `.github/workflows/ci.yml` (GH Actions) |
| `atlas-mcp-doc-search` | ruff + pyright + dep-audit | pytest | ↷ | import | ✓ Dockerfile | helm render | ✓ | — |
| `atlas-mcp-citations` | ruff + pyright + dep-audit | pytest | ↷ | import | ✓ Dockerfile | helm render | ✓ | — |
| `atlas-prompts` | ruff + pyright + dep-audit + schema-lint | pytest | ↷ | import | ↷ (not a service) | ↷ (no chart) | ✓ | `eval.sh` (Gate-2) |
| `atlas-frontend` | eslint + prettier + tsc | vitest | ↷ (@vitest/coverage) | ng build | ✓ Dockerfile | helm render | npm audit | — |
| `atlas-infra` | terraform fmt + tflint | per-dir `terraform validate` | ↷ | ↷ | ↷ | helm lint platform charts | Checkov + Trivy + gitleaks | extends existing cloud `Makefile` |
| `atlas-docs` | markdownlint | `validate_diagrams.sh` (Mermaid + PlantUML) | ↷ | ↷ | ↷ | ↷ | gitleaks | — |

Notes:

- **`atlas-prompts`** adds `scripts/eval.sh` — the eval quality gate (Gate-2). It
  runs `gate.py` only when `CANDIDATE_RUN_ID` (+ `BASELINE_EVAL_RUN_ID`, or
  `GATE_NO_BASELINE=1`) are set; otherwise it skips.
- **`atlas-infra`** **extends** its pre-existing `Makefile` (cloud `*-up/down`,
  `destroy`, etc.) — the build-system targets are added alongside, never replacing
  the deploy targets. `infra.sh` renders the `platform/` charts; `helm template`
  is advisory (`ATLAS_INFRA_STRICT=1` to enforce) because the MLflow/Elasticsearch
  wrapper charts are deployed with runtime `--set` injection and don't render from
  static overlays alone.
- **`atlas-agent-runtime`** and **`atlas-prompts`** also carry a GitHub Actions
  `ci.yml` (SHA-pinned actions) that mirrors the Bitbucket Gate-1 on the GitHub
  remote, plus a Trunk-pin age audit in `dep_audit.py` and a Trunk CLI sha256
  lock — all invoked through the same scripts.

---

## 5. Execution order & local usage

`ci.sh` runs stages in this order (each skips cleanly when N/A):

```text
lint → test → coverage → build → infra → docker → security
```

Common local commands:

```bash
make ci            # the full gate (what CI runs)
make lint          # just static checks
make test          # just tests
make local         # run the component locally
ATLAS_COV_MIN=80 make coverage          # enforce a coverage floor (when provider installed)
ATLAS_SECURITY_STRICT=1 make security   # make advisory scans blocking
ATLAS_INFRA_STRICT=1 make infra         # (infra) make helm template render blocking
```

Environment knobs:

| Variable | Default | Effect |
|---|---|---|
| `ATLAS_COV_MIN` | `0` | Coverage fail-under threshold (%). |
| `ATLAS_SECURITY_STRICT` | `0` | `1` makes security findings fail the gate. |
| `ATLAS_INFRA_STRICT` | `0` | (infra) `1` makes `helm template` render blocking. |
| `ATLAS_IMAGE` | `<repo>:dev` | Image tag for `docker.sh`. |
| `PORT` | per repo | Port for `local.sh`. |
| `CANDIDATE_RUN_ID` / `BASELINE_EVAL_RUN_ID` | unset | (prompts) drive `eval.sh` Gate-2. |

---

## 6. CI usage

- **Bitbucket Pipelines** (`bitbucket-pipelines.yml`) is the Enhesa-mirror
  reference. Each gate step does only env prep + a call to `./scripts/<stage>.sh`.
- **GitHub Actions** (`.github/workflows/ci.yml`, present on the Python service
  repos) runs the executable Gate-1 on the GitHub remote with SHA-pinned actions.
- **Trunk** is git-native and fetches its pinned tools at runtime, so the lint
  step needs `git`, `curl`, and network (still zero LLM/API spend).

---

## 7. Recommended quality gates (advisory; opt-in)

Wired into the scripts but off by default until the tooling/threshold is adopted:

- **Coverage thresholds** — `pytest-cov` (Python) / `@vitest/coverage-v8`
  (frontend); enable with `ATLAS_COV_MIN`.
- **Dependency CVE scanning** — `pip-audit` (Python) / `npm audit` (frontend),
  complementing the existing 14-day age audit.
- **Container & filesystem scanning** — `trivy fs` / `trivy image`.
- **Kubernetes manifest schema** — `kubeconform` over rendered Helm output.
- **Secret scanning** — `gitleaks` via Trunk (enabled in `atlas-infra`; can be
  enabled per repo in `.trunk/trunk.yaml`).
- **SBOM generation** — `syft` (future).

Flip all advisory scans to blocking with `ATLAS_SECURITY_STRICT=1`.

---

## 8. Discovered gaps (addressed during rollout)

- **Missing Dockerfiles** — the four Python services shipped `deploy/` Helm charts
  referencing images nothing built. Added multi-stage, non-root Dockerfiles
  (pinned base, runtime deps only).
- **Broken `.dockerignore`** (`atlas-frontend`) — excluded all of `deploy/` while
  the Dockerfile copies `deploy/nginx/nginx.conf`; the image build was broken.
  Fixed with a negation.
- **`validate_diagrams.sh`** (`atlas-docs`) — bash-3.2 empty-array crash under
  `set -u`, and a hard failure when PlantUML is absent; now skips advisory locally
  while CI still validates `.puml` via the pinned jar.
- **No coverage threshold / no CVE scan** anywhere — now available as opt-in gates.

---

## 9. Troubleshooting

- **`trunk: command not found`** — install via `curl -fsSL https://get.trunk.io | bash`.
  CI installs it in the lint step.
- **`docker build` skipped** — the daemon isn't running, or the repo has no
  Dockerfile (`atlas-prompts`/`atlas-infra`/`atlas-docs` have none by design).
- **`helm template` fails on required values** — env-injected fields (e.g.
  `secrets.tenantId` from a Terraform output) are supplied as dummies for the
  render check; see `infra.sh`.
- **`pip-audit` reports many CVEs** — it scans the active environment (which may
  include unrelated tooling), not just the repo's pinned deps; it is advisory.
- **Local tool versions differ from CI** — `common.sh` prefers `.venv/bin`
  locally; Trunk pins the linter versions for both, so lint results match.
