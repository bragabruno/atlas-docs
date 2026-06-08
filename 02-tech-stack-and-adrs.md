# 02 — Tech Stack & Architecture Decision Records

> **Status:** Living document — update when a technology choice changes or a new ADR is ratified.
> **Last reviewed:** 2026-06-08

---

## 1. Full Stack Table

| Area | Choice | Rationale | Enhesa-stack match? |
|---|---|---|---|
| **Language & runtime** | Python 3.12 + asyncio | Literal match for Enhesa AI microservices team; I/O-bound LLM proxy workload; see Language Note below | Yes |
| **Linting / type checking** | ruff + pyright (strict) | Fast, zero-config ruff replaces flake8+isort+black; pyright strict catches protocol mismatches at CI time | Yes |
| **Testing** | pytest + pytest-asyncio + pytest-cov | Standard async-aware test stack; coverage enforced in CI | Yes |
| **API framework** | FastAPI + Uvicorn | ASGI, automatic OpenAPI, `Depends` DI; layered architecture per ADR-016; gunicorn + uvicorn workers in K8s for multi-core fan-out | Yes |
| **Service architecture** | Layered + DI (controllers → services → repositories → domain) | "Spring-style" separation via FastAPI `Depends`, no heavyweight framework; see ADR-016 | n/a (internal) |
| **Data validation / settings** | pydantic v2 + pydantic-settings | First-class async support, model-level validation, settings from env/Key Vault | Yes |
| **DB driver — hot path** | asyncpg | Native asyncio PostgreSQL driver; zero ORM overhead on the gateway hot path | Yes |
| **ORM — registry / eval / runs** | SQLAlchemy 2.0 async | Full async session API; used outside the hot path where rich query composition matters | Yes |
| **Migrations** | Alembic (psycopg3 sync) | Schema-as-code; psycopg3 sync driver for the migration entrypoint only | Yes |
| **PostgreSQL service** | Azure Database for PostgreSQL Flexible Server | Managed, HA, point-in-time recovery; mirrors Enhesa cloud DB tier | Yes |
| **Cache / rate-limit / circuit-breaker state** | redis-py async | Exact-match cache, token-bucket rate limiting (Lua scripts), shared circuit-breaker counters across replicas | Yes |
| **Vector store** | Qdrant | `doc_chunks` and `semantic_cache` collections; dedicated vector engine with filtering; see ADR-004 | Yes |
| **Search** | Elasticsearch | Hybrid BM25 (keyword) + Qdrant vector rerank for doc-search; also used for log search | Yes |
| **Event bus** | Kafka | Topics: `atlas.calls.v1`, `atlas.spans.v1`, `atlas.shadow.v1`, `atlas.eval.requests.v1`; see ADR-007 | Yes |
| **Eval / experiment tracking** | MLflow | Tracks model-comparison experiments, eval runs, prompt versions; see ADR-008 | Yes |
| **Eval framework** | DeepEval (metrics) + custom `gate.py` | Adopt commodity metrics (semantic match, citation validity, LLM-as-judge); own the gate/promotion; see ADR-017 | New (greenfield) |
| **Observability** | OpenTelemetry SDK → OTel Collector → Splunk | GenAI semantic conventions; traces, metrics, logs all flow through OTel Collector; see ADR-009 | Yes |
| **LLM providers** | OpenAI + Anthropic + Google (Gemini) via Provider Protocol + MockProvider | Multi-vendor resilience; real keys in prod, mock fallback for offline/CI; see ADR-012 | Yes |
| **Model IDs (authoritative)** | `claude-opus-4-8` · `claude-sonnet-4-6` · `claude-haiku-4-5` · `gpt-4.1` · `gemini-*` | See token/pricing table below; never inferred from tiktoken | Yes |
| **Retry / backoff** | tenacity | Per-call retry with jitter; composable decorators | Yes |
| **Circuit breaker** | Hand-rolled Redis-backed per-provider | Shared state across replicas via Redis; see ADR-011 | Yes |
| **Agent / MCP SDK** | Official Python `mcp` SDK (FastMCP) | First-party protocol; FastMCP server interface + Streamable HTTP transport; no vendored fork | Yes |
| **Agent invocation** | FastAPI trigger surface (`POST /v1/agent/runs`) | Synchronous run trigger for atlas-agent-runtime; Kafka consumer later; see ADR-020 | n/a (internal) |
| **Container registry** | Azure Container Registry (ACR) | Geo-replicated; integrated with AKS pull identity | Yes |
| **Kubernetes** | AKS | Managed control plane; Workload Identity for pod-level Azure RBAC | Yes |
| **Secrets** | Doppler (dev/CI authoring) → Azure Key Vault + Secrets Store CSI (AKS runtime) | Doppler injects env vars locally/CI and syncs to Key Vault; pods mount via CSI + Workload Identity (runtime store of record); see ADR-021 | Yes (Key Vault runtime); Doppler is an added dev/CI plane |
| **IaC** | Terraform (azurerm) + Azure Storage state backend | Declarative infra; remote state with lock | Yes |
| **IaC testing / policy** | `terraform test` + Checkov + TFLint + Trivy | Native HCL module tests + security/compliance scan + lint; see ADR-019 | New (greenfield) |
| **CI/CD** | Bitbucket Pipelines | Org-standard; pipeline definitions live in the repo | Yes |
| **Helm** | Helm (pinned chart versions) | Kubernetes release management; values per environment | Yes |
| **Progressive delivery** | Argo Rollouts / Flagger | Canary deployments with automated metric-based promotion/rollback | Yes |
| **Local dev loop** | Skaffold (umbrella) | AKS-only dev loop, Helm-native, parallels the Argo/Helm CD path; Tilt evaluated (richer DX) — see ADR-019; no local Docker Compose target | Yes |
| **Object storage** | Azure Blob Storage | Artefacts, eval datasets, prompt snapshots | Yes |
| **Frontend** | Angular + TypeScript (`atlas-frontend`) | Mirrors Enhesa; **Vitest** test runner (Karma EOL) + **Angular Signals** service-store state per ADR-018; TS API types generated from the gateway OpenAPI spec | Yes |
| **Repo file layout** | Framework-idiomatic per repo (FastAPI `app/` · MCP named package · PyPA `src/` for `atlas-prompts` · Angular 2025 naming) | Each repo follows its owning framework's docs; `src/` only where no framework owns it; see ADR-022 | Convention |

