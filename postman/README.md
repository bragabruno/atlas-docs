# Atlas local API — Postman collection + curl cheat-sheet (MockProvider — zero spend)

Everything here exercises the **whole local stack** with zero API spend — chat/embeddings use the
gateway's built-in **MockProvider** (`model: "mock"`), so nothing costs a cent or needs a provider key.

## Postman

Three files in this folder:

| File | What |
|---|---|
| [Atlas-Local.postman_collection.json](Atlas-Local.postman_collection.json) | The collection — **30 requests in 5 folders**: Gateway, Agent Runtime, MCP · doc-search, MCP · citations, Platform Stores (ES/Qdrant/MLflow/OpenObserve). |
| [Atlas-Local.postman_environment.json](Atlas-Local.postman_environment.json) | **"Atlas Local (compose)"** — every service on its host port + `dev-key`. Use with `make local-up`. |
| [Atlas-Gateway-Standalone.postman_environment.json](Atlas-Gateway-Standalone.postman_environment.json) | **"Atlas Gateway Standalone (:8000)"** — for the gateway-only `docker run` (Option A). `/v1/usage` returns 503 there (no DB). |

**Import:** in Postman, *Import* → drop all three files → pick the collection, then select an
environment from the top-right dropdown. Run requests, or run a whole folder with the Collection Runner.

- **Auth** is wired at the collection level (`Authorization: Bearer {{api_key}}`); gateway requests
  inherit it, and agent-runtime / MCP / store requests override to No Auth (OpenObserve uses Basic).
- **Variables** (`gateway_url`, `agent_url`, `mcp_docsearch_url`, `api_key`, `demo_source_id`, …) come
  from the selected environment; `run_id` and `mcp_*_session` are filled in at runtime by test scripts.
- **Lightweight tests** assert status + key fields on the smoke requests, so a folder run is a quick
  health check. Newman: `newman run Atlas-Local.postman_collection.json -e Atlas-Local.postman_environment.json`.

### MCP servers in Postman (doc-search :8081, citations :8082)

The MCP servers speak **JSON-RPC 2.0 over Streamable HTTP** at a single `POST /mcp`. Run the four
requests in each MCP folder **in order** — they share a session:

1. **initialize** → 200; the response carries an `Mcp-Session-Id` header that the request's test
   script saves into `{{mcp_<svc>_session}}`.
2. **notifications/initialized** → 202 (completes the handshake).
3. **tools/list** → the one tool (`doc_search` / `verify_citation`).
4. **tools/call** → invoke it.

Every call **must** send both `Content-Type: application/json` **and**
`Accept: application/json, text/event-stream` (a missing dual Accept → 406), plus the captured
`Mcp-Session-Id` and `MCP-Protocol-Version: 2025-06-18` on requests 2–4 — all pre-wired in the requests.
Responses come back as SSE (`event: message` / `data: {…}`); Postman shows them raw.

- **`verify_citation`** works fully offline (pure Elasticsearch + Qdrant lookup by `source_id`).
- **`doc_search`** currently returns `isError: true` in the default local stack: it embeds the query via
  the gateway's `/v1/embeddings`, but the running `mcp-doc-search` container has no `ATLAS_EMBED_MODEL`
  set, so it requests a real embed model the mock-only gateway 404s on. To make it work offline, set
  `ATLAS_EMBED_MODEL=mock` on the `mcp-doc-search` service in `compose.dev.yaml` and recreate it.

