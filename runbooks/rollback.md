# Rollback Runbook

> **Three rollback surfaces:** gateway service (Argo Rollouts), prompt version (registry production-pointer flip), database migration (Alembic downgrade).
> Always confirm which surface is implicated before rolling back.

---

## 1. Gateway Service Rollback (Argo Rollouts)

The gateway, agent-runtime, mcp-doc-search, mcp-citations, and frontend all use Argo Rollouts canary deployments in prod. A rollback reverts to the last stable revision.

### 1.1 Check current rollout state

```bash
export NAMESPACE=atlas-prod
export KUBE_CTX=atlas-prod
kubectl config use-context ${KUBE_CTX}

# List all rollouts and their status
kubectl argo rollouts list rollouts -n ${NAMESPACE}

# Inspect a specific rollout (replace <service> with gateway / agent-runtime / etc.)
kubectl argo rollouts get rollout <service> -n ${NAMESPACE}
```

### 1.2 Abort a stuck canary

If the canary is still in progress and SLOs are breaching, abort before undoing:

```bash
kubectl argo rollouts abort <service> -n ${NAMESPACE}
```

The controller immediately shifts 100% traffic back to the stable pods.

### 1.3 Undo — revert to the previous stable revision

```bash
# Rollback gateway to previous stable image
kubectl argo rollouts undo gateway -n ${NAMESPACE}

# Rollback agent-runtime
kubectl argo rollouts undo agent-runtime -n ${NAMESPACE}

# Rollback mcp-doc-search
kubectl argo rollouts undo mcp-doc-search -n ${NAMESPACE}

# Rollback mcp-citations
kubectl argo rollouts undo mcp-citations -n ${NAMESPACE}

# Rollback frontend
kubectl argo rollouts undo frontend -n ${NAMESPACE}
```

### 1.4 Monitor rollback progress

```bash
# Watch until stable
kubectl argo rollouts status <service> -n ${NAMESPACE} --timeout 5m

# Confirm running image tag
kubectl argo rollouts get rollout <service> -n ${NAMESPACE} \
  -o jsonpath='{.status.stableRS.podTemplateHash}'
```

### 1.5 Verify SLOs recovered

Check the **Reliability** Splunk dashboard. SLOs:

| SLO | Threshold | Auto-rollback trigger |
|---|---|---|
| HTTP error rate | < 1% | > 2% sustained 3 min |
| p95 latency | < 2 s | > 5 s sustained 3 min |
| Guardrail block rate | < 5% | > 15% sustained 3 min |

If the rollback was triggered automatically by an `AnalysisTemplate` failure, confirm via:

```bash
kubectl get analysisrun -n ${NAMESPACE}
kubectl describe analysisrun <analysisrun-name> -n ${NAMESPACE}
```

---

## 2. Prompt Version Rollback (Registry Production-Pointer Flip)

The prompt registry (REG-5) stores prompt versions in the `prompt_versions` table with a `status` enum (`draft → candidate → production`). Only one version per prompt slug carries `status=production` at a time. Rolling back is a pointer flip — no redeployment required.

### 2.1 Identify current and target versions

```bash
# Port-forward to the gateway API (adjust port if different)
kubectl port-forward -n atlas-prod svc/gateway 8080:8080 &

# List all versions for a prompt slug
curl -sf http://localhost:8080/internal/registry/prompts/<slug>/versions | jq .

# Identify the version currently in production and the prior stable version
curl -sf http://localhost:8080/internal/registry/prompts/<slug>/versions \
  | jq '.[] | select(.status == "production") | {id, semver, promoted_at}'
```

### 2.2 Flip the production pointer

```bash
# Demote the current production version to candidate
curl -X POST http://localhost:8080/internal/registry/prompts/<slug>/versions/<current-version-id>/demote

# Promote the previous stable version to production
curl -X POST http://localhost:8080/internal/registry/prompts/<slug>/versions/<target-version-id>/promote
```

The gateway resolves `prompt_ref` at request time — the next request will use the newly promoted version with no restart needed.

### 2.3 Verify

```bash
# Confirm the pointer flipped
curl -sf http://localhost:8080/internal/registry/prompts/<slug>/versions \
  | jq '.[] | select(.status == "production") | {id, semver}'

# Emit a test request and check the prompt_template.id span attribute in Splunk
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "atlas.gpt4o.v1", "prompt_ref": "<slug>", "messages": [{"role":"user","content":"ping"}]}'
```

The `gen_ai.prompt_template.id` attribute on the resulting Splunk span must match the rolled-back version ID.

### 2.4 MLflow: mark the bad version

After rollback, tag the bad run in MLflow so the eval gate uses the correct baseline:

```bash
# In atlas-prompts CI or locally
python scripts/run_evals.py \
  --mlflow-uri ${MLFLOW_TRACKING_URI} \
  --run-id <bad-run-id> \
  --tag regression=true
```

---

## 3. Database Migration Rollback (Alembic Downgrade)

Atlas uses Alembic for all schema migrations in `atlas-gateway` (and other Python service repos). Each migration has an `upgrade()` and a `downgrade()` function.

### 3.1 Check current migration state

```bash
# Port-forward or exec into the gateway pod
kubectl exec -n atlas-prod deploy/gateway -- \
  alembic -c alembic.ini current
```

This outputs the current revision hash and whether it is the head.

### 3.2 View migration history

```bash
kubectl exec -n atlas-prod deploy/gateway -- \
  alembic -c alembic.ini history --verbose
```

### 3.3 Downgrade one revision

```bash
kubectl exec -n atlas-prod deploy/gateway -- \
  alembic -c alembic.ini downgrade -1
```

### 3.4 Downgrade to a specific revision

```bash
# Replace <target-revision> with the revision hash from the history output
kubectl exec -n atlas-prod deploy/gateway -- \
  alembic -c alembic.ini downgrade <target-revision>
```

### 3.5 Rollback to the base (empty schema — destructive)

Only use if you need to wipe all migrations:

```bash
kubectl exec -n atlas-prod deploy/gateway -- \
  alembic -c alembic.ini downgrade base
```

**This is destructive in prod. Coordinate with the team and take a database snapshot first.**

### 3.6 Take a PostgreSQL snapshot before any downgrade

```bash
# Via Azure CLI — create a point-in-time restore point
az postgres flexible-server backup create \
  --resource-group rg-atlas-data-prod \
  --name atlas-pg-prod \
  --backup-name "pre-rollback-$(date +%Y%m%d%H%M)"
```

### 3.7 Verify after downgrade

```bash
# Confirm revision
kubectl exec -n atlas-prod deploy/gateway -- \
  alembic -c alembic.ini current

# Run gateway health check
kubectl exec -n atlas-prod deploy/gateway -- \
  curl -sf http://localhost:8000/healthz
```

---

## 4. Rollback Decision Matrix

| Symptom | Rollback surface | Command |
|---|---|---|
| New image causing 5xx / SLO breach | Gateway (Argo Rollouts) | `kubectl argo rollouts undo <service> -n atlas-prod` |
| Prompt change causing eval regression or citation failures | Prompt registry | Production-pointer flip via internal API |
| Schema migration causing startup crash | Alembic | `alembic downgrade -1` in the gateway pod |
| Multiple surfaces broken simultaneously | Gateway first, then prompt | Argo Rollouts undo → verify → then prompt pointer flip if needed |