### Model Token & Pricing Reference

| Model | Input price | Output price | Context window |
|---|---|---|---|
| `claude-opus-4-8` | $5 / M tokens | $25 / M tokens | 1 M tokens |
| `claude-sonnet-4-6` | $3 / M tokens | $15 / M tokens | 1 M tokens |
| `claude-haiku-4-5` | $1 / M tokens | $5 / M tokens | 200 K tokens |
| `gpt-4.1` | (placeholder — confirm with OpenAI pricing page) | (placeholder) | — |
| `gemini-*` | (placeholder — confirm with Google pricing page) | (placeholder) | — |

> **Token counting:** use each provider's own `count_tokens` API (or the Anthropic `beta.messages.count_tokens` endpoint). Never use tiktoken for non-OpenAI models — it produces incorrect counts.

---

## 2. Versioning & Supply-Chain Policy

1. **Pin exact versions** in `uv.lock` and `requirements.txt` at lock time. No version ranges, no `latest`.
2. **Minimum age guardrail:** every dependency must be ≥ 14 days old at the time it is first added. New packages are a common supply-chain attack vector; the 14-day window lets the community surface malicious releases.
3. **Terraform providers and Helm chart versions** are pinned exactly in `versions.tf` and `Chart.yaml` respectively.
4. **Upgrade cadence:** dependency bumps happen in dedicated PRs with a changelog review; batch upgrades are preferred over ad-hoc single-package bumps.
5. **No transitive-only pins** — if a transitive dependency has a known CVE the project pins it explicitly with a comment referencing the CVE/advisory.

---

## 3. Language & Runtime Note

Python 3.12 + asyncio is the **literal stack match** for Enhesa's AI microservices team. This is not a translation — Atlas code and knowledge transfer across to Enhesa with zero language friction.

**Gateway latency tradeoff acknowledged:** Python carries per-request overhead vs Go or Rust. This is mitigated by:

- **asyncpg** on the hot path: direct protocol driver, no ORM round-trips.
- **Redis Lua scripts** for atomic token-bucket rate limiting — single round-trip per decision.
- The gateway is **I/O-bound** (network to upstream LLM APIs), not CPU-bound; Python's GIL is not the bottleneck.
- The external interface is an **OpenAI-compatible facade**. If a specific route proves CPU-bound in production profiling, it can be extracted behind that facade without changing any caller.

---

## 4. Architecture Decision Records

---

### ADR-001 Build Gateway Primitives vs. Adopt LiteLLM / Portkey

**Status:** Accepted

**Context:**
Off-the-shelf LLM proxy libraries (LiteLLM, Portkey, OpenRouter) provide multi-provider routing, cost tracking, and caching out of the box. The team evaluated both paths.

**Decision:**
Build the gateway primitives in-house. Atlas owns the Provider Protocol, circuit breaker, rate limiter, shadow sampling pipeline, and eval loop.

**Consequences:**

- Engineering investment: 3–4 sprint-weeks of scaffolding vs. near-zero for a hosted proxy.
- Full observability of every internal decision (retry logic, circuit state, prompt transformations) without black-box vendor internals.
- The primitives become IP that mirrors Enhesa's own internal tooling — direct knowledge transfer value.
- No runtime dependency on a third-party SaaS critical path; no per-token markup from a proxy vendor.

**Alternatives considered:**

- LiteLLM (open-source): good coverage, but abstractions hide the circuit-breaker and rate-limit logic Atlas needs to own.
- Portkey (managed): operational simplicity, but opaque internals and a vendor lock-in surface.

---

### ADR-002 Python + asyncio as Primary Runtime

**Status:** Accepted

**Context:**
Atlas must mirror Enhesa's AI microservices stack. The Enhesa AI team's production services are Python + asyncio.

**Decision:**
Python 3.12 + asyncio across all Atlas microservices.

**Consequences:**

- Zero translation overhead: Atlas engineers and Enhesa engineers read the same idioms.
- asyncio event loop handles the high concurrency of LLM proxy workloads efficiently (I/O-bound, not CPU-bound).
- Standard toolchain (ruff, pyright, pytest) is shared.

**Alternatives considered:**

- Go: lower per-request latency, but introduces a language barrier with the Enhesa team and negates the knowledge-transfer mission.
- Rust (axum): maximum throughput, but prohibitively high onboarding cost and no Enhesa alignment.

---

