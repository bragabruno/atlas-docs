# Cost Control Runbook

> **Scope:** Atlas dev environment (`ENV=dev`, `atlas-dev` namespace).
> Prod cost control is handled via Cluster Autoscaler + HPA + PDB — manual scale-to-zero is a dev-only operation.

---

## 1. Cost Reference (westeurope, approximate)

| Resource | Dev SKU | Hourly cost | Monthly at full scale |
|---|---|---|---|
| AKS system node (`Standard_B2s`) | 1 node | ~$0.04 | ~$29 |
| AKS workload node (`Standard_B4ms`) | 1 node | ~$0.17 | ~$124 |
| PostgreSQL Flexible Server (`B_Standard_B1ms`) | Always-on | ~$0.02 | ~$15 |
| Redis (Basic C0) | Always-on | ~$0.017 | ~$12 |
| ACR (Premium) | Always-on | ~$0.667/day | ~$20 |
| Key Vault | Per-operation | negligible | < $1 |
| Blob Storage (LRS) | Per-GB | negligible | < $1 |

| Scenario | Estimated monthly cost |
|---|---|
| Full scale, 24/7 | ~$200 |
| Nightly scale-to-zero (12 h/day, 5 d/week) | ~$95 |
| Weekend destroy (5 d/week, 12 h/day only) | ~$70 |

Numbers are approximate. Verify against the Azure Pricing Calculator for your region and any negotiated rates.

---

## 2. Decision: Scale-to-Zero vs Destroy

| Scenario | Recommended action | Bring-up time |
|---|---|---|
| Overnight (weekdays, cluster needed tomorrow) | Scale-to-zero CronJob (automatic) | ~3 min (nodes provision) |
| Weekend / multi-day idle | `make destroy ENV=dev` | ~10–15 min (full recreate) |
| Cost alert fires | `make destroy ENV=dev` | ~10–15 min (full recreate) |
| Switching Azure subscriptions or regions | `make destroy ENV=dev` | ~10–15 min (full recreate) |

---

## 3. Scale-to-Zero CronJob (Automatic, Weeknights)

The CronJob at `atlas-infra/platform/cost-controls/scale-to-zero-cronjob.yaml` runs on a fixed schedule. No manual action is needed for overnight idle periods.

### 3.1 Schedule

| Action | UTC schedule | CEST (UTC+2) equivalent |
|---|---|---|
| Scale down — all Deployments + StatefulSets to 0 replicas | `0 18 * * 1-5` (Mon–Fri) | 20:00 |
| Scale up — all Deployments + StatefulSets to 1 replica | `0 6 * * 1-5` (Mon–Fri) | 08:00 |

The AKS workload node pool has `min_count=0`. Once all pods are at 0 replicas, the Cluster Autoscaler drains and deallocates the workload VMs — no idle node cost overnight.

### 3.2 Deploy the CronJob

```bash
kubectl apply \
  -f atlas-infra/platform/cost-controls/scale-to-zero-cronjob.yaml \
  -n atlas-dev
```

### 3.3 Verify CronJob status

```bash
kubectl get cronjobs -n atlas-dev
# Expected: atlas-scale-down and atlas-scale-up both show LAST SCHEDULE and ACTIVE

kubectl get jobs -n atlas-dev | grep atlas-scale
# After a scheduled run: job completes with 1/1 success
```

### 3.4 Trigger a manual scale-down (out of schedule)

```bash
kubectl create job --from=cronjob/atlas-scale-down manual-scale-down -n atlas-dev
kubectl wait --for=condition=complete job/manual-scale-down -n atlas-dev --timeout=5m
kubectl logs job/manual-scale-down -n atlas-dev
```

### 3.5 Trigger a manual scale-up

```bash
kubectl create job --from=cronjob/atlas-scale-up manual-scale-up -n atlas-dev
kubectl wait --for=condition=complete job/manual-scale-up -n atlas-dev --timeout=5m
```

### 3.6 Exclude a workload from scale-down

Add the label `atlas/cost-control=exclude` to any Deployment or StatefulSet that must remain running:

```bash
kubectl label deployment <name> atlas/cost-control=exclude -n atlas-dev
```

The scale-down CronJob skips resources with this label.

---

## 4. Manual Scale-Down with `make`

Use the Makefile targets in `atlas-infra/` for ad-hoc teardown without destroying Azure resources.

### 4.1 Tear down only Atlas services (keep platform + Azure running)

```bash
# From atlas-infra/
make cloud-down ENV=dev
# Runs: skaffold delete --profile=dev --namespace=atlas-dev
```

### 4.2 Tear down services + platform charts (keep Azure infra running)

```bash
make full-down ENV=dev
# Runs: cloud-down + platform-down
# Azure resources (AKS, PG, Redis, ACR, Key Vault) remain billable
```

### 4.3 Bring back up after a manual scale-down

```bash
make cloud-up ENV=dev
# Runs: skaffold run --profile=dev --namespace=atlas-dev
# No local build — uses latest ACR images
```

---

## 5. Destroy-When-Idle with `make destroy`

For weekend or multi-day idle periods. Full procedure is in [teardown.md](teardown.md).

```bash
# Prerequisites: az login, TF_BACKEND_RG and TF_BACKEND_SA set
export TF_BACKEND_RG=rg-atlas-tfstate
export TF_BACKEND_SA=<storage-account-name>   # from bootstrap output

# Destroys: services + platform charts + ALL Azure resources for ENV=dev
make destroy ENV=dev \
  TF_BACKEND_RG=$TF_BACKEND_RG \
  TF_BACKEND_SA=$TF_BACKEND_SA

# Estimated time: 10–15 min (Terraform destroy dominates)
```

`make destroy` = `cloud-down` + `platform-down` + `tf-destroy`. Terraform state is preserved in the Azure Storage state backend; `make full-up` recreates from scratch.

---

## 6. Gateway Budget Enforcement (Runtime Cost Control)

The gateway enforces per-tenant spending limits at runtime:

- **Hard cap:** requests exceeding the monthly token budget return HTTP 429 (`rate_limit_exceeded`).
- **Alert threshold:** at 80% of the monthly budget, an alert is emitted via OTel metric `atlas.budget.threshold_warning`.
- **Agent session caps:** each agent session has a max token budget and max-iterations cap; breach raises an explicit error, never silent termination.

Check current budget state in Splunk:

```
index=atlas sourcetype=otel gen_ai.usage.total_tokens=*
| stats sum(gen_ai.usage.total_tokens) as total_tokens by tenant_id
```

---

## 7. Monitoring for Cost Anomalies

**Splunk Cost dashboard** — key panels:

| Panel | What it shows |
|---|---|
| Token spend per model / day | Catch model misrouting (cheap alias accidentally using expensive model) |
| Cumulative monthly forecast | Compare against budget ceiling |
| Cost per route | Identify high-cost routes for caching or rate-limiting |

**Azure Cost Management:**

```bash
# Current month spend for the dev resource groups
az consumption usage list \
  --scope /subscriptions/<subscription-id>/resourceGroups/rg-atlas-aks-dev \
  --query "[].{name:instanceName, cost:pretaxCost}" \
  --output table
```
