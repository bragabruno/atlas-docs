# Prompt Promotion Lifecycle

Activity flow showing how a prompt author edits a template, opens a PR, passes the eval gate to advance from draft to candidate to production, and the instant-rollback path via pointer flip.

```mermaid
flowchart TB
    START(["Prompt author edits\nprompt template"])
    DRAFT["Prompt status: draft\n(stored in PostgreSQL)"]
    PR["Open Pull Request\n(Bitbucket Pipelines triggered)"]

    subgraph GATE1["Gate 1 — Correctness"]
        G1["ruff + pyright + pytest\n(MockProvider, zero API spend)"]
    end

    G1PASS{Gate 1 pass?}
    BLOCK1["Block PR\n(correctness failures)"]

    subgraph GATE2["Gate 2 — Eval Quality"]
        G2A["eval-runner vs golden set\n(Azure Blob)"]
        G2B["regression check"]
        G2C["results → MLflow + PR comment"]
        G2A --> G2B --> G2C
    end

    G2PASS{Eval gate pass?}
    BLOCK2["Block PR\n(quality regression)"]

    MERGE["Merge to main"]
    CANDIDATE["Prompt status: candidate\n(pointer updated in registry)"]
    DEPLOY["Gate 3 canary deploy\n(Argo Rollouts 10% traffic)"]
    SLO{SLO analysis pass?}
    PRODUCTION["Prompt status: production\n(registry pointer → new template)"]
    ROLLBACK["Instant rollback:\nregistry pointer flipped\nback to previous production"]

    START --> DRAFT
    DRAFT --> PR
    PR --> GATE1
    GATE1 --> G1PASS
    G1PASS -- fail --> BLOCK1
    G1PASS -- pass --> GATE2
    GATE2 --> G2PASS
    G2PASS -- fail --> BLOCK2
    G2PASS -- pass --> MERGE
    MERGE --> CANDIDATE
    CANDIDATE --> DEPLOY
    DEPLOY --> SLO
    SLO -- pass --> PRODUCTION
    SLO -- fail --> ROLLBACK
    ROLLBACK -.->|previous template re-active| PRODUCTION
```
