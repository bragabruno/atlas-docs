# Teardown Runbook

> **Scope:** Complete destruction of an Atlas environment via `make destroy`.
> Use for multi-day idle periods, subscription changes, or when a cost alert fires.
> For overnight scale-down, use the scale-to-zero CronJob (see [cost-control.md](cost-control.md) §3).

---

## 1. When to Destroy vs Scale-to-Zero

| Scenario | Action |
|---|---|
| Overnight idle (weekday, cluster needed tomorrow) | Scale-to-zero CronJob (automatic) |
| Weekend / multi-day idle | `make destroy ENV=dev` |
| Cost alert fires above monthly dev ceiling | `make destroy ENV=dev` |
| Switching Azure subscriptions or regions | `make destroy ENV=dev` |

---

## 2. Pre-Destroy Checklist

Run through all items before proceeding:

- [ ] No active CI pipelines targeting the cluster (check Bitbucket Pipelines for in-progress runs).
- [ ] No long-running eval jobs in flight: `kubectl get jobs -n atlas-dev`
- [ ] MLflow experiment runs are complete and results synced to the remote tracking URI (PostgreSQL is destroyed with the cluster; in-cluster state is lost).
- [ ] Any Key Vault secrets added out-of-band (not managed by Terraform) are documented — secrets are soft-deleted (90-day retention) and recoverable, but note which ones may need recovery.
- [ ] Team members are aware the dev cluster is going down.
- [ ] Terraform state backend variables (`TF_BACKEND_RG`, `TF_BACKEND_SA`) are available and correct.

---

## 3. Destroy Procedure

### 3.1 Authenticate to Azure

```bash
az login
# In CI / OIDC environments: env vars AZURE_CLIENT_ID / AZURE_TENANT_ID /
# AZURE_FEDERATED_TOKEN_FILE are used instead; no az login needed.
```

### 3.2 Set Terraform backend variables

```bash
export TF_BACKEND_RG=rg-atlas-tfstate
export TF_BACKEND_SA=<storage-account-name>   # from bootstrap output
# TF_BACKEND_CONT defaults to "tfstate" — override only if you changed it
```

### 3.3 Verify the correct kubectl context

```bash
kubectl config use-context atlas-dev
kubectl config current-context   # must print: atlas-dev
```

### 3.4 One-command destroy

```bash
# From atlas-infra/
make destroy ENV=dev \
  TF_BACKEND_RG=$TF_BACKEND_RG \
  TF_BACKEND_SA=$TF_BACKEND_SA
```

`make destroy` runs these steps in sequence:

1. `make context-check` — aborts if kubectl context does not match `atlas-dev`.
2. `make cloud-down` — `skaffold delete --profile=dev --namespace=atlas-dev` (removes Atlas service Helm releases).
3. `make platform-down` — `helm uninstall` for all platform charts (Qdrant, Kafka, Elasticsearch, OTel Collector, MLflow).
4. `make tf-destroy` — `terraform destroy -var-file=infra/terraform/envs/dev/terraform.tfvars` (destroys all Azure resources: AKS, ACR, PostgreSQL, Redis, Key Vault, VNet, Managed Identities, Blob Storage).

**Expected output:**

```
All service releases removed from atlas-dev.
All platform charts removed from atlas-dev.
WARNING: This will destroy ALL dev Azure resources.
State is preserved; re-run 'make tf-apply ENV=dev' to recreate.
Press Ctrl-C to abort.  Proceeding in 5 seconds...
<terraform destroy output — ~10–15 min>
All dev resources destroyed.
Atlas dev fully destroyed (Terraform state preserved).
```

### 3.5 Destroy only Azure resources (skip Helm cleanup — cluster already gone)

If the cluster is already unreachable (e.g., a previous partial destroy):

```bash
make tf-destroy ENV=dev \
  TF_BACKEND_RG=$TF_BACKEND_RG \
  TF_BACKEND_SA=$TF_BACKEND_SA
```

---

## 4. Post-Destroy Verification

```bash
# Confirm resource groups are empty (or deleted)
az resource list --resource-group rg-atlas-aks-dev --output table
az resource list --resource-group rg-atlas-data-dev --output table
az resource list --resource-group rg-atlas-secrets-dev --output table

# Confirm Terraform state shows no managed resources
terraform -chdir=infra/terraform/envs/dev show
# Expected: "No state." or empty output
```

The Terraform state backend storage account (`rg-atlas-tfstate`) is intentionally **not** destroyed — it holds the state file needed for the next `full-up`.

