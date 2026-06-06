# Three-Gate CI/CD Pipeline

Bitbucket Pipelines flow: PR correctness gate, conditional eval quality gate, build/push to ACR, and canary deployment gate via Argo Rollouts with automatic SLO-based promotion or rollback.

```mermaid
flowchart TB
    PR["Open / update Pull Request"]

    subgraph GATE1["Gate 1 — Correctness"]
        G1A["ruff lint + pyright typecheck"]
        G1B["pytest with MockProvider\nephemeral PostgreSQL + Redis\nzero API spend"]
        G1A --> G1B
    end

    G1RESULT{Gate 1 pass?}

    PROMPT_CHANGED{prompts or agents\nchanged?}

    subgraph GATE2["Gate 2 — Eval Quality"]
        G2A["eval-runner vs golden set\n(Azure Blob)"]
        G2B["regression check"]
        G2C["results → MLflow\nPR comment posted"]
        G2A --> G2B --> G2C
    end

    G2RESULT{Gate 2 pass?}

    MERGE["Merge to main"]

    subgraph BUILD["Build & Publish"]
        BA["docker build"]
        BB["push image → ACR"]
        BA --> BB
    end

    subgraph GATE3["Gate 3 — Safety (Canary)"]
        G3A["Helm deploy"]
        G3B["Argo Rollouts / Flagger\n10% canary traffic"]
        G3C["SLO analysis\nerror-rate · p95 latency\nguardrail-block rate"]
        G3A --> G3B --> G3C
    end

    G3RESULT{SLO analysis pass?}

    PROMOTE["promote to 100%\ncanary finalized"]
    ROLLBACK["auto-rollback\nprevious stable image"]
    BLOCK_PR["block PR merge"]

    PR --> GATE1
    GATE1 --> G1RESULT
    G1RESULT -- fail --> BLOCK_PR
    G1RESULT -- pass --> PROMPT_CHANGED
    PROMPT_CHANGED -- yes --> GATE2
    PROMPT_CHANGED -- no --> MERGE
    GATE2 --> G2RESULT
    G2RESULT -- fail --> BLOCK_PR
    G2RESULT -- pass --> MERGE
    MERGE --> BUILD
    BUILD --> GATE3
    GATE3 --> G3RESULT
    G3RESULT -- pass --> PROMOTE
    G3RESULT -- fail --> ROLLBACK
```