### ADR-003 Azure / AKS — Full Enhesa Mirror

**Status:** Accepted

**Context:**
Enhesa's production infrastructure runs on Azure. Atlas is designed to demonstrate operational readiness on that exact stack.

**Decision:**
All Atlas infrastructure targets Azure: AKS, ACR, Azure Database for PostgreSQL Flexible Server, Azure Blob Storage, Azure Key Vault, AKS Workload Identity. Terraform state in Azure Storage.

**Consequences:**

- Infra runbooks, Helm values, and Terraform modules are directly reusable or easily adapted for Enhesa's environment.
- AKS Workload Identity removes the need to manage service-principal credentials in pods.
- Azure-specific costs (egress, managed DB) vs. AWS or GCP; acceptable given the strategic mirror value.

**Alternatives considered:**

- AWS with translation layer: possible, but every infrastructure artifact requires a mental translation step, reducing demo fidelity.
- GCP: no Enhesa alignment; eliminated immediately.

---

### ADR-004 Qdrant for Vector Storage

**Status:** Accepted

**Context:**
Atlas requires a vector store for `doc_chunks` (RAG) and `semantic_cache` (LLM response caching). Options evaluated: pgvector (PostgreSQL extension), Qdrant, Pinecone (managed SaaS).

**Decision:**
Qdrant, self-hosted on AKS.

**Consequences:**

- Dedicated vector engine with native filtering, payload indexing, and named collections — no schema contortions.
- Self-hosted: no per-query SaaS cost; full control over data residency.
- Matches Enhesa's confirmed vector store choice — direct operational parity.
- Adds one more stateful service to operate; mitigated by Helm chart and persistent volume claims.

**Alternatives considered:**

- pgvector: convenient co-location with PostgreSQL, but approximate-nearest-neighbour performance degrades at scale and filtering semantics are limited.
- Pinecone: no operational control, SaaS cost at scale, and not in Enhesa's stack.

---

### ADR-005 Hybrid Retrieval: Elasticsearch BM25 + Qdrant Vector

**Status:** Accepted

**Context:**
Pure vector search misses exact-keyword matches (product codes, regulatory identifiers, proper nouns). Pure BM25 misses semantic equivalence. Enhesa's stack includes both Elasticsearch and Qdrant.

**Decision:**
Doc-search uses a hybrid pipeline: BM25 candidates from Elasticsearch are reranked by Qdrant vector similarity. Elasticsearch also handles log search.

**Consequences:**

- Retrieval quality is higher for enterprise regulatory content (exact codes + semantic meaning).
- Two stateful systems to operate; mitigated by the fact that Elasticsearch already serves log search, so it is not an extra component added for retrieval alone.
- Dual-write on ingest: documents are indexed in both Elasticsearch and Qdrant.

**Alternatives considered:**

- Elasticsearch only (BM25): simpler, but poor semantic recall.
- Qdrant only (vector): misses exact-match requirements for regulatory content.
- Dedicated reranker service (Cohere Rerank, cross-encoder): evaluated as a future enhancement, deferred.

---

### ADR-006 Hand-Rolled Thin Agent Loop vs. LangGraph

**Status:** Accepted

**Context:**
Atlas needs an agent loop for multi-step tool-calling tasks. LangGraph provides a graph-based agent runtime with built-in state management.

**Decision:**
Build a thin, hand-rolled agent loop. No LangGraph dependency.

**Consequences:**

- Full ownership of every failure mode: retry semantics, tool error propagation, span emission, and circuit-breaker interaction are explicit in Atlas code.
- The loop is inspectable: every step emits an OTel span; there is no framework magic to debug.
- Engineering cost: ~2 sprint-weeks to build a robust loop vs. near-zero for LangGraph.
- No upstream breaking changes from a framework release to manage.

**Alternatives considered:**

- LangGraph: rich primitives, but abstractions hide failure paths; framework upgrades have historically introduced breaking changes in the agent graph API.
- LlamaIndex agent runtime: similar trade-offs to LangGraph; not in Enhesa's stack.
- **Pydantic AI** (sanctioned fallback): type-safe agents with built-in OpenTelemetry instrumentation, composing with the existing pydantic v2 + OTel stack. Unlike LangGraph it does not hide failure modes. **If the hand-rolled loop's ~2-sprint-week cost is not affordable, adopt Pydantic AI rather than LangGraph** — it preserves inspectability while removing the build cost. Re-evaluated 2026-06-07 against the current agent-framework landscape (see `research/framework-evaluation.md` §5.3); decision to hand-roll reaffirmed for the portfolio thesis.

---

### ADR-007 Kafka as the Event Bus

**Status:** Accepted

**Context:**
Atlas requires reliable, ordered, replayable event delivery for: call accounting (`atlas.calls.v1`), distributed tracing fan-out (`atlas.spans.v1`), shadow traffic sampling (`atlas.shadow.v1`), and async eval triggering (`atlas.eval.requests.v1`).

**Decision:**
Kafka as the single event bus. Topics are named with a `.v1` versioning suffix; schema evolution is managed via Confluent-compatible Avro or JSON Schema.

**Consequences:**

- Durable, replayable log: eval and accounting pipelines can replay from any offset.
- Shadow sampling is decoupled from the hot path — the gateway publishes to `atlas.shadow.v1` and the shadow consumer handles comparison asynchronously.
- Kafka adds operational complexity; mitigated by managed Kafka (Confluent Cloud or Azure Event Hubs Kafka-compatible surface) as a deployment option.

