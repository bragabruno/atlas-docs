# Analyst: Ask a Question, Receive a Citation-Enforced Answer

User-flow activity diagram showing the path from an analyst's question through agent retrieval and citation verification to a grounded answer, including the refusal branch when no supporting source exists.

```mermaid
flowchart TB
    START(["Analyst submits question\n(via frontend)"])
    GW_AUTH["Gateway: authenticate + guardrail pre-check\n(PII · injection · size)"]
    PRE_FAIL["Return 400/422\nguardrail block"]
    AR_START["Agent Runtime starts run\npersist run_id to PostgreSQL"]
    LLM1["Gateway → LLM: decide retrieval strategy\n(tool_call: doc_search)"]
    DOC_SEARCH["mcp-doc-search:\nBM25 (Elasticsearch) + vector (Qdrant)\nhybrid re-rank → chunks + source_ids"]
    VERIFY["mcp-citations: verify_citation\n(claim vs source_ids)"]

    SOURCES_FOUND{Supporting source\nfound?}

    CITATION_FAIL["Refusal response:\n'No supporting source available'\npost-guardrail blocks answer"]
    COMPOSE["LLM composes answer\nwith inline citations"]
    POST_GUARD["Post-guardrail: schema + citation-enforcement\n+ content-policy"]
    POST_FAIL["Return 422\ncitation enforcement block"]
    ANSWER["Return cited answer\nto frontend"]
    PERSIST["Persist completed run\n+ steps to PostgreSQL"]
    OTEL["Emit OTel spans\n→ Collector → Splunk"]

    START --> GW_AUTH
    GW_AUTH -- violation --> PRE_FAIL
    GW_AUTH -- pass --> AR_START
    AR_START --> LLM1
    LLM1 --> DOC_SEARCH
    DOC_SEARCH --> VERIFY
    VERIFY --> SOURCES_FOUND
    SOURCES_FOUND -- no --> CITATION_FAIL
    SOURCES_FOUND -- yes --> COMPOSE
    COMPOSE --> POST_GUARD
    POST_GUARD -- violation --> POST_FAIL
    POST_GUARD -- pass --> ANSWER
    ANSWER --> PERSIST
    PERSIST --> OTEL
    CITATION_FAIL --> PERSIST
```
