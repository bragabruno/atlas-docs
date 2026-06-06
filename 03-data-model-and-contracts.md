# 03 — Data Model & Contracts

> **Scope** — Authoritative reference for every persistent store, event schema, and API surface in the Atlas platform. Treat this document as the source of truth for schema design; Alembic manages all PostgreSQL migrations.

---

## Table of Contents

1. [PostgreSQL Schema](#1-postgresql-schema)
2. [Cost Computation Spec](#2-cost-computation-spec)
3. [Qdrant Collections](#3-qdrant-collections)
4. [Kafka Topics](#4-kafka-topics)
5. [Gateway API Contract](#5-gateway-api-contract)
6. [MCP Tool Contracts](#6-mcp-tool-contracts)
7. [Internal Interfaces](#7-internal-interfaces)

---

## 1. PostgreSQL Schema

**Host:** Azure Database for PostgreSQL Flexible Server  
**Migration tool:** Alembic (never apply DDL manually in production)

### 1.1 `model_aliases`

```sql
CREATE TYPE provider_enum AS ENUM ('anthropic', 'openai', 'google', 'azure_openai');

CREATE TABLE model_aliases (
    alias            TEXT        PRIMARY KEY,                 -- e.g. "smart", "deep", "fast"
    primary_model_id TEXT        NOT NULL,                   -- canonical model string, e.g. "claude-sonnet-4-6"
    fallback_model_id TEXT       NOT NULL,                   -- e.g. "gpt-4.1"
    provider         provider_enum NOT NULL,
    in_price_per_1m  NUMERIC(10,6) NOT NULL,                 -- USD, input tokens per 1M
    out_price_per_1m NUMERIC(10,6) NOT NULL,                 -- USD, output tokens per 1M
    per_key_overrides JSONB      NOT NULL DEFAULT '{}',      -- {api_key_id: {in_price, out_price}} overrides
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- No index needed; PK on alias covers all lookups.
```

**Design notes:**
- Prices are pinned at alias-creation time so historical cost in `call_records` is always reproducible.
- `per_key_overrides` supports negotiated rates per tenant without a separate table.

---

### 1.2 `api_keys`

```sql
CREATE TYPE key_status_enum AS ENUM ('active', 'suspended', 'revoked');

CREATE TABLE api_keys (
    id           UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    hashed_secret TEXT         NOT NULL UNIQUE,              -- bcrypt or SHA-256 hash; plaintext never stored
    app          TEXT          NOT NULL,                     -- logical application name
    owner        TEXT          NOT NULL,                     -- team or individual identifier
    status       key_status_enum NOT NULL DEFAULT 'active',
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE INDEX idx_api_keys_hashed_secret ON api_keys (hashed_secret);
CREATE INDEX idx_api_keys_app           ON api_keys (app);
```

---

### 1.3 `budgets`

```sql
CREATE TABLE budgets (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    api_key_id      UUID        NOT NULL REFERENCES api_keys(id) ON DELETE CASCADE,
    monthly_cap_usd NUMERIC(12,4) NOT NULL,
    current_spend   NUMERIC(12,4) NOT NULL DEFAULT 0,
    alert_at_80pct  BOOLEAN     NOT NULL DEFAULT TRUE,
    reset_cycle     TEXT        NOT NULL DEFAULT 'monthly',  -- 'monthly' | 'weekly' | 'daily'
    period_start    DATE        NOT NULL,                    -- start of current billing window
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT budgets_api_key_unique UNIQUE (api_key_id)
);

CREATE INDEX idx_budgets_api_key_id ON budgets (api_key_id);
```

---

### 1.4 `call_records`

```sql
CREATE TABLE call_records (
    id                           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    api_key_id                   UUID        NOT NULL REFERENCES api_keys(id),
    app                          TEXT        NOT NULL,
    prompt_version_id            UUID,                                -- NULL when prompt_ref not used
    alias                        TEXT        REFERENCES model_aliases(alias),
    model                        TEXT        NOT NULL,                -- resolved model id
    provider                     provider_enum NOT NULL,
    input_tokens                 INTEGER     NOT NULL DEFAULT 0,
    output_tokens                INTEGER     NOT NULL DEFAULT 0,
    cache_creation_input_tokens  INTEGER     NOT NULL DEFAULT 0,      -- tokens written to prompt cache
    cache_read_input_tokens      INTEGER     NOT NULL DEFAULT 0,      -- tokens served from prompt cache
    computed_cost_usd            NUMERIC(12,8) NOT NULL,
    latency_ms                   INTEGER     NOT NULL,
    status                       SMALLINT    NOT NULL,                -- HTTP status code
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_call_records_api_key_id  ON call_records (api_key_id, created_at DESC);
CREATE INDEX idx_call_records_created_at  ON call_records (created_at DESC);
CREATE INDEX idx_call_records_alias       ON call_records (alias);
```

---

### 1.5 `prompts` and `prompt_versions`

```sql
CREATE TABLE prompts (
    id         UUID  PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT  NOT NULL UNIQUE                         -- human-readable slug, e.g. "summarize-doc"
);

CREATE TYPE prompt_status_enum AS ENUM ('draft', 'candidate', 'production', 'retired');

CREATE TABLE prompt_versions (
    id            UUID              PRIMARY KEY DEFAULT gen_random_uuid(),
    prompt_id     UUID              NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
    semver        TEXT              NOT NULL,                -- e.g. "1.2.0"; SemVer format enforced by app layer
    template      TEXT              NOT NULL,               -- Jinja2/Mustache template string
    params_schema JSONB             NOT NULL DEFAULT '{}',  -- JSON Schema object describing template variables
    model_alias   TEXT              REFERENCES model_aliases(alias),
    status        prompt_status_enum NOT NULL DEFAULT 'draft',
    created_at    TIMESTAMPTZ       NOT NULL DEFAULT now(),
    CONSTRAINT prompt_versions_semver_unique UNIQUE (prompt_id, semver)
);

CREATE INDEX idx_prompt_versions_prompt_id ON prompt_versions (prompt_id);
CREATE INDEX idx_prompt_versions_status    ON prompt_versions (status);
```

**Status lifecycle:** `draft` → `candidate` → `production`; any state → `retired`. Only one version per prompt may hold `production` status at a time (enforced by a partial unique index or application-level constraint).

---

### 1.6 `eval_runs` and `eval_results`

```sql
CREATE TABLE eval_runs (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    prompt_version_id UUID        NOT NULL REFERENCES prompt_versions(id),
    dataset_version   TEXT        NOT NULL,                 -- e.g. "v3.1" — version tag of evaluation dataset
    triggered_by      TEXT        NOT NULL,                 -- "ci", "manual:<user>", "shadow_drift"
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_eval_runs_prompt_version ON eval_runs (prompt_version_id, created_at DESC);

CREATE TABLE eval_results (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    eval_run_id    UUID        NOT NULL REFERENCES eval_runs(id) ON DELETE CASCADE,
    metric         TEXT        NOT NULL,                    -- e.g. "accuracy", "latency_p95", "cost_usd"
    value          NUMERIC(14,6) NOT NULL,
    baseline_value NUMERIC(14,6),                           -- NULL for first run of a prompt
    passed         BOOLEAN     NOT NULL
);

CREATE INDEX idx_eval_results_eval_run_id ON eval_results (eval_run_id);
```

---

### 1.7 `agent_runs` and `agent_steps`

```sql
CREATE TYPE agent_status_enum AS ENUM ('running', 'completed', 'failed', 'cancelled');

CREATE TABLE agent_runs (
    id            UUID              PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_name    TEXT              NOT NULL,
    agent_version TEXT              NOT NULL,               -- SemVer
    status        agent_status_enum NOT NULL DEFAULT 'running',
    token_budget  INTEGER,                                  -- NULL = unlimited
    tokens_used   INTEGER           NOT NULL DEFAULT 0,
    started_at    TIMESTAMPTZ       NOT NULL DEFAULT now(),
    ended_at      TIMESTAMPTZ
);

CREATE INDEX idx_agent_runs_status      ON agent_runs (status, started_at DESC);
CREATE INDEX idx_agent_runs_agent_name  ON agent_runs (agent_name, started_at DESC);

CREATE TYPE step_type_enum AS ENUM ('llm_call', 'tool_call');

CREATE TABLE agent_steps (
    id          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_run_id UUID         NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE,
    idx         INTEGER       NOT NULL,                     -- zero-based step index within the run
    type        step_type_enum NOT NULL,
    payload     JSONB         NOT NULL,                     -- full request/response or tool invocation details
    tokens      INTEGER       NOT NULL DEFAULT 0,
    latency_ms  INTEGER       NOT NULL,
    CONSTRAINT agent_steps_run_idx_unique UNIQUE (agent_run_id, idx)
);

CREATE INDEX idx_agent_steps_agent_run_id ON agent_steps (agent_run_id, idx);
```

---

## 2. Cost Computation Spec

### Formula

```
computed_cost_usd =
    (input_tokens                 * in_rate_per_1m  / 1_000_000)
  + (output_tokens                * out_rate_per_1m / 1_000_000)
  + (cache_creation_input_tokens  * in_rate_per_1m  / 1_000_000 * 1.25)
  + (cache_read_input_tokens      * in_rate_per_1m  / 1_000_000 * 0.10)
```

Where `in_rate_per_1m` and `out_rate_per_1m` are fetched from the `model_aliases` row (or its `per_key_overrides`) at **call time** and stored in the `call_records` row alongside the tokens — this makes the cost auditable and reproducible even if alias prices change later.

### Token Field Semantics

| Field | Description | Billing multiplier |
|---|---|---|
| `input_tokens` | Non-cached prompt tokens | 1.0× input rate |
| `cache_creation_input_tokens` | Tokens written to the provider's prompt cache on this call | 1.25× input rate |
| `cache_read_input_tokens` | Tokens served from the provider's prompt cache on this call | 0.10× input rate |
| `output_tokens` | Generated completion tokens | 1.0× output rate |

These values are populated verbatim from the provider's usage response object (e.g. Anthropic `usage.cache_creation_input_tokens`).

### Worked Example — `smart` alias (claude-sonnet-4-6, $3/$15 per 1M)

```
input_tokens                = 800
output_tokens               = 200
cache_creation_input_tokens = 500
cache_read_input_tokens     = 300

cost = (800  * 3  / 1_000_000)       = $0.002400   # standard input
     + (200  * 15 / 1_000_000)       = $0.003000   # output
     + (500  * 3  / 1_000_000 * 1.25)= $0.001875   # cache write premium
     + (300  * 3  / 1_000_000 * 0.10)= $0.000090   # cache read discount

computed_cost_usd = $0.007365
```

### Token Counting

Token counts are obtained from the **provider's own counting endpoint** (Anthropic: `POST /v1/messages/count_tokens`). `tiktoken` is never used — it produces incorrect counts for non-OpenAI models and must not be introduced.

### Seed Alias Prices

| Alias | Primary model | Fallback model | In $/1M | Out $/1M |
|---|---|---|---|---|
| `smart` | claude-sonnet-4-6 | gpt-4.1 | $3.00 | $15.00 |
| `deep` | claude-opus-4-8 | gpt-4.1 | $5.00 | $25.00 |
| `fast` | claude-haiku-4-5 | gpt-4.1-mini | $1.00 | $5.00 |
| `balanced` | *(current Gemini model — set at deploy)* | — | *(placeholder)* | *(placeholder)* |
| `embed` | *(embeddings model — set at deploy)* | — | *(placeholder)* | — |

GPT-4.1 and Gemini prices are managed as environment variables (`ALIAS_GPT41_IN_PRICE`, `ALIAS_GPT41_OUT_PRICE`, etc.) and seeded via Alembic data migration.

---

## 3. Qdrant Collections

### 3.1 `doc_chunks`

| Property | Value |
|---|---|
| **Vector dimension** | TBD at build time (determined by chosen embedding model) |
| **Distance metric** | Cosine |
| **Index type** | HNSW |
| **HNSW m** | 16 (default; tune on recall benchmarks) |
| **HNSW ef_construct** | 100 |
| **Quantization** | None by default; enable scalar int8 if memory pressure requires |
| **Retention/eviction** | No TTL — documents are deleted explicitly via source ingestion pipeline on document removal |

**Payload schema:**

```json
{
  "source_id": "string",      // opaque ID of the source document (e.g. Confluence page ID)
  "doc_id":    "string",      // internal Atlas document record ID
  "chunk_idx": "integer",     // zero-based chunk position within the document
  "text":      "string"       // raw chunk text for retrieval display and BM25 hybrid re-rank
}
```

All payload fields are indexed as keyword/integer filters to support pre-filter by `source_id` or `doc_id`.

---

### 3.2 `semantic_cache`

| Property | Value |
|---|---|
| **Vector** | Embedding of the incoming request (same model as `embed` alias) |
| **Distance metric** | Cosine |
| **Similarity threshold** | **0.97** — requests below this score always bypass the cache |
| **Index type** | HNSW |
| **TTL** | 24 hours (Qdrant collection-level TTL on `created_at` payload field) |

**Payload schema:**

```json
{
  "api_key_id":      "string",      // tenant identifier — used for mandatory tenant isolation
  "prompt_version":  "string",      // prompt_versions.id that produced this response
  "response":        "string",      // serialized completion response (non-stream only)
  "created_at":      "integer"      // Unix timestamp (seconds) — used for TTL eviction
}
```

**Safety rules — both are hard requirements, not configuration options:**

1. **NEVER cross-tenant.** Every cache lookup MUST include a `api_key_id` filter. A cache hit from a different tenant is treated as a miss.
2. **NEVER cache citation-containing answers.** Before writing to `semantic_cache`, the response is inspected for citation markers (footnotes, `[source: …]` patterns, inline URL references). If any are detected the write is skipped and the response is served uncached.

---

## 4. Kafka Topics

All topics use a 7-day default retention unless stated otherwise. Consumers are expected to be idempotent.

---

### 4.1 `atlas.calls.v1`

**Purpose:** Per-call accounting events. Downstream consumers update `budgets.current_spend` and power real-time dashboards.

**Partition key:** `api_key_id` — ensures all events for a given tenant land on the same partition for ordered, in-sequence budget aggregation.

**Retention:** 30 days (billing audit requirement).

**Payload schema:**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["event_id", "api_key_id", "call_record_id", "alias", "model", "provider",
               "input_tokens", "output_tokens", "cache_creation_input_tokens",
               "cache_read_input_tokens", "computed_cost_usd", "latency_ms",
               "status", "created_at"],
  "properties": {
    "event_id":                    { "type": "string", "format": "uuid" },
    "api_key_id":                  { "type": "string", "format": "uuid" },
    "call_record_id":              { "type": "string", "format": "uuid" },
    "alias":                       { "type": ["string", "null"] },
    "model":                       { "type": "string" },
    "provider":                    { "type": "string", "enum": ["anthropic", "openai", "google", "azure_openai"] },
    "input_tokens":                { "type": "integer", "minimum": 0 },
    "output_tokens":               { "type": "integer", "minimum": 0 },
    "cache_creation_input_tokens": { "type": "integer", "minimum": 0 },
    "cache_read_input_tokens":     { "type": "integer", "minimum": 0 },
    "computed_cost_usd":           { "type": "number" },
    "latency_ms":                  { "type": "integer", "minimum": 0 },
    "status":                      { "type": "integer" },
    "created_at":                  { "type": "string", "format": "date-time" }
  }
}
```

**Producers:** Gateway service (one event per completed call).  
**Consumers:** Budget service, analytics aggregator, alerting service.

---

### 4.2 `atlas.spans.v1`

**Purpose:** OpenTelemetry span fan-out. Feeds the Atlas trace backend and any external observability sinks (Jaeger, Datadog, etc.).

**Partition key:** `trace_id` — collocates all spans from the same trace on one partition, simplifying trace assembly.

**Retention:** 7 days.

**Payload schema:**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["trace_id", "span_id", "parent_span_id", "name", "service", "start_time_unix_nano", "end_time_unix_nano", "attributes", "status"],
  "properties": {
    "trace_id":             { "type": "string" },
    "span_id":              { "type": "string" },
    "parent_span_id":       { "type": ["string", "null"] },
    "name":                 { "type": "string" },
    "service":              { "type": "string" },
    "start_time_unix_nano": { "type": "integer" },
    "end_time_unix_nano":   { "type": "integer" },
    "attributes":           { "type": "object", "additionalProperties": true },
    "status": {
      "type": "object",
      "properties": {
        "code":    { "type": "string", "enum": ["UNSET", "OK", "ERROR"] },
        "message": { "type": ["string", "null"] }
      }
    }
  }
}
```

**Producers:** Gateway service, agent executor, eval runner.  
**Consumers:** OTel collector, trace storage service.

---

### 4.3 `atlas.shadow.v1`

**Purpose:** Sampled live traffic for drift detection and offline evaluation. The gateway writes a configurable fraction (default 5%) of production requests here.

**Partition key:** `alias` — groups traffic by model alias for alias-level drift comparisons.

**Retention:** 14 days.

**Payload schema:**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["shadow_id", "api_key_id", "alias", "model", "request_messages", "response_message", "usage", "created_at"],
  "properties": {
    "shadow_id":        { "type": "string", "format": "uuid" },
    "api_key_id":       { "type": "string", "format": "uuid" },
    "alias":            { "type": "string" },
    "model":            { "type": "string" },
    "request_messages": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "role":    { "type": "string" },
          "content": { "type": "string" }
        }
      }
    },
    "response_message": {
      "type": "object",
      "properties": {
        "role":    { "type": "string" },
        "content": { "type": "string" }
      }
    },
    "usage": {
      "type": "object",
      "properties": {
        "input_tokens":                { "type": "integer" },
        "output_tokens":               { "type": "integer" },
        "cache_creation_input_tokens": { "type": "integer" },
        "cache_read_input_tokens":     { "type": "integer" }
      }
    },
    "created_at": { "type": "string", "format": "date-time" }
  }
}
```

**Producers:** Gateway service (sampled).  
**Consumers:** Drift eval scheduler, dataset builder.

---

### 4.4 `atlas.eval.requests.v1`

**Purpose:** Eval trigger requests. Decouples CI pipelines and the drift scheduler from the eval runner.

**Partition key:** `prompt_version_id` — serialises eval requests per prompt version to avoid concurrent runs on the same version.

**Retention:** 7 days.

**Payload schema:**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["request_id", "prompt_version_id", "dataset_version", "triggered_by", "requested_at"],
  "properties": {
    "request_id":         { "type": "string", "format": "uuid" },
    "prompt_version_id":  { "type": "string", "format": "uuid" },
    "dataset_version":    { "type": "string" },
    "triggered_by":       { "type": "string" },
    "priority":           { "type": "string", "enum": ["low", "normal", "high"], "default": "normal" },
    "requested_at":       { "type": "string", "format": "date-time" }
  }
}
```

**Producers:** CI pipeline, drift eval scheduler, manual trigger API.  
**Consumers:** Eval runner service.

---

## 5. Gateway API Contract

The Atlas Gateway exposes an **OpenAI-compatible** REST API. Clients that already target the OpenAI SDK require only a base URL change.

**Base URL:** `https://atlas.internal/v1` (configurable via `ATLAS_GATEWAY_BASE_URL`)

### 5.1 Authentication

All requests require a bearer token in the `Authorization` header. The token is an Atlas API key (plaintext, transmitted over TLS only).

```
Authorization: Bearer <atlas-api-key>
```

The gateway hashes the incoming secret, looks up `api_keys.hashed_secret`, and checks `api_keys.status == 'active'` before routing the request.

---

### 5.2 `POST /v1/chat/completions`

#### Request schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "oneOf": [
    { "required": ["model", "messages"] },
    { "required": ["prompt_ref", "messages"] }
  ],
  "properties": {
    "model": {
      "type": "string",
      "description": "A model_aliases.alias value (e.g. 'smart', 'deep'). Mutually exclusive with prompt_ref."
    },
    "prompt_ref": {
      "type": "string",
      "description": "Registry reference in the form '<prompt_name>@<semver>' or '<prompt_name>@production'. Resolves to a prompt_versions row; the alias is taken from that row. Mutually exclusive with model.",
      "examples": ["summarize-doc@1.2.0", "extract-entities@production"]
    },
    "messages": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["role", "content"],
        "properties": {
          "role":    { "type": "string", "enum": ["system", "user", "assistant"] },
          "content": { "type": "string" }
        }
      },
      "minItems": 1
    },
    "stream":       { "type": "boolean", "default": false },
    "temperature":  { "type": "number", "minimum": 0, "maximum": 2 },
    "max_tokens":   { "type": "integer", "minimum": 1 },
    "top_p":        { "type": "number", "minimum": 0, "maximum": 1 },
    "stop":         { "type": ["string", "array"], "items": { "type": "string" } },
    "user":         { "type": "string", "description": "Caller-supplied end-user identifier for abuse tracking." }
  }
}
```

**Design note:** Clients MUST pass either `model` (an alias) or `prompt_ref` (a registry reference). Embedding raw prompt text in the request is not supported and will return `400 Bad Request`.

---

#### Non-stream response (HTTP 200)

```json
{
  "id":      "chatcmpl-<uuid>",
  "object":  "chat.completion",
  "created": 1749200000,
  "model":   "claude-sonnet-4-6",
  "choices": [
    {
      "index":         0,
      "message": {
        "role":    "assistant",
        "content": "The answer is …"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens":     800,
    "completion_tokens": 200,
    "total_tokens":      1000
  }
}
```

`finish_reason` values: `"stop"`, `"length"`, `"content_filter"`, `"tool_calls"`.

---

#### Streaming response (`stream: true`)

**Content-Type:** `text/event-stream`

Each chunk is a Server-Sent Event:

```
data: {"id":"chatcmpl-<uuid>","object":"chat.completion.chunk","created":1749200000,"model":"claude-sonnet-4-6","choices":[{"index":0,"delta":{"role":"assistant","content":"The "},"finish_reason":null}]}

data: {"id":"chatcmpl-<uuid>","object":"chat.completion.chunk","created":1749200000,"model":"claude-sonnet-4-6","choices":[{"index":0,"delta":{"content":"answer"},"finish_reason":null}]}

data: {"id":"chatcmpl-<uuid>","object":"chat.completion.chunk","created":1749200000,"model":"claude-sonnet-4-6","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

The stream is terminated by the **literal string `data: [DONE]`** (no JSON parsing required on that final line). Clients must handle partial UTF-8 across chunk boundaries.

---

#### 429 — Rate Limit Exceeded

```json
{
  "error": {
    "code":    "rate_limit_exceeded",
    "message": "Request rate limit reached for alias 'smart'. Retry after 10 seconds.",
    "type":    "rate_limit_error",
    "param":   null
  }
}
```

**Headers:** `Retry-After: <seconds>`

---

#### 429 — Budget Exceeded

```json
{
  "error": {
    "code":    "budget_exceeded",
    "message": "Monthly spend cap of $50.00 has been reached for this API key. Cap resets on 2026-07-01.",
    "type":    "budget_error",
    "param":   null
  }
}
```

---

### 5.3 `GET /v1/models`

Returns the list of available model aliases visible to the authenticated key.

**Response (HTTP 200):**

```json
{
  "object": "list",
  "data": [
    {
      "id":       "smart",
      "object":   "model",
      "created":  1749200000,
      "owned_by": "atlas"
    },
    {
      "id":       "deep",
      "object":   "model",
      "created":  1749200000,
      "owned_by": "atlas"
    }
  ]
}
```

---

### 5.4 `POST /v1/embeddings`

#### Request schema

```json
{
  "type": "object",
  "required": ["input", "model"],
  "properties": {
    "input": {
      "oneOf": [
        { "type": "string" },
        { "type": "array", "items": { "type": "string" } }
      ]
    },
    "model":           { "type": "string", "description": "Must be the 'embed' alias." },
    "encoding_format": { "type": "string", "enum": ["float", "base64"], "default": "float" }
  }
}
```

#### Response (HTTP 200)

```json
{
  "object": "list",
  "data": [
    {
      "object":    "embedding",
      "index":     0,
      "embedding": [0.0023, -0.0091, "..."]
    }
  ],
  "model": "embed",
  "usage": {
    "prompt_tokens": 12,
    "total_tokens":  12
  }
}
```

---

## 6. MCP Tool Contracts

Atlas exposes MCP tools callable by agents. Inputs and outputs follow JSON Schema Draft-07.

### 6.1 `doc_search`

Hybrid retrieval: BM25 (Elasticsearch) + dense vector (Qdrant `doc_chunks`), results fused and ranked.

**Input schema:**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["query"],
  "properties": {
    "query": {
      "type": "string",
      "description": "Natural-language search query.",
      "minLength": 1,
      "maxLength": 2000
    },
    "k": {
      "type": "integer",
      "description": "Number of chunks to return.",
      "default": 8,
      "minimum": 1,
      "maximum": 50
    }
  },
  "additionalProperties": false
}
```

**Output schema:**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["chunks"],
  "properties": {
    "chunks": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "text", "source_id", "score"],
        "properties": {
          "id":        { "type": "string", "description": "Qdrant point ID for this chunk." },
          "text":      { "type": "string", "description": "Chunk text." },
          "source_id": { "type": "string", "description": "Opaque source document identifier." },
          "score":     { "type": "number", "description": "Fused relevance score (0–1).", "minimum": 0, "maximum": 1 }
        }
      }
    }
  }
}
```

---

### 6.2 `verify_citation`

Checks whether a specific claim can be grounded in a source document. Used to prevent hallucinated citations before they reach the semantic cache or end-user responses.

**Input schema:**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["source_id", "claim"],
  "properties": {
    "source_id": {
      "type": "string",
      "description": "The source_id value from a doc_search result."
    },
    "claim": {
      "type": "string",
      "description": "The factual claim to verify against the source.",
      "minLength": 1,
      "maxLength": 1000
    }
  },
  "additionalProperties": false
}
```

**Output schema:**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["exists"],
  "properties": {
    "exists": {
      "type": "boolean",
      "description": "True if the claim is supported by the source document."
    },
    "snippet": {
      "type": ["string", "null"],
      "description": "Supporting text excerpt from the source, or null if exists is false."
    }
  }
}
```

---

## 7. Internal Interfaces

These interfaces are service-internal contracts, not exposed over HTTP. They are defined here to govern the contracts between Atlas subsystems.

### 7.1 Prompt Registry — `resolve(ref) -> ResolvedConfig`

The registry service exposes a synchronous `resolve` call used by the gateway and agent executor before every LLM call.

**Input:** a `prompt_ref` string (e.g. `"summarize-doc@production"`, `"extract-entities@1.2.0"`) or a bare alias string (e.g. `"smart"`).

**Output — `ResolvedConfig`:**

```json
{
  "prompt_version_id": "<uuid or null>",
  "template":          "<rendered template string or null>",
  "params_schema":     "<JSON Schema object or null>",
  "alias":             "smart",
  "model":             "claude-sonnet-4-6",
  "fallback_model":    "gpt-4.1",
  "provider":          "anthropic",
  "in_price_per_1m":   3.00,
  "out_price_per_1m":  15.00
}
```

**Contract rules:**
- If `ref` is a bare alias, `prompt_version_id` and `template` are `null`; the caller is responsible for constructing the messages array.
- If `ref` is a `prompt_ref`, the template must be rendered with caller-supplied variables before being injected as the system message.
- `resolve` MUST return only `prompt_versions` rows with `status = 'production'` when the semver label is `@production`; any other `@<semver>` resolves directly by version.
- Resolution results are cached in-process for 60 seconds (short TTL to allow production promotion to propagate without restart).

---

### 7.2 Eval Runner — `submit_eval(prompt_version_id, dataset_version) -> eval_run_id`

Triggered by consuming a message from `atlas.eval.requests.v1`.

**Input:**

```json
{
  "prompt_version_id": "<uuid>",
  "dataset_version":   "v3.1",
  "triggered_by":      "ci"
}
```

**Output:** The eval runner creates one `eval_runs` row, executes the prompt against every item in the dataset snapshot, and inserts one `eval_results` row per metric per run. It returns the `eval_run_id` (UUID) to the caller.

**Behaviour contract:**
- The runner loads the prompt template from `prompt_versions` by `id`; it does not accept inline templates in the trigger payload.
- Each eval item is run as a non-streaming `POST /v1/chat/completions` call through the gateway (using a dedicated eval API key) so that cost and latency are recorded in `call_records`.
- `eval_results.passed` is set by comparing `value` against `baseline_value` using metric-specific thresholds defined in the eval dataset manifest (not hardcoded here).
- On completion the runner publishes a summary span to `atlas.spans.v1`.

---

*Document owner: Platform Engineering. Last schema change tracked in Alembic revision history.*