**Alternatives considered:**

- Redis Streams: lighter-weight, but limited retention and no consumer-group durability guarantees at scale.
- Azure Service Bus: managed, but not Kafka-compatible; pipeline code would not translate to Enhesa's environment.
- In-process async queues (asyncio.Queue): no persistence, no fan-out across replicas.

---

### ADR-008 MLflow for Eval / Experiment Tracking

**Status:** Accepted

**Context:**
Atlas runs prompt-comparison experiments and automated eval suites. Results must be queryable over time, comparable across model versions, and linkable to run artefacts.

**Decision:**
MLflow as the eval and experiment tracking layer. Eval results, prompt snapshots, and aggregate metrics are logged as MLflow runs.

**Consequences:**

- Standardised experiment API; UI available for human review of eval results.
- Integrates with Azure Blob Storage for artefact storage.
- Matches Enhesa's confirmed tracking stack.
- MLflow server is one more stateful service; a single replica with Azure Blob backend is sufficient at Atlas scale.

**Alternatives considered:**

- Custom-only (PostgreSQL tables + bespoke UI): higher engineering cost, no off-the-shelf comparison UI.
- Weights & Biases: managed SaaS, higher cost, not in Enhesa's stack.

---

### ADR-009 OpenTelemetry → Splunk (vs. Grafana / Tempo)

**Status:** Accepted

**Context:**
Atlas emits traces, metrics, and logs via the OpenTelemetry SDK. A backend must receive and query these signals. Enhesa's observability backend is Splunk.

**Decision:**
OTel SDK → OTel Collector (sidecar/DaemonSet) → Splunk. GenAI semantic conventions (`gen_ai.*` span attributes) are used for LLM-specific telemetry.

**Consequences:**

- Direct operational parity with Enhesa; dashboards and alert rules translate.
- GenAI semantic conventions enable per-model latency breakdowns, token usage tracking, and error classification without custom attributes.
- Splunk licensing cost is higher than open-source alternatives; accepted as a stack-mirror requirement.

**Alternatives considered:**

- Grafana + Tempo + Loki: fully open-source, lower cost, but diverges from Enhesa's stack; dashboards would not transfer.
- Datadog: strong GenAI support, but SaaS cost and not in Enhesa's stack.

---

### ADR-010 asyncpg on the Hot Path + SQLAlchemy 2.0 Elsewhere; Alembic for Migrations

**Status:** Accepted

**Context:**
The gateway hot path executes on every LLM call: auth lookup, rate-limit record, and call logging. Latency here is user-visible. Eval, run, and registry operations are less latency-sensitive but benefit from rich ORM query composition.

**Decision:**

- asyncpg directly on the gateway hot path: native protocol, no ORM overhead.
- SQLAlchemy 2.0 async sessions for registry, eval, and run persistence.
- Alembic manages all schema migrations using the psycopg3 sync driver in the migration entrypoint (no asyncpg in Alembic env).

**Consequences:**

- Hot-path DB operations are as fast as the Python driver allows.
- SQLAlchemy models serve as the schema source of truth; Alembic auto-generates diffs.
- Two DB access patterns in the codebase: asyncpg raw SQL (hot path) and SQLAlchemy ORM (everything else). Engineers must understand the boundary.

**Alternatives considered:**

- SQLAlchemy 2.0 everywhere: cleaner, but Core/ORM overhead is measurable on sub-10 ms latency targets.
- asyncpg everywhere: fast, but hand-writing complex eval queries in raw SQL is maintenance-heavy.

---

### ADR-011 Hand-Rolled Redis-Backed Per-Provider Circuit Breaker + tenacity for Per-Call Retries

**Status:** Accepted

**Context:**
LLM provider APIs fail transiently (rate limits, 5xx, timeouts). Two failure-management mechanisms are required: per-call retry (short-lived, same request) and circuit breaking (sustained failure, shed load across all replicas).

**Decision:**

- **tenacity** for per-call retry with exponential backoff + jitter. Decorators applied per provider method.
- **Hand-rolled circuit breaker** backed by Redis counters and TTL keys. State (CLOSED / OPEN / HALF-OPEN) is stored in Redis so all AKS replicas share the same view.

**Consequences:**

- A single unhealthy provider is quarantined within seconds across all gateway replicas — not just the replica that observed failures.
- Redis Lua scripts enforce atomic counter increments; no race conditions on state transitions.
- No dependency on a circuit-breaker library (e.g. `pybreaker`) whose maintenance status is uncertain.
- Adds Redis read on every provider call (negligible latency; Redis is already on the hot path for rate limiting).

**Alternatives considered:**

- pybreaker: in-process only; does not share state across replicas.
- Per-replica in-process state: each replica independently detects failure, leading to thundering herd before all replicas open the breaker.
- Istio/Envoy circuit breaking: infrastructure-level, but does not distinguish by provider at the application layer; cannot be influenced by HTTP response body (e.g., provider-specific error codes).

---

### ADR-012 Multi-Provider via Provider Protocol + MockProvider

**Status:** Accepted

**Context:**
Atlas must route to OpenAI, Anthropic, and Google (Gemini). CI pipelines must run without real API keys and without incurring token spend.

