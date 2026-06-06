# Agent RAG Run End-to-End Sequence

System-level flow for an agent run with retrieval-augmented generation: Frontend through Agent Runtime tool loop, document search, citation verification, guardrails, and distributed tracing.

```mermaid
sequenceDiagram
    autonumber
    participant FE as frontend
    participant AR as "agent-runtime"
    participant GW as gateway
    participant MDS as "mcp-doc-search"
    participant ES as Elasticsearch
    participant QD as Qdrant
    participant MCV as "mcp-citations"
    participant GUARD as "guardrails (post)"
    participant PG as "Azure PostgreSQL"
    participant OTEL as "OTel Collector"
    participant SPLUNK as Splunk

    FE->>AR: start agent run (task, context, session_id)
    AR->>PG: persist run record (run_id, status=running)

    AR->>GW: POST /v1/chat/completions (system prompt + task, tools declared)
    GW-->>AR: LLM response (tool_call: doc_search OR final answer)

    loop agent tool loop
        alt tool_call = doc_search
            AR->>MDS: call doc_search(query, filters)
            MDS->>ES: BM25 keyword search
            ES-->>MDS: keyword-ranked doc chunks
            MDS->>QD: vector similarity search (dense embeddings)
            QD-->>MDS: vector-ranked doc chunks
            MDS->>MDS: hybrid re-rank (BM25 + vector scores)
            MDS-->>AR: chunks + source_ids

            AR->>MCV: call verify_citation(claim, source_ids)
            MCV-->>AR: verification result (supported | unsupported)

            AR->>GW: POST /v1/chat/completions (tool result injected into context)
            GW-->>AR: LLM response (next tool_call OR final answer)
        end

        AR->>PG: persist step (run_id, step_index, tool, input, output, tokens)
    end

    AR->>GUARD: post-guardrail check (schema + citation-enforcement + content-policy)
    alt citation enforcement fails (no supporting source)
        GUARD-->>AR: block — no supporting source
        AR-->>FE: refusal response (citation enforcement)
    else guardrail pass
        GUARD-->>AR: pass
        AR->>PG: update run record (status=completed, final_answer)
        AR-->>FE: final cited answer (answer + citations)
    end

    par multi-span trace
        AR-)OTEL: export parent span (run_id, loop_depth, total_tokens,\ngen_ai.operation.name=agent_run)
        GW-)OTEL: export child spans per LLM call (gen_ai.system,\ngen_ai.request.model, gen_ai.usage.input_tokens,\ngen_ai.usage.output_tokens)
        MDS-)OTEL: export retrieval spans (es_hits, qdrant_hits, rerank_score)
        OTEL-)SPLUNK: forward all traces / metrics / logs
    end
```
