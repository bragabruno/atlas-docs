# Atlas — Backlog (Linear-ready)

This is the complete ticket breakdown for Atlas. Each **epic** maps to a phase in [`../06-roadmap-and-milestones.md`](../06-roadmap-and-milestones.md); each **story** below becomes one Linear issue under its epic.

## Changes in this revision (framework adoption — ADR-016…020, 2026-06-07)

Following the framework evaluation (`../research/framework-evaluation.md`), these decisions are ratified and reflected below: **layered architecture + DI** (ADR-016, new **GW-22** — done), **DeepEval** metrics for the eval gate (ADR-017, REG-8), **Angular Signals + Vitest** for the frontend (ADR-018, FE-1/FE-5), **Skaffold** umbrella dev-loop + `terraform test`/Checkov/TFLint/Trivy (ADR-019, INF-15), and a **FastAPI trigger surface** for the agent runtime (ADR-020, new **AGT-16**). Hand-rolled agent loop reaffirmed (ADR-006) with **Pydantic AI** as the sanctioned fallback.

## Changes in this revision (polyrepo / frontend / diagrams reconciliation)

- **Polyrepo:** every story now carries a `repo:` tag. The monorepo `INF-1` is reframed as per-repo scaffolding; CI is per-repo (a shared template).
- **`atlas-prompts` repo (8th repo):** owns git-tracked prompt templates + agent YAMLs + the eval runner + golden-set refs, and hosts the **eval-gate** pipeline. `REG-*` and prompt/agent ownership moved here.
- **Contracts:** the gateway publishes an **OpenAPI spec as the source of truth**; the frontend codegens TS types, Python services use a generated client (new `GW-21`).
- **Charts:** each service repo owns its own `deploy/` Helm chart; platform/third-party charts (Qdrant, Kafka, Elasticsearch, MLflow, OTel) live in `atlas-infra`.
- **Frontend:** new **`FE`** epic for the Angular `atlas-frontend` RegDoc Q&A app (was missing entirely).
- **Fixes:** `GRD-9` no longer has the backwards `AGT-9` dependency (the check is built against the contract; `AGT-12` does the live wiring); `GW-14` cost formula corrected to the **four** token fields; doc paths point to `atlas-docs/`; `INF-16` deps made explicit; new diagram-CI story (`XCUT-6`).

## How to read / conventions

- **ID** (e.g. `GW-3`) is a stable doc-local reference for dependencies. Linear assigns its own keys; keep these IDs as the issue title prefix for traceability.
- **Meta line:** `area · type · phase · repo · Points · Depends on`.
- **Points:** Fibonacci (1, 2, 3, 5, 8) — rough effort, not time.
- **Done when:** acceptance criteria — not closeable until all bullets hold.
- **Label taxonomy:**
  - `phase:p0…p5`
  - `area:infra | gateway | registry | evals | guardrails | agent | mcp | data | observability | cicd | security | frontend`
  - `type:feature | chore | spike | docs | test`
  - `repo:atlas-docs | atlas-gateway | atlas-agent-runtime | atlas-mcp-doc-search | atlas-mcp-citations | atlas-frontend | atlas-infra | atlas-prompts` (`repo:all` = cross-cutting template applied to every repo)
- **Global Definition of Done (Python repos):** ruff + pyright(strict) clean · pytest passing (offline via `MockProvider`/fakeredis) · no secrets in code/images/tests · pinned deps (≥14 days old) · small reviewable diff.
- **Global Definition of Done (atlas-frontend):** eslint + `tsc --noEmit` clean · unit tests (Vitest — ADR-018) passing · no hardcoded keys/secrets · TS API types generated from the gateway OpenAPI spec (not hand-written).

### Epic summary

| Epic   | Phase | Title                        | Primary repo(s)                  | Stories | Points |
|--------|-------|------------------------------|----------------------------------|---------|--------|
| `INF`  | P0    | Infra foundation (Azure/AKS) | atlas-infra (+all)               | 17      | 74     |
| `GW`   | P1    | LLM Gateway core             | atlas-gateway                    | 23      | 93     |
| `REG`  | P2    | Prompt registry + eval gate  | atlas-prompts (+gateway)         | 14      | 64     |
| `GRD`  | P3    | Guardrails                   | atlas-gateway                    | 12      | 49     |
| `AGT`  | P4    | Agent runtime + MCP          | atlas-agent-runtime, atlas-mcp-* | 16      | 80     |
| `FE`   | P1→P4 | Frontend (RegDoc Q&A app)    | atlas-frontend                   | 9       | 27     |
| `POL`  | P5    | Polish                       | atlas-gateway, atlas-infra       | 7       | 36     |
| `XCUT` | —     | Cross-cutting / hardening    | atlas-docs, all                  | 7       | 23     |

**Totals: 105 stories · ~446 points.** Suggested first slice (M1–M3): `INF-1 → INF-3..16`, then `GW-1..GW-9` + `GW-21` (gateway online with Mock + published contract), then `REG` (the eval-gate demo). The basic chat UI (`FE-1..FE-5`) can start once `GW-7` (SSE) lands.

---

## EPIC `INF` — Infra foundation (Azure / AKS) · phase:p0

> Goal: reproducible Azure footprint + AKS dev loop + all platform dependencies running. Exit: `make cloud-up ENV=dev` (in atlas-infra) works, every repo's CI green, data services reachable in-cluster.

### INF-1 — Scaffold all repos + tooling (polyrepo)

`area:infra · type:chore · phase:p0 · repo:all · Points: 3 · Depends on: —`
For each of the 8 repos: README, `.gitignore`, language tooling (Python repos: `pyproject` + ruff + pyright strict + pytest; atlas-frontend: Angular + eslint + tsc; atlas-infra: Terraform fmt/validate; atlas-prompts: prompt/agent schema lint), pre-commit, and `git init` + initial commit. *(Partly done: repos, READMEs, .gitignores, and diagrams already exist.)*
**Done when:** every repo has tooling that runs clean on an empty/placeholder target; all repos are git-initialized; layout matches `atlas-docs/02` + `atlas-docs/04`.