**Decision:**
Define a `Provider` protocol (Python `typing.Protocol`) that all provider implementations satisfy. Concrete implementations: `OpenAIProvider`, `AnthropicProvider`, `GoogleProvider`. A `MockProvider` is registered as the fallback in test/CI environments — it returns deterministic fixture responses and emits full OTel spans.

**Consequences:**

- New providers are added by implementing the protocol and registering in the provider registry — no changes to the gateway routing logic.
- CI runs at zero cost; MockProvider responses are deterministic, enabling reproducible eval baselines.
- MockProvider exercises the full OTel/Kafka/eval pipeline in CI, catching integration regressions without real keys.
- Token counting uses each provider's own API (`count_tokens`); tiktoken is never imported.

**Alternatives considered:**

- Single-provider-only for Phase 1: reduces initial scope but forecloses the Enhesa multi-vendor resilience pattern.
- VCR-style HTTP recording: captures real responses but requires periodic re-recording and leaks token spend into CI setup.

---

### ADR-013 Polyrepo (One Git Repo per Component) over Monorepo

**Status:** Accepted

**Context:**
Atlas is composed of multiple independently deployable components: gateway, agent runtime, two MCP services, frontend, infra, prompts/evals, and docs. A monorepo would simplify cross-cutting commits and shared tooling, but Enhesa's Bitbucket environment is a multi-repo organisation — each service lives in its own repo with its own pipeline.

**Decision:**
Polyrepo: 8 git repositories (`atlas-docs`, `atlas-gateway`, `atlas-agent-runtime`, `atlas-mcp-doc-search`, `atlas-mcp-citations`, `atlas-frontend`, `atlas-infra`, `atlas-prompts`). Each repo owns its own Bitbucket pipeline (from a shared pipeline template) and its own Helm chart under a `deploy/` directory. Platform charts (Qdrant, Kafka, Elasticsearch, MLflow, OTel Collector) live in `atlas-infra`.

**Consequences:**

- Directly mirrors Enhesa's Bitbucket multi-repo reality; repo structure, pipeline definitions, and Helm layouts transfer with no structural changes.
- Requires a shared cross-repo contract strategy (see ADR-014) and an umbrella dev-loop in `atlas-infra` to bring all services up together locally.
- Each service can be released, versioned, and on-called independently.
- Cross-cutting changes (e.g., shared pydantic models) require coordinated PRs across repos.

**Alternatives considered:**

- Monorepo: simpler cross-cutting commits and unified CI; rejected because it diverges from Enhesa's multi-repo Bitbucket structure, reducing the fidelity of the organisational mirror.

---

### ADR-014 Gateway OpenAPI Spec as the Cross-Repo Contract Source of Truth

**Status:** Accepted

**Context:**
With 8 separate repos, each consuming the gateway's HTTP API (frontend, agent runtime, MCP services), there is a risk of client models drifting from the server contract. A single authoritative source of truth is needed.

**Decision:**
`atlas-gateway` publishes its OpenAPI spec as the canonical contract. Consumers are code-generated from it: `atlas-frontend` runs an OpenAPI-to-TypeScript codegen step; Python services use a generated client (e.g., `openapi-python-client`). No hand-written or duplicated model definitions are permitted in consumer repos.

**Consequences:**

- Contract drift between server and consumers is caught at codegen time, not at runtime.
- Adding or changing a gateway endpoint requires publishing an updated spec and re-running codegen in consumer repos — a deliberate, visible change surface.
- Codegen must be integrated into each consumer's CI pipeline.

**Alternatives considered:**

- Shared `atlas-contracts` package (published to a private PyPI / npm registry): more tooling overhead (package publishing pipeline, version pinning across repos); rejected as over-engineering at current scale.
- Duplicated hand-written models in each consumer: drift-prone, rejected unconditionally.

---

### ADR-015 atlas-prompts Owns Prompts/Agents/Evals + Eval-Gate Pipeline; Per-Service Helm Charts + Per-Service DB Table Ownership

**Status:** Accepted

**Context:**
Three structural concerns span multiple repos and needed an explicit ownership decision: (1) where prompt templates, agent YAMLs, and eval assets live; (2) where Helm charts live; (3) which service owns which PostgreSQL tables.

**Decision:**

- **Prompts, agents, evals:** `atlas-prompts` owns all git-tracked prompt templates, agent YAML definitions, the eval runner, and golden-set references. The eval-gate CI pipeline (which gates merges on eval regressions) runs in `atlas-prompts`' Bitbucket pipeline.
- **Helm charts:** each service repo owns its own `deploy/` Helm chart for its microservice. Platform/infrastructure charts (Qdrant, Kafka, Elasticsearch, MLflow, OTel Collector) live in `atlas-infra`.
- **DB table ownership:** `atlas-gateway` owns `aliases`, `keys`, `budgets`, `call_records`, `prompts`, `prompt_versions`; `atlas-prompts` owns `eval_runs`, `eval_results`; `atlas-agent-runtime` owns `agent_runs`, `agent_steps`. No cross-service direct DB access — services query their own tables only.

**Consequences:**

- Eval regressions block merges at the prompt/agent layer, not buried inside service pipelines.
- Table ownership boundaries prevent implicit cross-service coupling via the DB.
- Deploying a new service requires only its own repo's `deploy/` chart; platform chart changes are isolated to `atlas-infra`.
- `atlas-prompts` becomes a coordination point for any change affecting prompts, agents, or evals — all such changes go through its eval-gate.

**Alternatives considered:**

