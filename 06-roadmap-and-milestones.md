# 06 — Roadmap & Milestones

> Cloud-first on **Azure / AKS**, full Enhesa-stack mirror. Each phase is independently demoable. Maps 1:1 to the epics in [`backlog/TICKETS.md`](backlog/TICKETS.md).

## Repos

Eight repositories — see [`backlog/TICKETS.md`](backlog/TICKETS.md) for the per-repo story mapping.

| Repo | Contents |
|---|---|
| `atlas-docs` | Architecture docs, ADRs, this roadmap |
| `atlas-gateway` | OpenAI-compatible API gateway; prompt registry DB + runtime |
| `atlas-agent-runtime` | Thin agent loop, YAML agent defs, run/step persistence |
| `atlas-mcp-doc-search` | MCP server — hybrid BM25 + vector doc retrieval |
| `atlas-mcp-citations` | MCP server — citation verification |
| `atlas-frontend` | Angular + TypeScript RegDoc Q&A app (epic `FE`) |
| `atlas-infra` | Terraform modules for the full Azure / AKS footprint |
| `atlas-prompts` | Prompt templates, agent YAMLs, eval runner, golden-set refs, eval-gate CI pipeline |

## Phasing principle

Build the **keystone first** (the gateway — everything depends on it), insert **infrastructure as Phase 0** (you can't deploy to a cluster that doesn't exist), then layer registry/evals → guardrails → agent/MCP → polish. Phases 0–2 alone demonstrate ~70% of the JD with running code.

## Phases

### P0 — Infra foundation (epic `INF`)

**Goal:** a reproducible Azure footprint and an AKS-only dev loop, with all platform dependencies running.
**Deliverables:** Terraform (azurerm) modules — network, AKS (+ Workload Identity), identity, secrets (Key Vault + CSI), data (Azure PostgreSQL Flexible Server + Redis), storage (Blob + ACR); Qdrant, Kafka (topics created), Elasticsearch, MLflow, and the OTel Collector→Splunk pipeline deployed; Bitbucket Pipelines PR pipeline green; Skaffold dev loop (ADR-019); Terraform state backend in Azure Storage.
**Demo:** `make cloud-up ENV=dev` → `kubectl get nodes` ready → a placeholder gateway pod reachable via ingress; `terraform plan` clean.
**Exit criteria:** one-command up; CI green on an empty `MockProvider`; all data services reachable in-cluster.

### P1 — Gateway core (epic `GW`)

**Goal:** the keystone — one OpenAI-compatible API in front of three providers, with accounting and traces.
**Deliverables:** Provider abstraction (Mock/OpenAI/Anthropic/Google); `/v1/chat/completions` (stream + non-stream), `/v1/models`, `/v1/embeddings`; alias routing + fallback; retries + per-provider Redis-backed circuit breaker; exact cache; per-call accounting (3 token fields) → Kafka `atlas.calls.v1`; rate-limit + monthly budget → 429; OTel GenAI spans → Splunk.
**Demo:** `curl` with `model=mock` → OpenAI-shaped JSON; a `call_records` row with cost/latency; a span in Splunk; 429 on rate-limit and budget.
**Exit criteria:** <50ms p95 gateway overhead under load (Mock); offline test suite green.

### P2 — Prompt registry + eval gate (epic `REG`) — *the money demo*

**Goal:** prompts versioned and promoted like code; a bad prompt cannot reach production.
**Deliverables:** `prompts`/`prompt_versions` + promotion state machine + instant rollback; git-tracked templates; eval runner + versioned golden sets in Blob; metrics (exact/semantic/citation/cost/latency + LLM-as-judge advisory); MLflow tracking; Bitbucket eval-gate that blocks a regressing PR and posts the metric diff.
**Repo split:** prompt templates, agent YAMLs, eval runner, golden-set refs, and the eval-gate CI pipeline live in `atlas-prompts`; the registry DB schema and runtime API live in `atlas-gateway`.
**Demo:** open a PR with a regressed prompt → eval-gate red + metric comment; fix → green → promote; rollback flips the pointer instantly.

### P3 — Guardrails (epic `GRD`)

**Goal:** enforced pre/post checks as a platform service.
**Deliverables:** middleware chain (fail-fast `GuardrailRejection`); pre — PII (regex + NER), injection (heuristics + cheap-model classifier via gateway, tool-output sanitization), size caps; post — JSON-schema + bounded repair, citation-enforcement check, content policy; per-check OTel metrics.
**Demo:** PII redacted pre-call; injection blocked; malformed JSON repaired-or-rejected; uncited claim rejected; raw PII absent from logs.
**Note:** citation enforcement becomes *end-to-end real* only once P4's doc-search exists (see DAG).