### INF-2 — Shared Bitbucket PR pipeline template (Gate 1)

`area:cicd · type:feature · phase:p0 · repo:all · Points: 3 · Depends on: INF-1`
A reusable `bitbucket-pipelines.yml` PR template per repo: Python repos run ruff → pyright(strict) → pytest with `MockProvider` + fakeredis + ephemeral Postgres service container; atlas-frontend runs eslint → tsc → unit tests. Zero API spend; not the cluster.
**Done when:** a PR in each repo runs its pipeline green on a placeholder; required status check configured per repo.

### INF-3 — Terraform state backend bootstrap

`area:infra · type:chore · phase:p0 · repo:atlas-infra · Points: 2 · Depends on: —`
Azure Storage account + blob container for Terraform state with lease locking; one-shot bootstrap documented (chicken/egg). `backend.tf` wired.
**Done when:** `terraform init` succeeds against the remote backend; state lock verified.

### INF-4 — Terraform module: network

`area:infra · type:feature · phase:p0 · repo:atlas-infra · Points: 3 · Depends on: INF-3`
VNet, subnets (system/workload/data), NSGs, private endpoints where applicable.
**Done when:** `terraform plan/apply` clean; subnets and NSGs created; documented CIDR plan.

### INF-5 — Terraform module: AKS + Workload Identity

`area:infra · type:feature · phase:p0 · repo:atlas-infra · Points: 5 · Depends on: INF-4`
AKS cluster (system + workload node pools, small burstable SKUs for dev), OIDC issuer + Workload Identity enabled, core add-ons.
**Done when:** `kubectl get nodes` ready; Workload Identity OIDC issuer present; node pools match the cost-control sizing.

### INF-6 — Terraform module: identity (managed identities + federation)

`area:infra · type:feature · phase:p0 · repo:atlas-infra · Points: 3 · Depends on: INF-5`
Per-service user-assigned managed identities + federated credentials + least-privilege role assignments (gateway→Key Vault/Blob read; eval-runner→Blob RW; etc.).
**Done when:** each service identity exists with scoped roles; federation maps to its K8s service account.

### INF-7 — Terraform module: secrets (Key Vault + CSI)

`area:infra · type:feature · phase:p0 · repo:atlas-infra · Points: 3 · Depends on: INF-6`
Azure Key Vault + Secrets Store CSI driver install + `SecretProviderClass` templates; secret *references* only (values seeded out-of-band).
**Done when:** a test pod mounts a secret from Key Vault via CSI using its workload identity; no secret in any manifest.

### INF-8 — Terraform module: data (Azure PostgreSQL + Redis)

`area:infra · type:feature · phase:p0 · repo:atlas-infra · Points: 3 · Depends on: INF-4`
Azure Database for PostgreSQL Flexible Server (dev SKU, single-AZ) + Redis (Azure Cache or in-cluster for dev).
**Done when:** a pod connects to both using Key Vault-sourced creds; `psql` reachable in-cluster.

### INF-9 — Terraform module: storage (Blob + ACR)

`area:infra · type:feature · phase:p0 · repo:atlas-infra · Points: 2 · Depends on: INF-3`
Blob containers (golden-sets, trace-archive, artifacts; versioning + lifecycle) + ACR (scan-on-push, retention).
**Done when:** `terraform apply` clean; ACR push works; Blob containers created with lifecycle.

### INF-10 — Deploy Qdrant on AKS

`area:data · type:feature · phase:p0 · repo:atlas-infra · Points: 3 · Depends on: INF-5`
Qdrant Helm chart (platform chart in atlas-infra); create `doc_chunks` + `semantic_cache` collections (config per atlas-docs/03).
**Done when:** Qdrant reachable in-cluster; both collections exist with correct vector/HNSW config.

### INF-11 — Deploy Kafka + create topics

`area:data · type:feature · phase:p0 · repo:atlas-infra · Points: 5 · Depends on: INF-5`
Kafka via Azure Event Hubs Kafka endpoint (dev) or Strimzi; create topics `atlas.calls.v1`, `atlas.spans.v1`, `atlas.shadow.v1`, `atlas.eval.requests.v1` with documented partitions/retention.
**Done when:** a producer/consumer smoke test round-trips a message on each topic.

### INF-12 — Deploy Elasticsearch on AKS

`area:data · type:feature · phase:p0 · repo:atlas-infra · Points: 3 · Depends on: INF-5`
Elasticsearch Helm chart; index template for the doc corpus (BM25) + log index.
**Done when:** ES reachable; corpus index template applied; a test doc is indexed and searchable.

### INF-13 — OTel Collector → Splunk pipeline

`area:observability · type:feature · phase:p0 · repo:atlas-infra · Points: 3 · Depends on: INF-5`
Deploy OTel Collector (Deployment/DaemonSet) exporting traces/metrics/logs to Splunk (OTLP/HEC). Pin `OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental`.
**Done when:** a test span/metric from a sample pod appears in Splunk.

### INF-14 — Deploy MLflow

`area:observability · type:feature · phase:p0 · repo:atlas-infra · Points: 3 · Depends on: INF-8, INF-9`
MLflow tracking server on AKS, backing store in Azure PG, artifacts in Blob.
**Done when:** MLflow UI reachable; a test run logs params/metrics/artifacts.

### INF-15 — Umbrella dev loop (Skaffold) + placeholder gateway

`area:cicd · type:feature · phase:p0 · repo:atlas-infra · Points: 5 · Depends on: INF-5, INF-9 · ADR-019`
An **umbrella** Skaffold config in atlas-infra that builds each service from its repo → ACR → Helm upgrade → dev namespace (file-sync), referencing the per-service `deploy/` charts. Includes a base gateway placeholder serving a healthcheck behind ingress.
**Done when:** editing a service file auto-redeploys it; placeholder gateway reachable via ingress URL; the loop spans the multiple repos.

### INF-16 — Env composition + one-command up + cost controls