- Fold prompts/evals into `atlas-agent-runtime`: co-location is convenient but conflates deployment lifecycle of the runtime service with the eval cadence of prompt/agent changes.
- Centralise all Helm charts in `atlas-infra`: simpler chart discovery but removes the "each service deploys itself" property that mirrors Enhesa's team autonomy model.

---

### ADR-016 Layered Service Architecture + Dependency Injection (per Python service)

**Status:** Accepted (2026-06-07)

**Context:**
The gateway began as a flat package where the route handler mixed HTTP parsing, business logic, and provider calls. As guardrails (GRD-*), the prompt-registry runtime (REG-*), accounting, and routing land, that flat shape does not scale and is hard to test in isolation. The question raised was whether to adopt a heavier opinionated framework ("Spring Boot for Python" — Litestar/Django) for structure. The framework evaluation (`research/framework-evaluation.md`) found the organization problem is solved by an internal layering convention, not by changing frameworks.

**Decision:**
Adopt a layered spine in every Python service: **`api/` (controllers) → `services/` (use-cases) → `repositories/` (persistence) → `domain/` (framework-free contracts)**, with the capability modules (`providers/`, `cache/`, `limits/`, `guardrails/`, …) as adapters the service layer composes. FastAPI's `Depends` is the DI container; `api/deps.py` is the request-scope composition root. HTTP shape lives only in `api/`; business logic only in `services/`; DB access only in `repositories/`; domain types carry no framework import. Controllers raise no business logic; services raise domain errors (e.g. `UnknownModelError`) that controllers map to HTTP.

**Consequences:**

- Clear separation + testability: services are unit-testable without HTTP; contract tests at the controller stay stable across internal refactors (the gateway refactor that introduced this kept all 14 tests green).
- The wave-1 "module-first, wire-later" plan is clean — cache (GW-13) and guardrails (GRD-1) land as adapters and wire into `services/`, never the controller.
- No new dependency — `Depends` is already present; "Spring-style" separation with zero framework magic.
- A convention engineers must follow; enforced by review and the package layout, not by a tool.

**Alternatives considered:**

- Litestar: opinionated layered controllers + DI, but smaller ecosystem and higher hiring risk; off the FastAPI/Enhesa mirror.
- Django/DRF: batteries-included but sync-first; wrong grain for the async LLM proxy.
- Stay flat: simplest now, unmaintainable as guardrails/registry/accounting accrue.

---

### ADR-017 Eval Stack — DeepEval Metrics + Custom Gate

**Status:** Accepted (2026-06-07)

**Context:**
`atlas-prompts` runs the eval-gate (Gate 2) that blocks any prompt/agent promotion on a regression. The metrics it needs — exact/semantic match, citation validity, faithfulness, LLM-as-judge — are now commodity in 2026 eval frameworks (DeepEval, promptfoo, Ragas). The decision is build-vs-adopt for the *metrics*, separate from the *gate* itself.

**Decision:**
Adopt **DeepEval** for the metric implementations (it carries 50+ metrics incl. citation/faithfulness and is built for CI gates over agents/multi-turn). Keep a **thin custom `gate.py`** for the Atlas-specific logic — baseline comparison, blocking-vs-advisory split, and server-side promotion enforcement (REG-13). Eval runs continue to log to MLflow (ADR-008). promptfoo may be added later for adversarial/red-team matrices.

**Consequences:**

- Far less code than a fully hand-rolled metric suite; the gate/promotion (the Atlas IP) stays owned.
- Judge-model token cost (~$200–600/mo at 10k traces/day per 2026 benchmarks) is a real operating cost — watch it on the nightly drift eval (POL-3); cap sample sizes.
- A new dependency (DeepEval) in `atlas-prompts`, pinned ≥14 days old per policy.

**Alternatives considered:**

- Fully custom runner: maximal "I built it" story, but reinvents commodity metrics and is more to maintain.
- promptfoo as the primary gate: declarative YAML, strong red-team, but a non-Python idiom and less bespoke metric control.
- Ragas: RAG-only; useful as a supplementary retrieval-quality dashboard, not the gate.

---

### ADR-018 Frontend State (Angular Signals) + Vitest Test Runner

**Status:** Accepted (2026-06-07)

**Context:**
`atlas-frontend` (Angular + TypeScript) left two choices open: state management ("service-store or NgRx") and test runner ("Karma/Jest"). Both sit in fast-moving areas; the framework evaluation gathered current (2026) evidence.

**Decision:**

- **Test runner: Vitest.** With Angular 21 (late 2025) Vitest is the CLI default and is "stable and production-ready"; Karma is deprecated (no new features/bugfixes) and Jest support is experimental/frozen. New specs are authored for Vitest; the README's "Karma/Jest" is superseded.
- **State: Angular Signals service-store.** Right-sized for the app (chat + citations + cost), modern default, least boilerplate. NgRx SignalStore is the sanctioned step-up if shared cross-module state or stronger debugging tooling is later needed; classic NgRx is not adopted (overkill at this size).

**Consequences:**

- Near-instant test feedback (Vite) vs Karma's browser boot; tests run in Node (jsdom) or real browsers via Playwright.
- Minimal state boilerplate now, with a documented upgrade path to NgRx SignalStore.
- Component tests must be authored/migrated to the Vitest API.

**Alternatives considered:**

