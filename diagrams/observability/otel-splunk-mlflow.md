# Observability: OTel → Splunk + MLflow

Data flow for runtime observability (traces, metrics, logs via OpenTelemetry to Splunk) and evaluation observability (eval-runner results to MLflow), converging in operational dashboards.

```mermaid
flowchart TB
    subgraph SERVICES["Atlas Services (OTel SDK instrumented)"]
        GW["gateway\ngen_ai.system\ngen_ai.request.model\ngen_ai.response.model\ngen_ai.usage.input_tokens\ngen_ai.usage.output_tokens\ngen_ai.operation.name"]
        AR["agent-runtime\n(parent span: loop_depth, run_id)"]
        MDS["mcp-doc-search\n(retrieval spans)"]
        MCV["mcp-citations\n(verify_citation spans)"]
    end

    KAFKA_SPANS["Kafka atlas.spans.v1"]

    COLLECTOR["OTel Collector\n(batch · filter · enrich)"]

    subgraph SPLUNK["Splunk"]
        SPL_TRACES["Traces & Spans\n(distributed trace view)"]
        SPL_METRICS["Metrics\n(counters · histograms)"]
        SPL_LOGS["Logs\n(structured events)"]
        subgraph DASHBOARDS["Dashboards"]
            D1["Cost & token spend"]
            D2["Latency (p50/p95/p99)"]
            D3["Cache hit rate"]
            D4["Guardrail block rate"]
            D5["Agent loop depth"]
            D6["Eval trends (linked)"]
        end
    end

    subgraph EVAL["Eval Pipeline"]
        EVAL_RUNNER["eval-runner\n(Gate 2 + scheduled runs)"]
        MLFLOW["MLflow\n(eval runs · metrics · params\nartifact lineage)"]
    end

    GW -->|OTel OTLP| COLLECTOR
    AR -->|OTel OTLP| COLLECTOR
    MDS -->|OTel OTLP| COLLECTOR
    MCV -->|OTel OTLP| COLLECTOR

    GW -.->|async produce| KAFKA_SPANS
    AR -.->|async produce| KAFKA_SPANS

    COLLECTOR --> SPL_TRACES
    COLLECTOR --> SPL_METRICS
    COLLECTOR --> SPL_LOGS

    SPL_TRACES --> DASHBOARDS
    SPL_METRICS --> DASHBOARDS
    SPL_LOGS --> DASHBOARDS

    EVAL_RUNNER -->|log runs / metrics / params| MLFLOW
    MLFLOW -.->|eval trend data| D6
```
