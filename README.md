# Atlas — Architecture Documentation

**Atlas** is an internal AI platform where *all* LLM traffic flows through a gateway: versioned prompts, eval-gated promotion, enforced guardrails (incl. citation verification), an agent runtime + MCP, and per-call cost traceability. It is built to mirror **Enhesa's confirmed production stack** — Azure/AKS, Terraform, Bitbucket Pipelines, Kafka, Elasticsearch, Qdrant, MLflow, Splunk, and a multi-provider LLM strategy (OpenAI + Anthropic + Google), with AI microservices in Python.

Demo workload: a **regulatory-document Q&A agent** (RAG with enforced citations).

## Document set

| # | Document | What it covers |
|---|---|---|
| 00 | [Overview, Goals & Requirements](00-overview-goals-requirements.md) | Vision, why-this-stack, goals/non-goals, FR/NFR, high-level diagram, request flows, demo workload, glossary |
| 01 | [System Architecture](01-system-architecture.md) | Component catalogue, AKS container diagram, chat + agent sequence diagrams, data flows, control vs data plane |
| 02 | [Tech Stack & ADRs](02-tech-stack-and-adrs.md) | Full stack table, versioning policy, ADR-001…012 (build-vs-adopt, Python, Azure, Qdrant, hybrid retrieval, hand-rolled loop, Kafka, MLflow, OTel→Splunk, …) |
| 03 | [Data Model & Contracts](03-data-model-and-contracts.md) | Postgres DDL (10 tables), Qdrant collections, Kafka topic schemas, gateway OpenAI-compatible API, MCP tool contracts, cost formula |
| 04 | [Infra, CI/CD & Observability](04-infra-cicd-observability.md) | Azure topology, Terraform modules, Workload Identity + Key Vault CSI, Helm + Skaffold/Tilt dev loop, Bitbucket three gates, OTel→Splunk, MLflow |
| 05 | [Guardrails & Security](05-guardrails-and-security.md) | Guardrail chain, PII/injection/citation enforcement, threat model, failure-modes table, secrets & tenant isolation |
| 06 | [Roadmap & Milestones](06-roadmap-and-milestones.md) | Phases P0–P5, dependency DAG, milestones M1–M6 |
| — | [Backlog (Linear-ready)](backlog/TICKETS.md) | 89 stories across 6 phase-epics + cross-cutting; acceptance criteria, estimates, dependencies, labels |

## Reading order

- **New to Atlas:** 00 → 01 → 06.
- **Implementing:** 02 (decisions) → 03 (contracts) → 04 (infra/CI) → `backlog/TICKETS.md`.
- **Security/review:** 05 + 03.

## Key locked decisions

Python 3.12 + asyncio · **Azure/AKS (full Enhesa mirror)** · hand-built OpenAI-compatible gateway · Qdrant + Elasticsearch hybrid retrieval · Kafka event bus · MLflow · OpenTelemetry → Splunk · OpenAI + Anthropic + Google (Gemini) + MockProvider · Bitbucket Pipelines three-gate CI/CD (tests / evals / canary) · AKS-only dev loop (Skaffold/Tilt). See [02-tech-stack-and-adrs.md](02-tech-stack-and-adrs.md) for rationale.

## Status

Architecture + backlog drafted. **Next:** on approval of `backlog/TICKETS.md`, the epics/stories are created as Linear issues (with labels, estimates, and dependency links). No code yet.