- Keep Karma: deprecated, slow, no future.
- Jest: viable but its Angular support is experimental and frozen; Vitest is the endorsed direction.
- Classic NgRx (actions/reducers/effects): canonical but heavy for this app; deferred.

---

### ADR-019 Infra Inner Dev-Loop (Skaffold) + Terraform Testing/Policy

**Status:** Accepted (2026-06-07)

**Context:**
`atlas-infra` left the umbrella dev-loop tool open ("Skaffold / Tilt", INF-15) and specified no Terraform testing/policy tooling.

**Decision:**

- **Dev-loop: Skaffold.** Helm-native and declarative, paralleling the Argo Rollouts/Helm CD path for the multi-repo build → ACR → Helm → AKS umbrella loop. (Tilt offers richer inner-loop DX via live file-sync + a service dashboard and remains a defensible alternative if inner-loop speed outweighs CD parity.)
- **Terraform testing/policy:** native **`terraform test`** (1.6+, HCL, no deploy) for module-logic validation; **Checkov** for security/compliance (CIS/GDPR/PCI; also scans Helm/K8s; Python-native, matches the team language); **TFLint** as the linter; **Trivy** (`trivy config`) for IaC scanning (the maintained successor to tfsec). **Terratest** (Go) is reserved for the top 1–2 critical modules only, to avoid a Go-language barrier in a Python shop.

**Consequences:**

- The inner loop mirrors the CD path, so "works in dev" tracks "works in canary."
- IaC is gated in CI on both correctness (`terraform test`) and security (Checkov/Trivy) without introducing Go for the common case.
- Two scanners (Checkov + Trivy) overlap somewhat; accepted for coverage breadth, deduped in triage.

**Alternatives considered:**

- Tilt: better DX, but more imperative Starlark config and less aligned with the declarative Helm/Argo pipeline.
- tfsec: folded into Trivy; "no reason to start a new pipeline on tfsec in 2026."
- Terratest as the primary test tool: powerful but requires Go and real deploys — overkill for module-logic checks.

---

### ADR-020 Agent-Runtime Invocation Surface — FastAPI Trigger (Kafka Later)

**Status:** Accepted (2026-06-07)

**Context:**
`atlas-agent-runtime`'s module map (loop, tools, persistence, gateway/MCP clients) had **no surface that receives a run request** — a gap surfaced by the framework evaluation. A caller (frontend via gateway, or an operator) needs a way to start a RegDoc agent run.

**Decision:**
Expose a thin **FastAPI** trigger surface in the runtime (`POST /v1/agent/runs` to start a run, `GET /v1/agent/runs/{id}` to poll status/result), reusing the same layered convention (ADR-016) and OpenAPI-contract approach (ADR-014). Asynchronous invocation via a Kafka consumer (off a new `atlas.agent.requests.v1` topic) is deferred to when batch/eval-triggered runs are needed.

**Consequences:**

- Consistent with every other Python HTTP service (FastAPI), and the run API is codegen-friendly for consumers.
- Synchronous-first keeps Phase 1 simple; the loop still enforces hard caps (ADR-006) so a long run can't hang a request indefinitely (it fails at the wall-time cap).
- Adds a new ticket (AGT trigger-surface) and a `agent.requests` topic to the Kafka plan when the async path lands.

**Alternatives considered:**

- Kafka-only invocation now: better decoupling, but no synchronous request/response for the demo UI and more moving parts in Phase 1.
- Invoke the runtime as an in-process library from the gateway: couples two deployables and breaks the per-service autonomy of the polyrepo (ADR-013).

---

### ADR-021 Doppler for Developer + CI Secrets; Azure Key Vault for AKS Runtime

**Status:** Accepted (2026-06-08)

**Context.**
Atlas mirrors the target company's stack (Azure / AKS), so the runtime secret store was
already fixed as **Azure Key Vault + Secrets Store CSI driver**, accessed via Workload
Identity (ADR-003 + §1 stack table; INF-7 ticket). In code today, secrets are plain
environment variables read by pydantic-settings — no manager is wired. Key Vault is strong at
runtime but weak at developer ergonomics: pulling secrets locally means `az login` +
`az keyvault secret show`, with no clean "inject env vars into my process" workflow, and the
polyrepo (8 repos) multiplies that friction.

**Decision.**
Adopt **Doppler as the authoring + distribution plane for developer and CI secrets**, and keep
**Azure Key Vault + CSI as the runtime store of record** in AKS. The two are bridged by
**Doppler's Key Vault sync integration**:

- **Local dev:** `doppler run -- <cmd>` injects secrets as env vars; `doppler.yaml` maps each
  repo to a Doppler project/config. No `.env` files, nothing secret in git.
- **CI:** integration/deploy stages fetch secrets via a scoped Doppler **service token**
  (stored in the CI secret store, referenced by name). The **unit gate (ruff → pyright →
  pytest) runs with no secrets** (MockProvider / fakes) and never depends on Doppler.
- **Runtime (AKS):** Doppler syncs secrets into Key Vault; pods mount them via the CSI driver +
  Workload Identity exactly as before. Application code is unchanged — it still reads env vars.

**Consequences.**

- (+) First-class local/CI DX; no `.env` sprawl; single authoring source fans out to Key Vault.
- (+) Preserves the Azure-native runtime narrative (Key Vault + CSI) end to end.
- (+) Rotation flow: rotate in Doppler → sync → Key Vault → CSI re-mount.
- (−) One extra SaaS vendor in the dev/CI trust boundary — an enterprise would security-review it;
  noted as a known trade-off, mitigated by Doppler holding only dev/CI material and runtime
  authority remaining in Key Vault.