---

## 5. Key Vault Soft-Delete Recovery

Key Vault uses soft-delete with a 90-day retention window. When the Key Vault is destroyed and recreated (same name), existing soft-deleted secrets must be recovered before the new vault can create secrets with the same names.

### 5.1 List soft-deleted secrets

```bash
az keyvault secret list-deleted \
  --vault-name kv-atlas-dev \
  --output table
```

### 5.2 Recover individual secrets

```bash
# Recover by name — restores to the new vault instance
az keyvault secret recover \
  --vault-name kv-atlas-dev \
  --name atlas-pg-password

az keyvault secret recover \
  --vault-name kv-atlas-dev \
  --name atlas-openai-api-key

az keyvault secret recover \
  --vault-name kv-atlas-dev \
  --name atlas-anthropic-api-key

# Repeat for each soft-deleted secret shown in the list
```

### 5.3 Key Vault name change (different suffix)

If the new Key Vault has a different name (e.g., unique suffix changed), soft-deleted secrets cannot be recovered into the new vault. Create them from scratch from your secure credential store:

```bash
az keyvault secret set \
  --vault-name <new-kv-name> \
  --name atlas-pg-password \
  --value "$(cat /path/to/secure/pg-password)"
```

**Never store secret values in files committed to git.** Use a password manager or another Azure Key Vault as the source.

### 5.4 Purge a soft-deleted Key Vault (if recreating with same name fails)

If Terraform cannot create a Key Vault because a soft-deleted vault with the same name exists:

```bash
# Purge the soft-deleted vault (irreversible — secrets are permanently deleted)
az keyvault purge --name kv-atlas-dev --location westeurope
```

Only purge if you have verified all secrets are backed up elsewhere or are about to be recreated.

---

## 6. Recreate Procedure (`make full-up`)

```bash
# 1. Authenticate
az login

# 2. Ensure terraform.tfvars is present and correct
#    (gitignored; copy from terraform.tfvars.example and fill in values)
ls infra/terraform/envs/dev/terraform.tfvars

# 3. One-command bring-up (from atlas-infra/)
make full-up ENV=dev \
  TF_BACKEND_RG=$TF_BACKEND_RG \
  TF_BACKEND_SA=$TF_BACKEND_SA

# full-up = tf-apply + platform-up + cloud-up
# Estimated time: 10–15 min (AKS cluster creation dominates)
```

`make full-up` runs these steps in sequence:

1. `make tf-apply` — `terraform apply` provisions all Azure resources (network → AKS → identity → secrets / data / storage).
2. `make context-check` — verifies kubectl context after AKS credentials are written.
3. `make platform-up` — deploys Qdrant, Kafka, Elasticsearch, OTel Collector, MLflow via Helm.
4. `make cloud-up` — `skaffold run --profile=dev --namespace=atlas-dev` deploys all Atlas service images from ACR.

### 6.1 Post-recreate smoke tests

```bash
# Nodes ready
kubectl get nodes

# All pods running
kubectl get pods -n atlas-dev

# ACR FQDN (confirm ACR was reprovisioned)
terraform -chdir=infra/terraform/envs/dev output acr_login_server

# Gateway health
kubectl port-forward -n atlas-dev svc/gateway 8080:8080 &
curl -sf http://localhost:8080/healthz

# Platform: Qdrant
kubectl exec -n atlas-dev deploy/mcp-doc-search -- \
  curl -sf http://atlas-qdrant:6333/readyz

# Platform: Elasticsearch
kubectl exec -n atlas-dev deploy/mcp-doc-search -- \
  curl -sf http://atlas-elasticsearch:9200/_cluster/health | jq .status
```

### 6.2 Key Vault secrets after recreate

After `full-up`, if secrets were not recovered (see §5), seed them before the pods can start:

```bash
# Check which CSI mounts are failing (pods in Init state)
kubectl describe pod <pod-name> -n atlas-dev | grep -A 10 Events

# Seed the missing secrets, then restart the affected pods
kubectl rollout restart deployment/gateway -n atlas-dev
kubectl rollout restart deployment/agent-runtime -n atlas-dev
```

---

## 7. Terraform State Reference

The Terraform state is stored in:

```
Storage account : <TF_BACKEND_SA>
Resource group  : rg-atlas-tfstate
Container       : tfstate
Blob key        : envs/dev/terraform.tfstate
```

The state backend storage account is provisioned once (bootstrap) and is **never** destroyed by `make destroy`. It survives all environment cycles.
