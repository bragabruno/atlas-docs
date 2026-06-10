# Atlas Production-Grade Demo (POL-7)

Demonstrates the three key production hardening stories in sequence:
semantic cache hit → canary rollback → drift alerting.

## Prerequisites

| Component | Required version |
|-----------|-----------------|
| atlas-gateway | deployed to `atlas-prod` namespace |
| atlas-prompts | nightly CronJob applied (drift-eval-cronjob.yaml) |
| atlas-infra | Argo Rollouts ≥ 1.7, Helm chart with `canary.enabled: true` |
| MLflow | reachable at `$MLFLOW_TRACKING_URI` |
| Webhook sink | any HTTP endpoint (ngrok / Slack inbound) |

---

## Story 1: Semantic Cache Hit (POL-1)

**What to show:** a paraphrase of a prior question is served from the Qdrant
semantic cache in < 5 ms rather than being forwarded to the LLM.

```bash
GATEWAY=https://gateway.atlas-prod.example.com
KEY=<your-api-key>

# First request — cache miss, forwarded to LLM
curl -s -X POST "$GATEWAY/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"atlas-rag","messages":[{"role":"user","content":"What does GDPR Article 6 require?"}],"stream":false}' \
  | jq '.choices[0].message.content'

# Second request — semantic paraphrase, should hit the cache
curl -s -X POST "$GATEWAY/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"atlas-rag","messages":[{"role":"user","content":"Can you explain the requirements under GDPR Article 6?"}],"stream":false}' \
  | jq '.choices[0].message.content'
```

**Verify:** check the Splunk dashboard panel "Semantic cache hit rate" — the
second request shows `atlas.cache.semantic.hits` for the tenant.

---

## Story 2: Canary Rollback (POL-2)

**What to show:** deploy a canary revision of the gateway with a deliberate
latency regression; Argo Rollouts' analysis detects it and auto-rolls back.

```bash
# Deploy the canary (10% traffic weight)
kubectl argo rollouts set image atlas-gateway \
  atlas-gateway=bragabruno/atlas-gateway:canary-slow \
  -n atlas-prod

# Watch the rollout — analysis should fire and pause/abort
kubectl argo rollouts get rollout atlas-gateway -n atlas-prod --watch

# The AnalysisRun queries p95 latency via Prometheus; if p95 > 200ms for
# two consecutive intervals the rollout is aborted and traffic returns to
# the stable revision.

# Confirm rollback
kubectl argo rollouts get rollout atlas-gateway -n atlas-prod | grep "Status"
# Expected: Healthy (stable revision restored)
```

**Verify:** check Splunk panel "Latency p95 by route" — the spike appears at
the canary weight then drops back to baseline.

---

## Story 3: Drift Alerting (POL-5)

**What to show:** the nightly drift-eval job fires an alert when a prompt
version's pass_rate regresses beyond 10%.

### Simulate a regression

```bash
# Create a shadow JSONL file with deliberately bad latency
cat > /tmp/shadow_regression.jsonl <<'EOF'
{"prompt_version":"v1.2","input":"What does GDPR Article 6 require?","output":"I don't know.","model":"gpt-4o","latency_ms":8500.0,"cost_usd":0.05}
{"prompt_version":"v1.2","input":"Explain Article 17.","output":"No information.","model":"gpt-4o","latency_ms":9200.0,"cost_usd":0.06}
{"prompt_version":"v1.2","input":"What is a controller?","output":"Unclear.","model":"gpt-4o","latency_ms":7800.0,"cost_usd":0.04}
EOF

# Run the drift eval in dry-run mode against the simulated file
ATLAS_DRIFT_WEBHOOK_URL=https://your-webhook-sink.example.com/atlas \
MLFLOW_TRACKING_URI=http://mlflow.atlas-prod.svc:5000 \
python scripts/nightly_drift_eval.py \
  --source /tmp/shadow_regression.jsonl \
  --alert-pct 10.0
```

**Expected output:** the script prints the drift report showing `ALERTED` for
`v1.2`, logs `drift_alert dispatched to webhook`, and exits with code 1.

**Verify:** your webhook sink receives a JSON payload:

```json
{
  "text": "Atlas drift alert — 2026-06-10T02:00:00+00:00",
  "summary": "...",
  "evaluated_at": "...",
  "versions": [
    {"prompt_version": "v1.2", "n_samples": 3, "alerted": true, "run_id": "..."}
  ]
}
```

---

## End-to-end checklist

- [ ] Cache hit rate panel shows ≥ 1 hit in the last 5-minute bucket
- [ ] Canary rollback completed in < 10 min from deploy
- [ ] Drift alert received at webhook sink
- [ ] MLflow experiment `atlas-drift` has a new run logged
- [ ] All Atlas pods healthy after the demo (`kubectl get pods -n atlas-prod`)