> The **Platform Stores** folder needs the corpus seeded — run the seeders first (see
> [Fill the databases](#fill-the-databases-mock-traffic--seeders) below).

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

The accounting recorder (GW-14/15) is wired in the compose loop, so rows
accumulate from real traffic — but only after the api_keys row exists
(`seed-db` below creates it; without it the FK silently blocks recording,
by GW-15's never-fail-the-request contract).

## Fill the databases (mock traffic + seeders)

Accounting (GW-14/15) is wired in the local loop: every **non-streaming**
completion writes a priced `call_records` row and emits an `atlas.calls.v1`
event (streaming deliberately skips accounting — first-token latency).
Everything below is zero-spend (`model=mock`) and runnable from docker alone.

```bash
cd atlas-infra

# 1. Seed Postgres (api_keys, model_aliases, N synthetic call_records) and
#    emit matching Kafka events (watch them in Redpanda Console :8086):
docker compose -f local/compose.dev.yaml --profile jobs run --rm seed-db \
  --records 500 --kafka

# 2. Seed the Elasticsearch + Qdrant corpus (real golden-dataset source_ids,
#    mock 8-dim embeddings — fills the doc_chunks index/collection):
docker compose -f local/compose.dev.yaml run --rm \
  -e ATLAS_GATEWAY_URL=http://gateway:8000 -e ATLAS_GATEWAY_API_KEY=dev-key \
  -e ATLAS_EMBED_MODEL=mock \
  -e ATLAS_ES_URL=http://elasticsearch:9200 -e ATLAS_QDRANT_URL=http://qdrant:6333 \
  --entrypoint sh mcp-doc-search \
  -c "python scripts/make_seed_corpus.py --docs 40 > /tmp/corpus.jsonl && \
      python scripts/ingest.py --source /tmp/corpus.jsonl"

# 3. Stress traffic — Locust web UI at http://localhost:8089:
docker compose -f local/compose.dev.yaml --profile loadtest up locust
#    ...or headless (20 users, 60s):
docker compose -f local/compose.dev.yaml --profile loadtest run --rm locust \
  -f /mnt/locust/locustfile.py --headless -u 20 -r 5 -t 60s

# 4. Contract fuzzing from the committed OpenAPI spec (host venv:
#    pip install -e "atlas-gateway[loadtest]"):
schemathesis run atlas-gateway/openapi.json --url http://localhost:8090 \
  -H "Authorization: Bearer dev-key"
```

What each fills: chat traffic → `call_records` + `atlas.calls.v1` + Valkey
cache · agent runs (`regdoc-qa-mock`) → `agent_runs`/`agent_steps` · corpus
ingest → Elasticsearch `doc_chunks` + Qdrant `doc_chunks` · seed-db → everything
relational at once. Host-venv alternative for iterating on the locustfile:
`pip install -e "atlas-gateway[loadtest]" && locust -f atlas-gateway/loadtest/locustfile.py`.

## Local stack credentials (committed dev placeholders — not secrets)

Everything below is a local-only placeholder defined in
[`atlas-infra/local/compose.dev.yaml`](../../atlas-infra/local/compose.dev.yaml)
(+ `frontend-config.json`). Real deployments source secrets from Azure Key
Vault via the CSI driver (atlas-docs/04 §3) — none of these exist outside the
offline dev loop.

### Application surfaces

| Service | URL | Auth |
|---|---|---|
| Gateway API | `http://localhost:8090` | `Authorization: Bearer dev-key` |
| Frontend (Ledger UI) | `http://localhost:8080` | none (sends `dev-key` to the gateway itself) |
| Agent runtime API | `http://localhost:8083` | none |
| MCP doc-search / citations | :8081 / :8082 (`/mcp`) | none |

### Data stores

| Store | Host | Credentials |
|---|---|---|
| Postgres | `localhost:5432`, db `atlas` | `atlas` / `atlas` |
| Valkey (Redis) | `localhost:6379` | none |
| Qdrant | `http://localhost:6333` (gRPC :6334) | none — dashboard at `/dashboard` |
| Elasticsearch | `http://localhost:9200` | none — xpack security disabled locally (real ES 9.4.0; replaced the OpenSearch substitute, which the pinned client refuses) |
| Redpanda (Kafka) | `localhost:9092` | none — PLAINTEXT listener |

### Platform UIs

| Service | URL | Credentials |
|---|---|---|
| MLflow | `http://localhost:5500` | none |
| Redpanda Console (Kafka UI) | `http://localhost:8086` | none — browse topics like `atlas.calls.v1` |
| RedisInsight (Valkey UI) | `http://localhost:5540` | none — connect to host `valkey`, port `6379` if not pre-registered |
| OpenObserve (Splunk stand-in) | `http://localhost:5080` | `dev@atlas.local` / `Atlas-local-5080` |
| Azurite (Blob/Queue/Table) | :10000 / :10001 / :10002 | Microsoft's well-known emulator account: `devstoreaccount1` / `Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==` (public, documented) |
| lowkey-vault (Key Vault double) | `https://localhost:8443` | not started by default (`--profile parity`); self-signed cert, no auth |

### MLflow SQLite snapshot (for DBeaver)

MLflow's tracking DB is SQLite inside the docker volume. To browse it in
DBeaver, refresh the local snapshot the "Atlas MLflow (snapshot)" connection
points at:

```bash
docker cp atlas-local-mlflow-1:/mlflow/mlflow.db \
  ~/Library/DBeaverData/snapshots/mlflow-snapshot.db
```
