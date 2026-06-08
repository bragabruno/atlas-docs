# Atlas — Diagram Index

Diagrams span **requirements → context → container → component → low-level (class/state/sequence) → data → user-flow**. System-level / cross-repo diagrams live here in `atlas-docs/diagrams/`; component-specific diagrams live in each repo's `docs/diagrams/`.

- **Mermaid** = `.md` with a ```mermaid block (renders inline on GitHub/Bitbucket). All validated with `mermaid-cli`.
- **PlantUML** = `.puml` (formal UML — use a PlantUML renderer).

## System level (this repo)

### Context & requirements

- [System context — C4 Level 1](context/system-context.md)
- [Use cases — UML](context/use-cases.puml)
- [Requirements traceability — FR/NFR → components](context/requirements-traceability.md)

### Containers

- [Container diagram — C4 Level 2](containers/container-c4.md)

### Data

- [Entity-relationship — PostgreSQL (10 tables)](data/erd.md)
- [Qdrant collections](data/qdrant-collections.md)
- [Kafka topics & event schemas](data/kafka-topics.md)

### Interaction (system-level)

- [Chat request — end to end](sequence/chat-request-e2e.md)
- [Agent RAG run — end to end](sequence/agent-rag-run-e2e.md)

### User flows / activity

- [Analyst → cited answer](flows/analyst-cited-answer.md)
- [Prompt promotion (eval-gated)](flows/prompt-promotion.md)
- [Budget alert response](flows/budget-alert-response.md)

### Cross-cutting

- [CI/CD — three-gate pipeline](cicd/three-gate-pipeline.md)
- [Observability — OTel → Splunk + MLflow](observability/otel-splunk-mlflow.md)

## Component level (in each component repo's `docs/diagrams/`)

| Repo | Diagrams |
|---|---|
| `atlas-gateway` | component-c4 · provider-class *(UML)* · circuit-breaker-state · seq-chat-nonstream · seq-chat-stream · seq-failover · seq-cache-hit |
| `atlas-agent-runtime` | component-c4 · agent-loop-class *(UML)* · agent-run-state · seq-agent-rag · flow-loop-control |
| `atlas-mcp-doc-search` | component-c4 · seq-doc-search-hybrid · class *(UML)* |
| `atlas-mcp-citations` | component-c4 · seq-verify-citation · class *(UML)* |
| `atlas-frontend` | component-tree · module-class *(UML)* · screen-wireflow · seq-frontend-gateway · state-model |
| `atlas-infra` | azure-topology · aks-deployment *(UML)* · tf-module-graph · network-security |
| `atlas-prompts` | eval-gate-flow · prompt-lifecycle-state · eval-runner-sequence |
