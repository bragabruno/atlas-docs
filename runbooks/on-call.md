# On-Call Runbook

> **Purpose:** Quick orientation for the on-call engineer. What to check first, where things live, how to escalate.

---

## 1. First 5 Minutes

1. Acknowledge the alert in your alerting tool.
2. Post in `#atlas-incidents` that you are investigating (see [incident-response.md](incident-response.md) §4.1 for the message template).
3. Set your kubectl context:

```bash
export ENV=prod      # or dev
export NAMESPACE=atlas-${ENV}
kubectl config use-context atlas-${ENV}
```

4. Run the triage checklist from [incident-response.md](incident-response.md) §2.

---

## 2. Key Signals — What to Check

### 2.1 SLO thresholds that trigger alerts

| SLO | Objective | Window | Alert threshold |
|---|---|---|---|
| API availability | ≥ 99.5% | 28-day rolling | < 99.5% |
| p95 response latency | < 2 s (non-streaming) | 1-hour rolling | > 5 s (auto-rollback) |
| Guardrail block rate | < 5% | 24-hour rolling | > 15% (auto-rollback) |
| Eval score (faithfulness) | ≥ 0.85 weighted mean | Per-deploy gate | < 0.85 blocks the PR |
| Eval score (task success) | ≥ 0.90 | Per-deploy gate | < 0.90 blocks the PR |
| Cache hit rate | ≥ 40% | 24-hour rolling | — (informational) |

### 2.2 Top signal sources

```bash
# 1. Pod status (CrashLoopBackOff = image/config problem; OOMKilled = memory limit)
kubectl get pods -n ${NAMESPACE}

# 2. Recent events (shows node pressure, image pull errors, etc.)
kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp' | tail -30

# 3. Gateway logs — first place to look for 5xx or guardrail rejection bursts
kubectl logs -n ${NAMESPACE} deploy/gateway --tail=200 --timestamps

# 4. Argo Rollouts — is a canary stuck?
kubectl argo rollouts list rollouts -n ${NAMESPACE}

# 5. Resource saturation
kubectl top nodes
kubectl top pods -n ${NAMESPACE} --sort-by=memory
```

### 2.3 OTel → Splunk: key metric names

| Signal | OTel attribute / metric name |
|---|---|
| LLM call span | `gen_ai.system`, `gen_ai.request.model` |
| Prompt version | `gen_ai.prompt_template.id` |
| Guardrail triggered | `atlas.guardrail.triggered` |
| Agent loop depth | `atlas.agent.loop_depth` |
| Semantic cache hit | `atlas.cache.hit` |
| Guardrail PII | `guardrail.pii_detected`, `guardrail.pii_redacted` |
| Injection block | `guardrail.injection_blocked{stage=input\|tool_output}` |
| Citation rejection | `guardrail.citation_rejected{route, reason}` |

---

## 3. Where Things Live

### 3.1 Repos

| Repo | What is there |
|---|---|
| `atlas-infra` | Terraform modules, Helm platform charts, Makefile, Skaffold umbrella, scale-to-zero CronJob |
| `atlas-gateway` | OpenAI-compatible API gateway, prompt registry runtime, guardrail chain, per-service Helm chart |
| `atlas-agent-runtime` | Thin agent loop, YAML agent defs, run/step persistence |
| `atlas-mcp-doc-search` | MCP server — hybrid BM25 + vector search over Elasticsearch + Qdrant |
| `atlas-mcp-citations` | MCP server — citation verification (`verify_citation`) |
| `atlas-prompts` | Prompt templates, agent YAMLs, eval runner, golden-set refs, eval-gate CI pipeline |
| `atlas-frontend` | Angular SPA — RegDoc Q&A app |
| `atlas-docs` | Architecture docs, ADRs, roadmap, this runbook |

### 3.2 Azure resource groups (prod)