- (−) One sync integration to configure and monitor.

**Alternatives rejected.**

- **Key Vault only:** keeps everything in-Azure but leaves the poor local-dev DX unsolved.
- **Doppler everywhere (K8s Operator, drop Key Vault):** simpler, but diverges from the target
  stack and weakens the "built the way you run it" story.

---

### ADR-022 Per-Repo File Layout Follows the Owning Framework's Docs (PyPA `src/` as Fallback)

**Status:** Accepted (2026-06-08)

**Context.**
The 8 polyrepos (ADR-013) had drifted into three inconsistent Python layouts and a half-migrated Angular naming scheme. The FastAPI services and the MCP servers all used a generic `app/` import package behind a `pythonpath = ["."]` test shim (so `top_level.txt = app` in every wheel — a name collision if co-installed); `atlas-prompts` carried three top-level packages (`atlas_prompts`, `evals`, `eval_runs`) plus a loose `gate.py`; and `atlas-frontend` had migrated only its root files to the new Angular naming. There was no single principle for "where do files go," so the question got re-litigated per repo.

**Decision.**
Each repo follows the **recommended file structure of its owning framework's documentation**; **PyPA's `src/` layout is the fallback only where no framework owns the repo.** Verified against the live framework docs, this yields:

- **FastAPI services** (`atlas-gateway`, `atlas-agent-runtime`) → keep the **`app/` package** (FastAPI's "Bigger Applications" docs prescribe `app/main.py` + routers + `dependencies.py`). Already conformant; explicitly **not** migrated to `src/`.
- **MCP servers** (`atlas-mcp-doc-search`, `atlas-mcp-citations`) → a **named package** `atlas_mcp_<name>/` with `server.py` and a `[project.scripts] … = "pkg.server:main"` console entry, per the MCP Python SDK's own example servers.
- **`atlas-prompts`** (library + CLI, no owning framework) → **PyPA `src/atlas_prompts/`**, folding the former `evals`/`eval_runs` packages and `gate.py` in as subpackages, with eval **data** hoisted to repo-root `datasets/` + `rubrics/`. The `pythonpath` shim is removed — an editable install is mandatory, so tests run against the installed package.
- **`atlas-frontend`** (Angular 21) → the Angular **"2025" style guide**: suffix-less filenames (drop `.component`/`.service`/`.store`/`.interceptor`), same base name for `.ts`/`.html`/`.scss`.
- **`atlas-infra`** (Terraform/HashiCorp) → already conformant with the HashiCorp module structure (`modules/*/{main,variables,outputs,versions}.tf` + `envs/` + `bootstrap/`).

**Consequences.**

- (+) One rule resolves every layout question and is defensible by citing each framework's docs; no per-repo bikeshedding.
- (+) Each repo reads as idiomatic in its ecosystem (a FastAPI dev sees `app/`; an MCP author sees a named package + console script; a Python packager sees `src/`).
- (+) Dropping the `pythonpath` shim in `atlas-prompts` surfaces packaging bugs early (tests import the built package, not the working dir).
- (−) The fleet is **intentionally not uniform** — FastAPI repos use `app/` while `atlas-prompts` uses `src/`. This is by design (framework-idiomatic > globally-uniform); a reviewer must know the rule rather than expect one layout everywhere.
- (−) The FastAPI/MCP packages keep relying on `pythonpath = ["."]` for tests (acceptable — matches their framework norms; only the distributable library earns the `src/` install discipline).

**Alternatives rejected.**

- **`src/` everywhere (uniformity):** overrides FastAPI's and the MCP SDK's documented conventions and would churn ~95 files across the two FastAPI repos for zero conformance gain — directly contradicting the principle.
- **`app/` everywhere:** keeps the generic, collision-prone `app` import name and the `pythonpath` shim, which is wrong for a distributable library like `atlas-prompts`.

*Implemented (2026-06-08, pure-structural, behavior-preserving): `atlas-mcp-doc-search` #10, `atlas-mcp-citations` #9, `atlas-prompts` #12, `atlas-frontend` #10; docs synced in this PR.*

---

## 5. Deliberately Deferred

The following capabilities are architecturally compatible with the current stack but are **not in scope for Phase 1**:

| Deferred item | Why deferred | When to revisit |
|---|---|---|
| **Semantic cache by default** | Qdrant `semantic_cache` collection is provisioned; cache population and lookup are off by default. TTL, similarity threshold, and cache-invalidation policy need product validation before enabling. | After eval data shows hit-rate ROI for target query patterns. |
| **Multi-region deployment** | Azure networking, Kafka replication, and PostgreSQL geo-redundancy add significant operational surface. Single-region HA (AZs within one region) is sufficient for Phase 1. | When data-residency or latency SLAs require it. |
| **Fine-grained multi-tenancy** | Per-tenant rate limits, cost attribution, and data isolation at the prompt/completion level require schema changes and policy engine work. Current model is team-level isolation. | When Atlas onboards external tenants or Enhesa requires per-team billing isolation. |
| **Cross-encoder / dedicated reranker** | The BM25 + vector hybrid (ADR-005) delivers acceptable retrieval quality. A cross-encoder would improve rerank precision at the cost of an extra inference call per query. | When retrieval eval shows recall degradation on complex queries. |