`area:infra · type:feature · phase:p0 · repo:atlas-infra · Points: 3 · Depends on: INF-4, INF-5, INF-6, INF-7, INF-8, INF-9, INF-10, INF-11, INF-12, INF-13, INF-14, INF-15`
`envs/dev` root composing all modules + `make cloud-up ENV=dev` / `make down` / `make destroy`; scale-to-zero CronJob; destroy-when-idle runbook. Deploys services from published ACR images (per-repo `deploy/` charts).
**Done when:** a clean subscription reaches a working dev cluster via one command; teardown documented.

### INF-17 — Optional local offline dev loop (docker-compose)

`area:cicd · type:feature · phase:p0 · repo:atlas-infra · Points: 3 · Depends on: INF-15 · ADR-023`
Optional local **offline** dev loop via `atlas-infra/local/compose.dev.yaml` (`make local-up` / `make local-down`) — free local equivalents for every paid service (Postgres, Valkey, Qdrant, OpenSearch, Redpanda, Azurite, lowkey-vault, MLflow, OpenObserve) + gateway + 2 MCP servers + frontend — **alongside, not replacing,** the Skaffold/AKS loop (INF-15). Adds the previously-missing gateway + agent-runtime Dockerfiles. See [`../research/local-mock-stack.md`](../research/local-mock-stack.md). *(In progress — compose + ADR-023 doc merged; frontend↔gateway needs GW-23 CORS; agent-runtime joins once containerized. BRA-875.)*
**Done when:** `make local-up` brings the full stack up; the SPA→gateway chat works end-to-end; CI smoke-tests `docker compose config`.

---

## EPIC `GW` — LLM Gateway core · phase:p1 · repo:atlas-gateway

> Goal: OpenAI-compatible API in front of OpenAI/Anthropic/Google with accounting, caching, limits, traces, and a published contract. Exit: <50ms p95 overhead (Mock), offline suite green, OpenAPI spec published.

### GW-1 — Provider Protocol + result types

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 2 · Depends on: INF-1`
Define `Provider` Protocol (`async chat(...) -> ChatResult`, `async models()`) + pydantic result/usage types incl. the 4 token fields (input, output, cache_creation_input_tokens, cache_read_input_tokens).
**Done when:** the protocol + types exist with full type coverage; documented in atlas-docs/03.

### GW-2 — MockProvider

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 2 · Depends on: GW-1`
Deterministic offline provider (chat + stream + usage) for tests/CI and as failover-of-last-resort in dev.
**Done when:** unit tests drive chat + streaming entirely offline; deterministic outputs.

### GW-3 — AnthropicProvider

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-1`
Implement against the official `anthropic` SDK: chat + streaming, map usage incl. `cache_creation_input_tokens`/`cache_read_input_tokens`, `count_tokens`.
**Done when:** key-gated integration test returns a valid `ChatResult` with all 4 token fields mapped; offline suite still green.

### GW-4 — OpenAIProvider

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-1`
Implement against the official `openai` SDK: chat + streaming + usage + token counting.
**Done when:** key-gated integration test passes; usage mapped; offline suite green.

### GW-5 — GoogleProvider (Gemini)

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-1`
Implement against the Google Gemini SDK: chat + streaming + usage + token counting.
**Done when:** key-gated integration test passes; usage mapped; offline suite green.

### GW-6 — `/v1/chat/completions` (non-stream)

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 5 · Depends on: GW-2`
OpenAI-compatible non-streaming endpoint + request/response models (atlas-docs/03), per-key bearer auth.
**Done when:** `curl model=mock` returns a spec-shaped `chat.completion`; contract test green.

### GW-7 — Streaming SSE

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-6`
SSE `chat.completion.chunk` deltas terminated by `data: [DONE]`.
**Done when:** a streaming client receives deltas + `[DONE]`; usage emitted on final chunk.

### GW-8 — `/v1/models` + `/v1/embeddings`

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-6`
Models listing (from alias table) + embeddings passthrough (for ingestion + semantic cache).
**Done when:** both endpoints return spec-shaped responses; embeddings round-trip via Mock + one real provider.

### GW-9 — Schema + migrations: aliases/keys/budgets/calls

`area:data · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: INF-8`
Alembic migrations for `model_aliases`, `api_keys`, `budgets`, `call_records` (atlas-docs/03); seed alias rows.
**Done when:** migrations apply on Azure PG; alias seed present; rollback tested.

### GW-10 — Alias routing resolver

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-9, GW-1`
Resolve alias → primary + fallback model/provider, with per-key overrides.
**Done when:** routing chooses the configured primary; per-key override respected; unit-tested.

### GW-11 — Retry with backoff (tenacity)

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 2 · Depends on: GW-10`
Exponential backoff + jitter on transient provider errors/timeouts.
**Done when:** injected transient failures retry then succeed; non-retryable errors surface immediately.

### GW-12 — Per-provider circuit breaker + failover

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 5 · Depends on: GW-11`
Redis-backed shared breaker (closed/open/half-open) per provider; failover to fallback on 5xx/timeout/open.
**Done when:** repeated failures open the breaker across replicas; traffic fails over; recovery via half-open verified.

### GW-13 — Exact cache (Redis)

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-6`
Normalized-request hash → Redis; key includes prompt version + tenant; TTL.
**Done when:** identical request is served from cache (hit metric); key composition prevents cross-tenant/version reuse.

### GW-14 — Accounting recorder + cost formula

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-9`
Async `call_records` insert (asyncpg) with the cost formula over the **four** token fields — `input_tokens` + `output_tokens` priced from the alias row, plus `cache_creation_input_tokens` (~1.25×) and `cache_read_input_tokens` (~0.1×) recorded separately (atlas-docs/03).
**Done when:** every call writes a row with correct cost; cache-read calls cost ~0.1× input; idempotent on retry.

### GW-15 — Accounting events → Kafka `atlas.calls.v1`

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-14, INF-11`
Publish per-call accounting events (key = api_key) for downstream dashboards/drift.
**Done when:** a consumer reads well-formed events for every call; backpressure handled without blocking the request path.

