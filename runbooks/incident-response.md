# Incident Response Runbook

> **Scope:** Atlas platform (gateway, agent-runtime, mcp-doc-search, mcp-citations, frontend)
> **Environment conventions:** `atlas-dev` / `atlas-prod` namespaces; `atlas-aks-dev` / `atlas-aks-prod` AKS clusters.

---

## 1. Severity Classification

| Severity | Criteria | Response target | Who is paged |
|---|---|---|---|
| **SEV-1** | Full platform down; prod gateway returns 5xx for all requests; SLO breach confirmed | Immediate | On-call engineer + platform lead |
| **SEV-2** | Partial outage (≥1 route broken; guardrail chain failing; canary stuck); sustained SLO breach | < 15 min | On-call engineer |
| **SEV-3** | Degraded performance (elevated latency, high error rate below 100%); eval score regression | < 1 hr | On-call engineer |
| **SEV-4** | Minor issue; single user affected; non-prod environment | Best-effort | Ticket |

---

## 2. Triage Checklist

Run these in order. Stop at the first positive signal and treat that as the blast radius.

### 2.1 Establish context

```bash
# Set to the affected environment
export ENV=prod
export NAMESPACE=atlas-${ENV}
export KUBE_CTX=atlas-${ENV}

# Confirm you're on the right cluster
kubectl config use-context ${KUBE_CTX}
kubectl config current-context   # must match
```

### 2.2 Pod health

```bash
# Quick overview — look for CrashLoopBackOff, OOMKilled, Pending
kubectl get pods -n ${NAMESPACE}

# Detailed pod events (replace <pod-name> with the crashing pod)
kubectl describe pod <pod-name> -n ${NAMESPACE}

# Logs — last 200 lines of the affected service
kubectl logs -n ${NAMESPACE} deploy/gateway         --tail=200 --timestamps
kubectl logs -n ${NAMESPACE} deploy/agent-runtime   --tail=200 --timestamps
kubectl logs -n ${NAMESPACE} deploy/mcp-doc-search  --tail=200 --timestamps
kubectl logs -n ${NAMESPACE} deploy/mcp-citations   --tail=200 --timestamps

# Previous container logs (if pod restarted)
kubectl logs -n ${NAMESPACE} deploy/gateway --previous --tail=100
```

### 2.3 Argo Rollouts canary status

```bash
# Check if a canary is in progress or stuck
kubectl argo rollouts list rollouts -n ${NAMESPACE}
kubectl argo rollouts status gateway -n ${NAMESPACE}
kubectl argo rollouts status agent-runtime -n ${NAMESPACE}

# View canary analysis results
kubectl argo rollouts get rollout gateway -n ${NAMESPACE} --watch
```

### 2.4 Node health

```bash
# Check for NotReady nodes or resource pressure
kubectl get nodes -o wide
kubectl describe node <node-name>   # for any node not Ready

# Node-level resource usage
kubectl top nodes
kubectl top pods -n ${NAMESPACE} --sort-by=memory
```

### 2.5 Platform dependency health

```bash
# Qdrant
kubectl exec -n ${NAMESPACE} deploy/mcp-doc-search -- \
  curl -sf http://atlas-qdrant:6333/readyz

# Elasticsearch
kubectl exec -n ${NAMESPACE} deploy/mcp-doc-search -- \
  curl -sf http://atlas-elasticsearch:9200/_cluster/health | jq .status

# Redis (gateway circuit-breaker + cache)
kubectl exec -n ${NAMESPACE} deploy/gateway -- \
  redis-cli -h atlas-redis ping

# Kafka connectivity (from agent-runtime)
kubectl exec -n ${NAMESPACE} deploy/agent-runtime -- \
  kafkacat -b atlas-kafka:9092 -L -J | jq .brokers
```

---

## 3. Splunk Dashboards to Check

Open these dashboards immediately when triaging a SEV-1 or SEV-2.

| Dashboard | What to look for | SPL hint |
|---|---|---|
| **Reliability** | HTTP error rate by route; spike in 5xx; guardrail block spikes | `index=atlas sourcetype=otel | stats count by http.status_code route` |
| **Latency** | p95 jump above 2 s threshold; slow path: cache miss, tool call, guardrail | `index=atlas | perc95(duration_ms) by route` |
| **Cost** | Sudden token-spend spike (runaway agent loop, misrouted model alias) | `index=atlas | sum(gen_ai.usage.total_tokens) by gen_ai.request.model` |
| **Agent behaviour** | Loop-depth distribution spike; tool call frequency anomaly; abandon rate | `index=atlas | stats avg(atlas.agent.loop_depth) by route` |
| **Cache** | Cache hit rate collapse (cold start vs expected warm ratio) | `index=atlas | stats count(atlas.cache.hit=true), count by route` |
| **Eval trends** | Judge score drop in MLflow (after a prompt deploy) | Check MLflow UI: `Experiments → <prompt version>` |

**Splunk span attributes to filter on:**

```
gen_ai.system            — provider (openai / anthropic / google / mock)
gen_ai.request.model     — model alias
gen_ai.prompt_template.id — prompt version deployed
atlas.guardrail.triggered — true if any guardrail fired
atlas.agent.loop_depth    — depth at time of span
atlas.cache.hit           — true / false
```

**OTel metric namespaces for guardrail signals:**

```
guardrail.pii_detected
guardrail.injection_blocked{stage=input|tool_output}
guardrail.citation_rejected{route, reason}
guardrail.schema_repair_exhausted
guardrail.content_policy_block{category}
```

---

## 4. Communication Protocol

### 4.1 Initial acknowledgement (within 5 min of page)

Post in `#atlas-incidents` (Slack):

```
[SEV-X] <short description>
Status: investigating
Impact: <what is broken / who is affected>
Investigating: <your name>
```

### 4.2 Updates

Post every 15 minutes (SEV-1) or 30 minutes (SEV-2) until resolved:

```
[SEV-X UPDATE <HH:MM UTC>]
Findings: <what you found>
Action taken: <what you did>
Next step: <what you're doing now>
ETA: <estimate or "unknown">
```

### 4.3 Resolution

```
[SEV-X RESOLVED <HH:MM UTC>]
Root cause: <brief>
Fix applied: <what was done>
Verification: <how confirmed>
Follow-up: <ticket ID for post-mortem / prevention>
```

---

## 5. Escalation Path

1. On-call engineer (primary)
2. Platform lead (SEV-1 or if no progress after 20 min)
3. Azure support (infrastructure issues — AKS node failures, network, PaaS outages)

---

## 6. Post-Incident

- Open a post-mortem issue in Linear within 24 h of resolution.
- Required sections: timeline, root cause, impact, what went well, what didn't, action items with owners.
- Action items that prevent recurrence → backlog tickets with priority label.