### P4 — Agent runtime + MCP (epic `AGT`) — *the Enhesa parallel*

**Goal:** a bounded RAG agent with verified citations.
**Deliverables:** hand-rolled thin loop with hard caps; YAML agent defs; tool whitelist + sanitization; run/step persistence; corpus ingestion → Qdrant `doc_chunks` + Elasticsearch index; `mcp-doc-search` (hybrid BM25 + vector) and `mcp-citations` servers; the RegDoc Q&A agent; full multi-span traces.
**Demo:** cited answer end-to-end; refusal on an unanswerable question (no hallucinated cite); runaway hits the cap with an explicit error; trace in Splunk; run/step rows in Postgres.

### Frontend — RegDoc Q&A UI (epic `FE`, repo `atlas-frontend`)

Angular + TypeScript app spanning P1 → P4. Depends on the gateway OpenAPI spec (`GW-21`) as the source of truth for generated TS types.

- **P1+:** basic streaming chat UI can start once the SSE endpoint (`GW-7`) lands.
- **P4+:** citations panel becomes fully functional once end-to-end citation enforcement is in place.

### P5 — Polish (epic `POL`)

**Goal:** the production-grade differentiators.
**Deliverables:** opt-in semantic cache (Qdrant `semantic_cache`, 0.97, tenant-scoped, never for cited answers); gateway canary (Argo Rollouts/Flagger, 10%, auto-rollback on SLO breach); nightly shadow/drift evals via `atlas.shadow.v1` → MLflow; Splunk dashboards.
**Demo:** semantic cache hit on a paraphrase; broken image auto-rolled-back by canary; drift delta on the dashboard.

## Dependency DAG

```
P0 infra (network → aks → data/storage/identity/secrets; Qdrant, Kafka, ES, MLflow, OTel→Splunk)
        │  OTel Collector before ANY span export (all phases)
        ▼
P1 gateway: accounting schema → budget; provider abstraction → P2 judge / P3 classifier / P4 agent;
            exact cache → P5 semantic cache; atlas.calls.v1 → P5 cost dashboards
        ▼
P2 registry: prompt_versions (gateway DB) → eval gate (atlas-prompts CI) → promotion → CI quality gate; golden sets → P5 shadow/drift
        ║
        ║ GW-21 OpenAPI spec → atlas-frontend TS types (unblocks FE build)
        ▼
P3 guardrails (needs P1 middleware seam; citation enforcement end-to-end needs P4 doc-search)
        ▼
P4 agent + MCP: doc-search → citation enforcement; run/step schema → traces → P5 dashboards
        ║
        ║ citation enforcement live → atlas-frontend citations panel complete
        ▼
P5 polish (canary needs P1 OTel SLO metrics; drift needs P2 metrics + atlas.shadow.v1 sampling)
```

**Hard ordering:** accounting schema before budget · OTel Collector before any exporter · `prompt_versions` before eval gate · doc-search before end-to-end citation enforcement · provider abstraction before LLM-as-judge and the injection classifier.

## Milestones

| Milestone | Phases | Demoable outcome | JD coverage |
|---|---|---|---|
| **M1 — Platform online** | P0 | One-command Azure up; CI green; placeholder pod reachable | IaC reproducibility, AKS, Bitbucket |
| **M2 — Gateway live** | P1 | Three providers behind one API + live cost/trace in Splunk | Multi-provider routing, accounting, observability |
| **M2a — Chat UI live** | P1+ | Streaming chat UI in atlas-frontend talking to SSE endpoint (GW-7) | Frontend baseline, gateway OpenAPI contract |
| **M3 — Quality gate** | P2 | A bad-prompt PR blocked by evals; instant rollback | Prompt registry, eval-gated promotion, MLflow |
| **M4 — Trust layer** | P3 | PII/injection/citation guardrails enforced | Guardrail & policy enforcement signals |
| **M5 — RegDoc agent** | P4 | Citation-enforced RAG agent with full traces | Agent runtime, MCP, RAG, citations |
| **M5a — Cited UI** | P4 | Citations panel live in atlas-frontend | End-to-end RegDoc UX with citations |
| **M6 — Production-grade** | P5 | Semantic cache + canary + drift dashboards | Canary/SLO, drift, cost dashboards |

M1–M3 are the highest-leverage interview demos; ship those as small, reviewable slices first.