### GW-16 — Token-bucket rate limiting → 429

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-13`
Redis Lua token bucket per key; spec-shaped 429 on exhaustion.
**Done when:** load past the limit returns 429 with the documented body; limits reset correctly.

### GW-17 — Monthly budget enforcement → 429 + 80% alert

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-14`
Hard per-key monthly cap → 429; alert signal at 80%.
**Done when:** exceeding the cap returns 429; an 80% alert metric fires; budgets reset on cycle.

### GW-18 — OTel GenAI spans → Splunk

`area:observability · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: INF-13, GW-6`
Instrument the request path with GenAI semconv attrs (atlas-docs/04); export to Splunk.
**Done when:** each call produces a span with `gen_ai.*` attrs visible in Splunk.

### GW-19 — Gateway Helm chart (in-repo `deploy/`) + Rollout

`area:cicd · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: INF-15`
Production-shaped Helm chart in `atlas-gateway/deploy/` (HPA, probes, CSI secrets, Argo Rollouts `Rollout` resource ready for canary).
**Done when:** `helm upgrade` deploys; pod healthy behind ingress; Rollout object present (canary wired in POL-2).

### GW-20 — Gateway integration tests + p95 budget check

`area:test · type:test · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-7, GW-12, GW-16, GW-17`
End-to-end tests via Mock + a load test asserting <50ms p95 gateway overhead.
**Done when:** suite covers routing/failover/cache/limits/budget; p95 overhead < 50ms in the load test.

