# Atlas — Architecture Documentation

**Atlas** is an internal AI platform where *all* LLM traffic flows through a gateway: versioned prompts, eval-gated promotion, enforced guardrails (incl. citation verification), an agent runtime + MCP, and per-call cost traceability. It is built to mirror **Enhesa's confirmed production stack** — Azure/AKS, Terraform, Bitbucket Pipelines, Kafka, Elasticsearch, Qdrant, MLflow, Splunk, and a multi-provider LLM strategy (OpenAI + Anthropic + Google), with AI microservices in Python.

Demo workload: a **regulatory-document Q&A agent** (RAG with enforced citations).

## Document set

| # | Document | What it covers |
|---|---|---|
| 00 | [Overview, Goals & Requirements](00-overview-goals-requirements.md) | Vision, why-this-stack, goals/non-goals, FR/NFR, high-level diagram, request flows, demo workload, glossary |
| 01 | [System Architecture](01-system-architecture.md) | Component catalogue, AKS container diagram, chat + agent sequence diagrams, data flows, control vs data plane |
| 02 | [Tech Stack & ADRs](02-tech-stack-and-adrs.md) | Full stack table, versioning policy, ADR-001…020 (build-vs-adopt, Python, Azure, Qdrant, hybrid retrieval, hand-rolled loop, Kafka, MLflow, OTel→Splunk, layered architecture+DI, eval stack, frontend state+Vitest, infra dev-loop+TF testing, agent invocation) |
| 03 | [Data Model & Contracts](03-data-model-and-contracts.md) | Postgres DDL (10 tables), Qdrant collections, Kafka topic schemas, gateway OpenAI-compatible API, MCP tool contracts, cost formula |
| 04 | [Infra, CI/CD & Observability](04-infra-cicd-observability.md) | Azure topology, Terraform modules, Workload Identity + Key Vault CSI, Helm + Skaffold dev loop, Bitbucket three gates, OTel→Splunk, MLflow |
| 05 | [Guardrails & Security](05-guardrails-and-security.md) | Guardrail chain, PII/injection/citation enforcement, threat model, failure-modes table, secrets & tenant isolation |
| 06 | [Roadmap & Milestones](06-roadmap-and-milestones.md) | Phases P0–P5, dependency DAG, milestones M1–M6 |
| — | [Framework Evaluation](research/framework-evaluation.md) | Evidence-based framework selection across all 8 repos — Enhesa current stack (live JDs), build-vs-adopt frontier, per-repo recommendations → ADR-016…020 |
| — | [Backlog (Linear-ready)](backlog/TICKETS.md) | 100 stories across 6 phase-epics + cross-cutting; acceptance criteria, estimates, dependencies, labels |

## Runbooks

Operational runbooks for the Atlas platform. All commands reference real `make` targets, `kubectl`, `helm`, `skaffold`, `kubectl argo rollouts`, and `alembic` commands from the repos.

| Runbook | What it covers |
|---|---|
| [Incident Response](runbooks/incident-response.md) | Triage checklist, severity classification, Splunk dashboards + OTel signals to check, comms protocol |
| [Rollback](runbooks/rollback.md) | Gateway canary rollback (Argo Rollouts `undo`); prompt version rollback (registry production-pointer flip / REG-5); database migration rollback (Alembic downgrade) |
| [On-Call](runbooks/on-call.md) | Escalation path, key SLO signals, where things live (repos, Azure RGs, namespaces, endpoints), common failure patterns |
| [Cost Control](runbooks/cost-control.md) | Scale-to-zero CronJob (automatic overnight), `make cloud-down` / `full-down`, `make destroy`, expected $/month |
| [Teardown](runbooks/teardown.md) | `make destroy` end-to-end, Key Vault soft-delete recovery, post-destroy verification, `make full-up` recreate |

## Reading order

- **New to Atlas:** 00 → 01 → 06.
- **Implementing:** 02 (decisions) → 03 (contracts) → 04 (infra/CI) → `backlog/TICKETS.md`.
- **Security/review:** 05 + 03.

## Key locked decisions

Python 3.12 + asyncio · **Azure/AKS (full Enhesa mirror)** · hand-built OpenAI-compatible gateway · layered service architecture + DI (ADR-016) · Qdrant + Elasticsearch hybrid retrieval · Kafka event bus · MLflow + DeepEval eval gate · OpenTelemetry → Splunk · OpenAI + Anthropic + Google (Gemini) + MockProvider · Angular + Vitest + Signals frontend · Bitbucket Pipelines three-gate CI/CD (tests / evals / canary) · AKS-only dev loop (Skaffold). See [02-tech-stack-and-adrs.md](02-tech-stack-and-adrs.md) for rationale.

## Status

Architecture, backlog, and initial build complete through **P3 (Guardrails)**; P4 (Agent runtime + MCP) and P5 (Polish) in progress.

**Shipped (code exists and tests pass):**
- `atlas-gateway` — layered FastAPI service (api/services/repositories/domain + DI); all four providers (Anthropic, OpenAI, Google, MockProvider); `/v1/chat/completions` (stream + non-stream), `/v1/models`, `/v1/embeddings`; alias routing; tenacity retry + Redis-backed per-provider circuit breaker; exact-match cache (Redis); per-key token-bucket rate limit + monthly budget → 429; accounting → Kafka `atlas.calls.v1`; OTel GenAI spans; prompt registry (resolver + promotion state machine + eval-gated promotion); full guardrail chain — PII regex (GRD-2), PII NER stand-in (GRD-3), injection heuristics (GRD-4), injection classifier via gateway (GRD-5), tool-output sanitization (GRD-6), size caps (GRD-7), JSON-schema repair (GRD-8), citation enforcement stub (GRD-9), content policy (GRD-10), per-check OTel metrics (GRD-11). 35 test files, offline via MockProvider + fakeredis.
- `atlas-agent-runtime` — bounded loop (AGT-3) with hard iteration/token/wall-time caps; AgentSpec YAML model; ToolRegistry whitelist enforcement (AGT-4); ToolSanitizer (AGT-5); run/step persistence + resume (AGT-6); OTel agent spans (AGT-7). FastAPI trigger surface (AGT-16) defined in deploy chart; app/api/ not yet coded.
- `atlas-mcp-doc-search` — MCP server with hybrid ES BM25 + Qdrant vector retrieval, RRF fusion, ingestion pipeline.
- `atlas-mcp-citations` — MCP server with ES + Qdrant corpus lookup for citation verification.
- `atlas-prompts` — eval runner, LLM-as-judge, gate comparator, golden datasets, Alembic eval schema.
- `atlas-frontend` — Angular + TypeScript RegDoc Q&A app; chat module, state store, gateway service + SSE client, usage module, Helm chart.
- `atlas-infra` — Terraform modules (network, aks, data, storage, identity, secrets); platform Helm charts (qdrant, kafka, elasticsearch, mlflow, otel-collector, cost-controls); Skaffold umbrella dev loop; Makefile one-command up/down/destroy.
