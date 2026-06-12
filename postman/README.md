# Atlas local API cheat-sheet (MockProvider — zero spend)

curl equivalents of [Atlas-Local.postman_collection.json](Atlas-Local.postman_collection.json).
Every chat/embeddings call uses the gateway's built-in **MockProvider** (`model: "mock"`), so
nothing here costs a cent or needs a provider key.

## Bring the stack up

```bash
# Option A — standalone gateway only, on :8000 (zero dependencies, Mock-only):
cd atlas-gateway && docker build -t atlas-gateway . && docker run --rm -p 8000:8000 atlas-gateway

# Option B — full local stack (gateway :8090, agent-runtime :8083, MCP, Postgres, …):
cd atlas-infra && make local-up
```

## Environment

```bash
export ATLAS_BASE=http://localhost:8000    # Option A; use http://localhost:8090 for the compose stack
export ATLAS_KEY=dev-key                   # dev default from ATLAS_API_KEYS
export ATLAS_AGENT=http://localhost:8083   # agent-runtime (compose stack only)
```

## Bulletproof trio

```bash
# 1. Routing surface — model list includes "mock" + the Atlas aliases. Expect 200.
curl -s "$ATLAS_BASE/v1/models" -H "Authorization: Bearer $ATLAS_KEY" | python3 -m json.tool

# 2. A real call through the whole platform (auth → service → provider), zero spend.
#    Expect 200 and content "[mock:mock] echo: What does GDPR Article 6 require?"
curl -s -X POST "$ATLAS_BASE/v1/chat/completions" \
  -H "Authorization: Bearer $ATLAS_KEY" -H "Content-Type: application/json" \
  -d '{"model":"mock","messages":[{"role":"user","content":"What does GDPR Article 6 require?"}],"stream":false}' \
  | python3 -m json.tool

# 3. The cost trail — per-app/model token + cost aggregates. Expect 200 {since, rows}
#    on the compose stack (DB wired); 503 "DB not configured" on the standalone container.
curl -s "$ATLAS_BASE/v1/usage" -H "Authorization: Bearer $ATLAS_KEY" | python3 -m json.tool
# Optional window: curl -s "$ATLAS_BASE/v1/usage?since=2026-01-01" ...
```

## Riskier — test first

```bash
# Embeddings via MockProvider (8-dim vectors, zero spend). Expect 200.
curl -s -X POST "$ATLAS_BASE/v1/embeddings" \
  -H "Authorization: Bearer $ATLAS_KEY" -H "Content-Type: application/json" \
  -d '{"model":"mock","input":"hello atlas"}' | python3 -m json.tool

# Streaming chat — SSE frames ending in "data: [DONE]". Use -N to disable buffering.
curl -s -N -X POST "$ATLAS_BASE/v1/chat/completions" \
  -H "Authorization: Bearer $ATLAS_KEY" -H "Content-Type: application/json" \
  -d '{"model":"mock","messages":[{"role":"user","content":"Stream me something."}],"stream":true}'

# Agent runtime liveness (compose stack; no auth). Expect 200 {"status":"ok"}.
curl -s "$ATLAS_AGENT/healthz"

# Trigger a bounded agent run. Expect 201 with {run_id, status, content, ...}.
# Depends on: gateway reachable from the agent container (compose wires it); the bundled
# spec's model_alias is gpt-oss:120b-cloud (local Ollama — free; set it to "mock" in
# atlas-agent-runtime/agents/regdoc-qa.yaml for fully offline). The full RAG/citation
# path also needs MCP doc-search/citations + Qdrant/Elasticsearch + an ingested corpus,
# so it may error/refuse locally. run_id persistence needs the compose Postgres.
curl -s -X POST "$ATLAS_AGENT/v1/agent/runs" \
  -H "Content-Type: application/json" \
  -d '{"agent_name":"regdoc-qa","user_message":"What does GDPR Article 6 require for consent?"}' \
  | python3 -m json.tool

# Fetch a persisted run (id from the previous response):
# curl -s "$ATLAS_AGENT/v1/agent/runs/<run_id>" | python3 -m json.tool
```

## Enable the cost trail (GET /v1/usage → 200)

The usage endpoint is config-gated: without `ATLAS_DB_URL` the gateway returns
503 by design. The compose stack wires it to the bundled Postgres
(`ATLAS_DB_URL: postgresql://atlas:atlas@postgres:5432/atlas` on the gateway
service) — the `call_records` table just has to exist once:

```bash
cd atlas-infra
# Alembic reads ATLAS_DATABASE_URL (sync +psycopg DSN — different var/driver than
# the runtime's ATLAS_DB_URL, which is asyncpg-style):
docker compose -f local/compose.dev.yaml exec \
  -e ATLAS_DATABASE_URL=postgresql+psycopg://atlas:atlas@postgres:5432/atlas \
  gateway alembic upgrade head
```

Rows stay empty until the accounting recorder is wired into the request path
(GW-14/15) — a 200 with `{"since": "...", "rows": []}` is the working contract.

## Local stack credentials (committed dev placeholders — not secrets)

Everything below is a local-only placeholder defined in
[`atlas-infra/local/compose.dev.yaml`](../../atlas-infra/local/compose.dev.yaml)
(+ `frontend-config.json`). Real deployments source secrets from Azure Key
Vault via the CSI driver (atlas-docs/04 §3) — none of these exist outside the
offline dev loop.

### Application surfaces

| Service | URL | Auth |
|---|---|---|
| Gateway API | http://localhost:8090 | `Authorization: Bearer dev-key` |
| Frontend (Ledger UI) | http://localhost:8080 | none (sends `dev-key` to the gateway itself) |
| Agent runtime API | http://localhost:8083 | none |
| MCP doc-search / citations | :8081 / :8082 (`/mcp`) | none |

### Data stores

| Store | Host | Credentials |
|---|---|---|
| Postgres | `localhost:5432`, db `atlas` | `atlas` / `atlas` |
| Valkey (Redis) | `localhost:6379` | none |
| Qdrant | http://localhost:6333 (gRPC :6334) | none — dashboard at `/dashboard` |
| OpenSearch | http://localhost:9200 | none — security plugin disabled (the `Atlas-local-9200` admin password in compose is unused while security is off) |
| Redpanda (Kafka) | `localhost:9092` | none — PLAINTEXT listener |

### Platform UIs

| Service | URL | Credentials |
|---|---|---|
| MLflow | http://localhost:5500 | none |
| OpenObserve (Splunk stand-in) | http://localhost:5080 | `dev@atlas.local` / `Atlas-local-5080` |
| Azurite (Blob/Queue/Table) | :10000 / :10001 / :10002 | Microsoft's well-known emulator account: `devstoreaccount1` / `Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==` (public, documented) |
| lowkey-vault (Key Vault double) | https://localhost:8443 | not started by default (`--profile parity`); self-signed cert, no auth |