| Resource group | Contains |
|---|---|
| `rg-atlas-network-prod` | VNet, subnets, NSGs, private DNS zones |
| `rg-atlas-aks-prod` | AKS cluster, node pools, ACR |
| `rg-atlas-data-prod` | PostgreSQL Flexible Server, Redis Cache |
| `rg-atlas-storage-prod` | Blob Storage (artifacts, traces, golden sets) |
| `rg-atlas-secrets-prod` | Key Vault (`kv-atlas-prod`) |
| `rg-atlas-identity-prod` | User-Assigned Managed Identities |
| `rg-atlas-observability-prod` | OTel Collector resources, MLflow |

### 3.3 Kubernetes namespaces

| Namespace | Contents |
|---|---|
| `atlas-prod` | All Atlas services (prod) |
| `atlas-dev` | All Atlas services (dev) |
| `kube-system` | System components, Secrets Store CSI driver |

### 3.4 Key endpoints

| Service | Internal address (in-cluster) | Port |
|---|---|---|
| Gateway | `http://gateway.atlas-prod.svc` | 8080 |
| Agent runtime | `http://agent-runtime.atlas-prod.svc` | 8081 |
| MCP doc-search | `http://mcp-doc-search.atlas-prod.svc` | 8082 |
| MCP citations | `http://mcp-citations.atlas-prod.svc` | 8083 |
| Qdrant | `http://atlas-qdrant.atlas-prod.svc` | 6333 |
| Elasticsearch | `http://atlas-elasticsearch.atlas-prod.svc` | 9200 |
| Redis | `atlas-redis.atlas-prod.svc` | 6379 |
| MLflow | `http://atlas-mlflow.atlas-prod.svc` | 5000 |

### 3.5 Secrets

All secrets are in Azure Key Vault (`kv-atlas-prod` / `kv-atlas-dev`). Mounted into pods via Secrets Store CSI driver at `/mnt/secrets/`. Do not create Kubernetes `Secret` objects for sensitive values.

```bash
# List secrets in Key Vault (requires Key Vault Secrets User or higher role)
az keyvault secret list --vault-name kv-atlas-prod --output table
```

---

## 4. Common Failure Patterns and First Actions

| Symptom | Likely cause | First action |
|---|---|---|
| All pods `CrashLoopBackOff` after deploy | Bad image or missing Key Vault secret | `kubectl logs deploy/gateway --previous`; check CSI mount |
| Gateway returning 429 on all routes | Budget limit reached for a tenant | Check `atlas.budget.*` metrics in Splunk; raise limit or wait for reset |
| Guardrail block rate > 15% | Injection or PII spike; possible prompt regression | Check `guardrail.injection_blocked` and `guardrail.pii_detected` in Splunk |
| Canary stuck at 10% for > 15 min | AnalysisTemplate failing SLO checks | `kubectl describe analysisrun -n atlas-prod`; check Splunk for error spike |
| Agent abandon rate spike | Max-iteration cap hit; possible infinite loop | Check `atlas.agent.loop_depth` distribution in Splunk; kill runaway sessions |
| Citation rejection rate spike | New prompt version citing non-existent sources | Rollback prompt version (see [rollback.md](rollback.md) §2) |
| Redis disconnected | Azure Cache for Redis restarted or network policy issue | `kubectl exec deploy/gateway -- redis-cli -h atlas-redis ping` |
| OTel spans missing from Splunk | OTel Collector DaemonSet crash | `kubectl get pods -n ${NAMESPACE} | grep otel`; `kubectl logs ds/atlas-otel-collector` |

---

## 5. Escalation

| Level | Contact | When |
|---|---|---|
| On-call engineer | PagerDuty rotation | Always first |
| Platform lead | Direct message | SEV-1, or no progress after 20 min |
| Azure support | `az support tickets create` | AKS node failures, network, PaaS service outages |

For rollback procedures see [rollback.md](rollback.md).
For teardown/cost emergencies see [cost-control.md](cost-control.md) and [teardown.md](teardown.md).
