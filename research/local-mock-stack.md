# Local Mock Stack — Free Offline Equivalents for Paid Services

**Status:** Accepted (2026-06-09) · See [ADR-023](../02-tech-stack-and-adrs.md#adr-023-optional-local-offline-dev-loop-docker-compose-alongside-the-aks-loop)

## Purpose

The primary dev loop runs entirely against the AKS `dev` namespace and live Azure
PaaS (see [§4.3 AKS-Only Dev Loop](../04-infra-cicd-observability.md)). That loop is
high-fidelity but **costs real money** and needs network access to Azure. This
document maps every paid / subscription service in the stack
([§1 Full Stack Table](../02-tech-stack-and-adrs.md)) to a **free, local, offline**
equivalent, so contributors can run Atlas end-to-end on a laptop at zero cloud cost.

The runnable stack that wires these together lives in
`atlas-infra/local/compose.dev.yaml` (`make local-up`).

## Two kinds of "free equivalent"

Paid services split into two groups that need different treatment:

1. **Same software, just self-hosted.** Azure / Confluent merely *host* OSS we can run
   in a container with **near-zero fidelity loss** — Postgres, Redis, Qdrant, Kafka,
   Elasticsearch, MLflow. No "mock" needed; run the real engine.
2. **Cloud-proprietary APIs.** No OSS original exists, so we need an **emulator or
   mock**, each with a fidelity caveat — Blob, Key Vault, Monitor/Log Analytics, ACR,
   AKS, the LLM vendor APIs, Doppler.

## Mapping: paid service → free local equivalent

| Production (paid) | Free local equivalent | Pinned image | Type | Fidelity gap |
|---|---|---|---|---|
| Azure PostgreSQL Flexible Server | PostgreSQL | `postgres:16.8` | Same SW | password auth (no Entra MI); no HA/PITR/geo-backup |
| Azure Cache for Redis | Valkey (Redis fork) | `valkey/valkey:8.0` | Same SW | no TLS locally (prod is TLS-only); no access-policy |
| Azure Blob Storage | Azurite (official MS emulator) | `mcr.microsoft.com/azure-storage/azurite:3.33.0` | Emulator | **no CMK, lifecycle, SAS-policy, private-endpoint** |
| Azure Key Vault | lowkey-vault (test double) | `nagyesta/lowkey-vault:3.6.1` | Emulator | not secure; key/secret CRUD only — no RBAC/purge-protection |
| Azure Container Registry | local registry | `registry:2.8.3` | Substitute | no quarantine/scan-on-push/geo-repl |
| AKS | k3d (k3s in Docker) | `rancher/k3s:v1.30.6-k3s1` | Substitute | no Workload Identity / Azure-RBAC / KV-CSI |
| Azure Monitor / Log Analytics | OTel Collector → local sink | `otel/opentelemetry-collector-contrib:0.110.0` | Redirect | sink only; no KQL/workbooks |
| Splunk | OpenObserve (OTel-native) | `openobserve/openobserve:v0.14.4` | Substitute | OTel pipeline ≈ same; query lang ≠ SPL |
| OpenAI / Anthropic / Google APIs | `MockProvider` (in-repo) or Ollama | n/a / `ollama/ollama:0.5.4` | Mock / local LLM | Mock = deterministic-but-fake; Ollama = real-ish, nondeterministic |
| Doppler (dev/CI secrets) | Infisical, or SOPS+age / `.env` | `infisical/infisical:v0.90.0` | Substitute | SOPS/dotenv lose the sync-to-Key-Vault plane |

### Already the real OSS — self-host, no mock

| Service | Pinned image | Note |
|---|---|---|
| Qdrant | `qdrant/qdrant:v1.17.1` | identical engine |
| Kafka → Redpanda | `redpandadata/redpanda:v25.1.1` | Kafka-API compatible, single binary, no ZooKeeper/JVM |
| Elasticsearch → OpenSearch | `opensearchproject/opensearch:3.6.0` | Apache-2.0; minor query-API drift; needs `OPENSEARCH_INITIAL_ADMIN_PASSWORD` |
| MLflow | `ghcr.io/mlflow/mlflow:v3.12.0` | SQLite backend + local artifact dir |

> **Pin note:** MLflow 3.13.0 (2026-06-01) was deliberately **not** chosen — it was
> inside the 14-day supply-chain floor at authoring time. All pins above are exact
> tags (no `latest`); lock to digests and re-check the 14-day floor at `compose` build
> time, per the versioning policy in [§2](../02-tech-stack-and-adrs.md).

## The auth seam: env, not credential code

Atlas services **do not call the Azure SDK directly** — verified across all five
service repos (no `DefaultAzureCredential` / `BlobServiceClient` / `SecretClient`).
Backends and secrets are read from environment variables:

- `atlas-gateway` — `pydantic-settings` (`ATLAS_` prefix, `.env`); capabilities are
  config-gated and default OFF, so with no `ATLAS_REDIS_URL` it runs a Mock-only
  `ChatService` with zero external dependencies.
- `atlas-mcp-doc-search` / `atlas-mcp-citations` — read `ELASTICSEARCH_URL`,
  `QDRANT_URL`, `ATLAS_GATEWAY_URL`, `ATLAS_GATEWAY_API_KEY` straight from `os.environ`.

In production the Key Vault CSI driver injects those as env vars; **locally we set the
same vars to compose hostnames.** No credential-swap code is required — the "shim" is
an env / Helm `values-local` concern:

| Var | Prod source | Local value |
|---|---|---|
| `ATLAS_REDIS_URL` | Key Vault → CSI → env | `redis://valkey:6379` |
| `ELASTICSEARCH_URL` | env | `http://opensearch:9200` |
| `QDRANT_URL` | env | `http://qdrant:6333` |
| `ATLAS_GATEWAY_URL` | env | `http://gateway:8000` |
| LLM provider keys | Key Vault → CSI → env | unset → `model=mock` (MockProvider) |

## What the local stack deliberately does NOT reproduce

The local loop trades fidelity for cost/offline speed. It does **not** exercise the
production security posture, so always validate these against a real `dev` namespace
before release:

- Customer-managed-key encryption, blob lifecycle, SAS-expiry policy, private endpoints.
- Workload Identity / Azure RBAC / Key Vault CSI mounting.
- TLS-only data paths (Redis 6380, Postgres SSL), network ACLs / NSGs.
- AKS API authorized IP ranges, Azure Policy add-on, disk encryption.

Use the local stack for **functional** development (does the request flow work?), and
the AKS `dev` loop for **infrastructure / security** validation.

## Sources

- [Azurite — official Azure Storage emulator (Microsoft Learn)](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azurite)
- [lowkey-vault — Azure Key Vault test double](https://github.com/nagyesta/lowkey-vault)
- [OpenObserve — open-source observability (Splunk alternative)](https://github.com/openobserve/openobserve)
- [SigNoz — OpenTelemetry-native observability](https://github.com/SigNoz/signoz)
- [Infisical — open-source Doppler/Vault alternative](https://infisical.com/blog/doppler-alternatives)
- [Qdrant releases](https://github.com/qdrant/qdrant/releases)
- [Redpanda — Kafka-compatible streaming](https://github.com/redpanda-data/redpanda)
- [OpenSearch releases](https://github.com/opensearch-project/OpenSearch/releases)
- [MLflow releases](https://github.com/mlflow/mlflow/releases)