### GW-21 — OpenAPI spec (source of truth) + client codegen

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-6, GW-8`
Publish the gateway's OpenAPI spec as the cross-repo contract; generate a TS types package (consumed by atlas-frontend) and a Python client (consumed by atlas-agent-runtime + atlas-prompts eval-runner). CI fails if the committed spec drifts from the code.
**Done when:** the spec is published as a build artifact; TS + Python clients generate from it; a drift check guards the spec in CI.

### GW-22 — Layered architecture + DI skeleton

`area:gateway · type:chore · phase:p1 · repo:atlas-gateway · Points: 3 · Depends on: GW-6 · ADR-016`
Layered service spine (api → services → repositories → domain) + FastAPI `Depends` DI (`api/deps.py`) + `providers/registry.py`; capability modules as adapters the service layer composes. Canonical reference for every Python service; behavior-preserving. *(Done — gateway refactored, 14 tests green; BRA-872.)*
**Done when:** gateway follows api/services/repositories/domain; DI via deps.py; `UnknownModelError`→404 in the controller; tests green (ruff + pyright strict + pytest).

### GW-23 — Config-gated gateway CORS

`area:gateway · type:feature · phase:p1 · repo:atlas-gateway · Points: 1 · Depends on: GW-1`
Optional, config-gated CORS (`ATLAS_CORS_ALLOW_ORIGINS`, default empty → no middleware added; same default-OFF philosophy as the cache/rate-limit gates) so browser SPAs (the INF-17 local frontend) can call the gateway cross-origin. `allow_credentials=False` (auth is header-based). *(In review — atlas-gateway #23; 321 tests green. BRA-876.)*
**Done when:** a configured origin can call the gateway cross-origin; the default-off path is unchanged; tests cover it.

---

## EPIC `REG` — Prompt registry + eval gate · phase:p2

> Goal: prompts versioned + promoted like code; a bad prompt can't reach production. The "money demo". Templates/agents/evals live in **atlas-prompts**; the runtime registry (DB + resolution) lives in **atlas-gateway**.

### REG-1 — Schema + migrations: prompts/prompt_versions

`area:data · type:feature · phase:p2 · repo:atlas-gateway · Points: 3 · Depends on: GW-9`
Alembic for `prompts`, `prompt_versions` (semver, template, params_schema, model_alias, status enum) in the gateway's DB.
**Done when:** migrations apply; status enum enforced; indexes per atlas-docs/03.

### REG-2 — Git-tracked prompt templates + agent YAMLs (atlas-prompts)

`area:registry · type:feature · phase:p2 · repo:atlas-prompts · Points: 2 · Depends on: INF-1`
`prompts/<name>/<semver>/{template.jinja, meta.yaml}` + `agents/<name>.yaml` layout in atlas-prompts + a seed prompt + RegDoc agent def.
**Done when:** templates + agent YAMLs live in atlas-prompts; CI validates template/meta/agent schema.

### REG-3 — Registry resolve + render

`area:registry · type:feature · phase:p2 · repo:atlas-gateway · Points: 3 · Depends on: REG-1`
`resolve(prompt_ref|alias) -> resolved config`; params_schema validation; Jinja render.
**Done when:** resolve returns the correct version by status; invalid params fail fast; render unit-tested.

### REG-4 — Gateway consumes `prompt_ref`

`area:gateway · type:feature · phase:p2 · repo:atlas-gateway · Points: 3 · Depends on: REG-3, GW-6`
Gateway resolves `prompt_ref` at request time; clients never embed prompt text; cache key includes resolved version.
**Done when:** a request with `prompt_ref` renders + routes correctly; accounting records the prompt version.

### REG-5 — Promotion state machine + rollback

`area:registry · type:feature · phase:p2 · repo:atlas-gateway · Points: 3 · Depends on: REG-1`
draft→candidate→production transitions; production pointer; instant rollback (pointer flip).
**Done when:** transitions enforce rules; rollback flips production and the next call uses the prior version.

### REG-6 — Schema + migrations: eval_runs/eval_results

`area:data · type:feature · phase:p2 · repo:atlas-prompts · Points: 2 · Depends on: REG-1`
Alembic for `eval_runs`, `eval_results` (atlas-docs/03), owned by the eval-runner; FK to `prompt_versions`.
**Done when:** migrations apply; FK to prompt_versions; indexes present.

### REG-7 — Golden datasets format + Blob versioning

`area:evals · type:feature · phase:p2 · repo:atlas-prompts · Points: 3 · Depends on: INF-9`
JSONL golden-set schema (input, expected properties, citation requirements) + versioned storage in Blob; refs tracked in atlas-prompts.
**Done when:** a versioned dataset loads by version; schema validated; immutable versions.

### REG-8 — Eval runner + core metrics

`area:evals · type:feature · phase:p2 · repo:atlas-prompts · Points: 5 · Depends on: REG-7, GW-6, GW-21`
Runner executes a prompt_version over a dataset via the gateway (using the generated Python client); metrics: exact match, semantic match, citation validity %, cost/latency deltas.
**Done when:** a run writes `eval_results`; metrics computed deterministically; runs offline via Mock.

### REG-9 — LLM-as-judge metric (advisory)

`area:evals · type:feature · phase:p2 · repo:atlas-prompts · Points: 3 · Depends on: REG-8`
Judge model pinned, temperature 0, rubric versioned in the registry, scored over samples with a margin; marked advisory (non-blocking).
**Done when:** judge scores logged; flakiness bounded by multi-sample margin; clearly advisory in the gate.

### REG-10 — MLflow tracking integration

`area:observability · type:feature · phase:p2 · repo:atlas-prompts · Points: 3 · Depends on: REG-8, INF-14`
Log eval runs/metrics/params/artifacts to MLflow keyed by prompt_version + dataset_version.
**Done when:** each run appears in MLflow with comparable metrics across versions.

### REG-11 — Regression gate (`gate.py`)

`area:evals · type:feature · phase:p2 · repo:atlas-prompts · Points: 3 · Depends on: REG-8`
Compare a candidate's metrics to the production baseline; non-zero exit on regression beyond thresholds; blocking vs advisory split.
**Done when:** a regressed candidate exits non-zero; an improved one exits zero; thresholds configurable.

### REG-12 — Eval-gate pipeline (Gate 2) in atlas-prompts

`area:cicd · type:feature · phase:p2 · repo:atlas-prompts · Points: 5 · Depends on: REG-11, INF-2`
atlas-prompts' `bitbucket-pipelines.yml` triggers on `prompts/**` + `agents/**`; runs the eval runner against a seeded test DB; blocks merge on regression; posts the metric diff to the PR.
**Done when:** a regressing PR shows a red required check + a metric-diff comment; a passing PR is green.

### REG-13 — Promotion gated on evals

`area:registry · type:feature · phase:p2 · repo:atlas-gateway · Points: 3 · Depends on: REG-5, REG-11`
candidate→production allowed only when the eval gate is green for that version (server-side enforcement in the gateway registry).
**Done when:** promotion is rejected when evals fail; allowed when green; enforced server-side.

### REG-14 — Demo: blocked-PR + rollback

`area:docs · type:docs · phase:p2 · repo:atlas-prompts · Points: 2 · Depends on: REG-12, REG-13`
Scripted demo (regressed prompt → red gate → fix → green → promote → rollback) + README.
**Done when:** the demo runs end-to-end and is documented with screenshots/commands.

---

## EPIC `GRD` — Guardrails · phase:p3 · repo:atlas-gateway

> Goal: enforced pre/post checks as a platform service; fail-fast, metered.

### GRD-1 — Guardrail chain framework

`area:guardrails · type:feature · phase:p3 · repo:atlas-gateway · Points: 3 · Depends on: GW-6`
Ordered pre/post middleware chain, per-route config, explicit `GuardrailRejection`, fail-fast (never silent).
**Done when:** checks run in order per route; a rejection returns an explicit, documented error; config-driven.

### GRD-2 — PII regex fast-path

`area:guardrails · type:feature · phase:p3 · repo:atlas-gateway · Points: 2 · Depends on: GRD-1`
Regex detection + redaction for common PII formats on the inline path.
**Done when:** known PII patterns redacted before the provider call; redaction visible in the trace; raw value never logged.

### GRD-3 — PII NER (off inline path)

`area:guardrails · type:feature · phase:p3 · repo:atlas-gateway · Points: 5 · Depends on: GRD-2`
NER (Presidio + pinned spaCy model, or GLiNER) for novel PII; run off the <50ms inline path per the latency strategy (atlas-docs/05).
**Done when:** NER catches formats regex misses; inline p95 budget preserved; model pinned.

### GRD-4 — Injection heuristics

`area:guardrails · type:feature · phase:p3 · repo:atlas-gateway · Points: 2 · Depends on: GRD-1`
Heuristic screen for known prompt-injection patterns.
**Done when:** a known injection corpus is flagged; false-positive rate documented.

### GRD-5 — Cheap-model injection classifier

`area:guardrails · type:feature · phase:p3 · repo:atlas-gateway · Points: 3 · Depends on: GRD-4, GW-10`
Classifier called *through the gateway* (alias) for ambiguous inputs.
**Done when:** classifier verdict gates the request; calls go through the gateway (accounted + traced).

### GRD-6 — Tool-output sanitization

`area:guardrails · type:feature · phase:p3 · repo:atlas-gateway · Points: 3 · Depends on: GRD-4`
Sanitize tool/MCP outputs before they re-enter agent context (injection-via-tool-results defense). Exposed for reuse by the agent runtime (AGT-5).
**Done when:** a poisoned tool output is neutralized before context re-entry; unit-tested.

### GRD-7 — Input size caps

`area:guardrails · type:feature · phase:p3 · repo:atlas-gateway · Points: 1 · Depends on: GRD-1`
Reject oversized inputs with an explicit error.
**Done when:** over-cap requests are rejected pre-provider; cap configurable per route.

### GRD-8 — Post: JSON-schema validation + bounded repair

`area:guardrails · type:feature · phase:p3 · repo:atlas-gateway · Points: 3 · Depends on: GRD-1`
Validate structured outputs; bounded auto-repair (hard attempt cap) then reject.
**Done when:** malformed output is repaired within the cap or rejected; cap enforced; tested via Mock.

### GRD-9 — Post: citation enforcement (check framework)

`area:guardrails · type:feature · phase:p3 · repo:atlas-gateway · Points: 5 · Depends on: GRD-1`
Build the citation-enforcement check against the `verify_citation` contract: every factual claim must reference a doc-search `source_id` or the response is rejected. Tested against a **stub** verifier in p3; the live wiring to the citations MCP happens in `AGT-12`.
**Done when:** an uncited/unsupported claim is rejected and a properly-cited answer passes against the stub; the check is contract-compatible with the citations MCP. *(No backwards dependency on AGT-9 — see AGT-12 for live integration.)*

### GRD-10 — Post: content policy

`area:guardrails · type:feature · phase:p3 · repo:atlas-gateway · Points: 2 · Depends on: GRD-1`
Content-policy screen on outputs.
**Done when:** policy violations are rejected with an explicit reason; configurable.

### GRD-11 — Per-check OTel metrics

`area:observability · type:feature · phase:p3 · repo:atlas-gateway · Points: 2 · Depends on: GRD-1, INF-13`
One counter per check (`atlas.guardrail.<name>.{pass,block}`).
**Done when:** counters increment per check and surface in Splunk dashboards.

### GRD-12 — No-raw-PII-in-logs enforcement + tests

`area:security · type:test · phase:p3 · repo:atlas-gateway · Points: 3 · Depends on: GRD-2, GRD-3`
Log/trace processors strip PII; tests assert raw PII never reaches logs.
**Done when:** a PII-bearing request leaves no raw PII in logs/traces; test guards regression.

---

## EPIC `AGT` — Agent runtime + MCP · phase:p4

> Goal: a bounded RAG agent with verified citations. The Enhesa parallel. Runtime in **atlas-agent-runtime**; retrieval/citation servers in **atlas-mcp-doc-search** / **atlas-mcp-citations**; the agent YAML lives in **atlas-prompts**.

### AGT-1 — Agent spec model

`area:agent · type:feature · phase:p4 · repo:atlas-agent-runtime · Points: 2 · Depends on: REG-3`
`agentspec.py` pydantic model parsing the agent YAML (system_prompt_ref, model_alias, tool_whitelist, max_iterations, token_budget, timeout_s). The YAML files themselves live in atlas-prompts (REG-2).
**Done when:** a YAML agent loads + validates; invalid specs fail fast.

### AGT-2 — Schema + migrations: agent_runs/agent_steps

`area:data · type:feature · phase:p4 · repo:atlas-agent-runtime · Points: 2 · Depends on: GW-9`
Alembic for `agent_runs`, `agent_steps` (atlas-docs/03), owned by the agent runtime.
**Done when:** migrations apply; FK + indexes present.

### AGT-3 — Thin agent loop with hard caps

`area:agent · type:feature · phase:p4 · repo:atlas-agent-runtime · Points: 5 · Depends on: AGT-1, GW-6`
Bounded loop: hard caps on iterations/tokens/wall-time; fail-fast on breach with an explicit error.
**Done when:** a runaway agent stops at the cap with a clear error; normal runs complete; caps unit-tested.

### AGT-4 — Tool whitelist registry + enforcement

`area:agent · type:feature · phase:p4 · repo:atlas-agent-runtime · Points: 3 · Depends on: AGT-3`
Registry maps agent → allowed MCP servers/tools; every tool call checked against the whitelist.
**Done when:** a non-whitelisted tool call is rejected; allowed calls proceed; tested.

### AGT-5 — Tool-result sanitization integration

`area:agent · type:feature · phase:p4 · repo:atlas-agent-runtime · Points: 2 · Depends on: AGT-4, GRD-6`
Wire GRD-6 sanitization into the loop before results re-enter context.
**Done when:** tool outputs pass through sanitization in the loop; tested with a poisoned output.

### AGT-6 — Run/step persistence + resumability

`area:agent · type:feature · phase:p4 · repo:atlas-agent-runtime · Points: 3 · Depends on: AGT-2, AGT-3`
Persist runs + steps; support resume from last step.
**Done when:** a run's steps are persisted; an interrupted run resumes; tested.

### AGT-7 — OTel agent spans

`area:observability · type:feature · phase:p4 · repo:atlas-agent-runtime · Points: 3 · Depends on: AGT-3, INF-13`
One span per LLM call / tool call; `gen_ai.operation.name` ∈ {invoke_agent, execute_tool}; `gen_ai.agent.name`.
**Done when:** a run produces a coherent multi-span trace in Splunk (NFR4: 100% of agent runs).

### AGT-8 — Corpus ingestion pipeline

`area:mcp · type:feature · phase:p4 · repo:atlas-mcp-doc-search · Points: 5 · Depends on: INF-10, INF-12, GW-8`
Chunk the regulatory corpus → embeddings (via `/v1/embeddings`) → Qdrant `doc_chunks` + Elasticsearch index; carries `source_id`.
**Done when:** the corpus is ingested; chunks queryable in both ES and Qdrant; `source_id` preserved.

### AGT-9 — mcp-doc-search server (hybrid)

`area:mcp · type:feature · phase:p4 · repo:atlas-mcp-doc-search · Points: 5 · Depends on: AGT-8`
MCP server exposing `doc_search(query, k)` = hybrid Elasticsearch BM25 + Qdrant vector → `{chunks:[{id,text,source_id,score}]}`.
**Done when:** doc_search returns fused ranked chunks with source_ids; contract matches atlas-docs/03; deployed on AKS.

### AGT-10 — mcp-citations server

`area:mcp · type:feature · phase:p4 · repo:atlas-mcp-citations · Points: 3 · Depends on: AGT-8`
MCP server exposing `verify_citation(source_id, claim)` → `{exists, snippet}` against the corpus.
**Done when:** verify_citation correctly confirms/denies a source_id; contract matches atlas-docs/03; deployed.

### AGT-11 — RegDoc Q&A agent definition

`area:agent · type:feature · phase:p4 · repo:atlas-prompts · Points: 3 · Depends on: AGT-3, AGT-9, AGT-10, REG-2`
The RegDoc agent YAML + system prompt (in atlas-prompts) wiring doc-search + citations under whitelist + caps.
**Done when:** the agent answers a corpus question with cited sources via the loop.

### AGT-12 — End-to-end citation enforcement (live wiring)

`area:guardrails · type:feature · phase:p4 · repo:atlas-gateway · Points: 3 · Depends on: AGT-11, GRD-9, AGT-10`
Wire GRD-9's check to the live citations MCP (AGT-10) against the AGT-9 corpus so the agent's answers are citation-enforced end-to-end.
**Done when:** an unsupported claim is rejected at the gateway; a supported answer passes; verified live against the corpus.

### AGT-13 — Helm charts (in-repo `deploy/`) for agent-runtime + MCP servers

`area:cicd · type:feature · phase:p4 · repo:atlas-agent-runtime · Points: 3 · Depends on: AGT-3, AGT-9, AGT-10`
Per-repo `deploy/` Helm charts for atlas-agent-runtime, atlas-mcp-doc-search, atlas-mcp-citations (probes, CSI secrets, identities).
**Done when:** all three deploy to AKS healthy; reachable per their contracts.

### AGT-14 — Agent integration tests

`area:test · type:test · phase:p4 · repo:atlas-agent-runtime · Points: 3 · Depends on: AGT-11, AGT-12`
Tests for cited answer, refusal on unanswerable, runaway-cap, whitelist rejection, trace emission.
**Done when:** all scenarios pass; offline where possible via Mock + fixture corpus.

### AGT-15 — Demo: RegDoc agent

`area:docs · type:docs · phase:p4 · repo:atlas-agent-runtime · Points: 2 · Depends on: AGT-14`
Scripted end-to-end demo + README (cited answer, refusal, runaway, trace).
**Done when:** the demo runs and is documented.

### AGT-16 — Agent-runtime FastAPI trigger surface

`area:agent · type:feature · phase:p4 · repo:atlas-agent-runtime · Points: 2 · Depends on: AGT-3 · ADR-020`
Thin FastAPI surface: `POST /v1/agent/runs` (start) + `GET /v1/agent/runs/{id}` (poll status/result). Closes the gap that the runtime had no surface to receive a run request; reuses the layered convention (ADR-016) + OpenAPI contract (ADR-014). Async Kafka invocation (`atlas.agent.requests.v1`) deferred. *(Done — surface on `main`: `app/api/v1/runs.py` + `app/main.py` + contract/endpoint tests; BRA-873.)*
**Done when:** a run starts + polls over HTTP; OpenAPI spec published; offline test via Mock; hard caps (ADR-006) still enforced.

---

## EPIC `FE` — Frontend: RegDoc Q&A app · phase:p1→p4 · repo:atlas-frontend

> Goal: the Angular + TypeScript demo SPA — streaming chat with a citations panel and a cost/usage view. Talks only to the gateway. TS API types are generated from the gateway OpenAPI spec (GW-21), never hand-written.

### FE-1 — Angular scaffold + tooling + CI

`area:frontend · type:chore · phase:p1 · repo:atlas-frontend · Points: 3 · Depends on: INF-2`
Angular workspace, eslint + prettier, `tsc --noEmit`, **Vitest** (ADR-018), environment config; CI (INF-2 frontend variant) green.
**Done when:** app builds; lint/typecheck/tests run clean in CI.

### FE-2 — Config + AuthInterceptor (no hardcoded keys)

`area:frontend · type:feature · phase:p1 · repo:atlas-frontend · Points: 2 · Depends on: FE-1`
ConfigService (runtime config, no secrets in the bundle) + AuthInterceptor attaching the per-key bearer token sourced from a secured config/BFF.
**Done when:** the bearer token is injected on every gateway call; no key is present in the built artifact; verified by a build-artifact scan.

### FE-3 — GatewayService + SseService (streaming client)

`area:frontend · type:feature · phase:p1 · repo:atlas-frontend · Points: 3 · Depends on: FE-2, GW-7, GW-21`
Typed client over the gateway using TS types generated from the OpenAPI spec; SSE consumption of `chat.completion.chunk` deltas through `data: [DONE]`.
**Done when:** a streamed response renders token-by-token; types come from the generated package; 429 bodies surfaced.

### FE-4 — ChatModule components

`area:frontend · type:feature · phase:p1 · repo:atlas-frontend · Points: 5 · Depends on: FE-3`
ChatPage, MessageList, Composer, CitationsPanel, Message components per the frontend diagrams.
**Done when:** a user can ask a question and see the streamed answer + a (initially empty) citations panel; component tests pass.

### FE-5 — Request/stream state store

`area:frontend · type:feature · phase:p1 · repo:atlas-frontend · Points: 3 · Depends on: FE-3`
Store implementing the state model (idle → submitting → streaming → done / error / rate_limited / budget_exceeded) driving UI affordances.
**Done when:** each state drives the correct UI (spinner, disabled composer, banners); transitions unit-tested per the state-model diagram.

### FE-6 — UsageModule (CostDashboard)

`area:frontend · type:feature · phase:p2 · repo:atlas-frontend · Points: 3 · Depends on: FE-4, GW-14`
Cost/usage view reading per-key token + cost from the gateway accounting surface.
**Done when:** the dashboard shows per-key spend + token usage; refresh works.

### FE-7 — Containerize + Helm chart + Rollout

`area:cicd · type:feature · phase:p4 · repo:atlas-frontend · Points: 3 · Depends on: FE-4, INF-15`
Multi-stage Dockerfile (nginx static serve) + in-repo `deploy/` Helm chart + Argo Rollouts `Rollout`.
**Done when:** the SPA deploys to AKS behind ingress; healthcheck green; Rollout present.

### FE-8 — Citations panel wired to RegDoc answers + e2e tests

`area:frontend · type:test · phase:p4 · repo:atlas-frontend · Points: 3 · Depends on: FE-4, AGT-12`
Render verified citations from the agent's cited answers; e2e tests for chat, streaming, citations, 429 handling, refusal.
**Done when:** citations render with source links; e2e suite passes against a Mock/fixture gateway.

### FE-9 — Demo: end-to-end UI

`area:docs · type:docs · phase:p4 · repo:atlas-frontend · Points: 2 · Depends on: FE-7, FE-8`
Scripted UI demo + README (ask → streamed cited answer → cost view).
**Done when:** the demo runs end-to-end and is documented.

---

## EPIC `POL` — Polish · phase:p5

> Goal: the production-grade differentiators — semantic cache, canary, drift, dashboards.

### POL-1 — Semantic cache (Qdrant)

`area:gateway · type:feature · phase:p5 · repo:atlas-gateway · Points: 5 · Depends on: GW-13, AGT-8`
Embed normalized request → Qdrant `semantic_cache` cosine search (0.97), opt-in per route, tenant-scoped, never for cited answers.
**Done when:** a paraphrase hits the cache (metric + span tag); cross-tenant never hit; cited answers never cached.

### POL-2 — Gateway canary (Argo Rollouts/Flagger)

`area:cicd · type:feature · phase:p5 · repo:atlas-gateway · Points: 5 · Depends on: GW-19, GW-18`
10% canary with automated SLO analysis (error rate / p95 latency / guardrail block rate) → promote or auto-rollback.
**Done when:** a deliberately broken image is auto-rolled-back; a healthy one is promoted.

### POL-3 — Nightly shadow / drift eval

`area:evals · type:feature · phase:p5 · repo:atlas-prompts · Points: 5 · Depends on: GW-15, REG-8, REG-10`
Sample `atlas.shadow.v1` live traffic → re-run eval metrics on production prompt versions → drift report → MLflow + Splunk.
**Done when:** the nightly job produces a drift delta visible on the dashboard; alerts on score drop.

### POL-4 — Splunk dashboards

`area:observability · type:feature · phase:p5 · repo:atlas-infra · Points: 3 · Depends on: GW-18, GW-15, GRD-11, AGT-7`
Dashboards: cost per app/model/day, p50/p95/p99 latency by route, cache hit rate, guardrail trigger rates, agent loop-depth, eval score trends.
**Done when:** all panels render from live data; saved/versioned dashboards.

### POL-5 — Drift alerting

`area:observability · type:feature · phase:p5 · repo:atlas-infra · Points: 2 · Depends on: POL-3`
Alert when a production prompt version's score drops beyond threshold.
**Done when:** a simulated drop fires an alert to the configured channel.

### POL-6 — Load test + p95 validation

`area:test · type:test · phase:p5 · repo:atlas-gateway · Points: 3 · Depends on: POL-1, POL-2`
Sustained load test validating <50ms p95 gateway overhead with cache + canary in place.
**Done when:** p95 overhead < 50ms under target RPS; report archived.

### POL-7 — Demo: production-grade

`area:docs · type:docs · phase:p5 · repo:atlas-docs · Points: 2 · Depends on: POL-1, POL-2, POL-3`
Scripted demo (semantic hit, canary rollback, drift panel) + README.
**Done when:** the demo runs end-to-end and is documented.

---

## EPIC `XCUT` — Cross-cutting / hardening

### XCUT-1 — Security review pass

`area:security · type:chore · repo:all · Points: 5 · Depends on: GW-19, INF-7`
Review secrets handling, network policies, least-privilege identities, image scanning across all repos; close gaps.
**Done when:** no secrets in code/images/tests; network policies in place; scan clean; findings tracked.

### XCUT-2 — Runbooks

`area:docs · type:docs · repo:atlas-docs · Points: 3 · Depends on: INF-16`
Incident, rollback, on-call, cost-control, and teardown runbooks.
**Done when:** runbooks exist and are linked from `atlas-docs/README.md`.

### XCUT-3 — Architecture docs + diagrams upkeep

`area:docs · type:docs · repo:atlas-docs · Points: 2 · Depends on: —`
Keep `atlas-docs/00..06`, the ADRs, and the diagrams (cross-repo + per-repo) in sync as the build proceeds.
**Done when:** docs + diagrams reflect the shipped system at each milestone.

### XCUT-4 — Dependency + version lock audit

`area:chore · type:chore · repo:all · Points: 3 · Depends on: INF-1`
Establish lockfiles per repo; verify every dependency is pinned and ≥14 days old; Terraform providers + Helm charts pinned.
**Done when:** lockfiles committed; an audit script flags any unpinned/too-new dep in CI.

### XCUT-5 — Threat-model review

`area:security · type:spike · repo:atlas-docs · Points: 5 · Depends on: GRD-1, AGT-3`
Validate the threat model (atlas-docs/05) against the built system; add tests for any gap.
**Done when:** each threat has a mitigation + a test; residual risks documented.

### XCUT-6 — Diagram validation in CI

`area:cicd · type:test · repo:all · Points: 2 · Depends on: INF-2`
CI step that validates Mermaid (mermaid-cli) and PlantUML diagrams render, in atlas-docs and each repo's `docs/diagrams/`.
**Done when:** a broken diagram fails CI; all current diagrams pass (38 Mermaid + 7 PlantUML already validated locally).

### XCUT-7 — Build system + CI hardening

`area:cicd · type:chore · repo:all · Points: 3 · Depends on: INF-1`
Single-source build system across all 8 repos: **Trunk** linter front-end, `scripts/` + `Makefile` (`make ci`), per-repo Dockerfiles, a GitHub Actions mirror of the Bitbucket gates, and the strict Checkov/Trivy/TFLint IaC posture. Retroactively ticketed in the 2026-06-09 repo↔Linear audit. *(Done — merged to `main` in every repo; BRA-874.)*
**Done when:** `make ci` runs the full gate locally and in CI; every repo green.

---

### Totals

**105 stories · ~446 points** across 7 phase/area epics + cross-cutting, mapped over 8 repos. Suggested first slice (M1–M3): `INF-1 → INF-3..16`, then `GW-1..GW-9` + `GW-21`, then `REG` (the eval-gate demo). The chat UI (`FE-1..FE-5`) can begin as soon as `GW-7` lands.
