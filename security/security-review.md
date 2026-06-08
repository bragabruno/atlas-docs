# XCUT-1 — Security Review

**Date:** 2026-06-07
**Scope:** Atlas polyrepo (`atlas-gateway`, `atlas-agent-runtime`, `atlas-mcp-doc-search`, `atlas-mcp-citations`, `atlas-frontend`, `atlas-infra`, `atlas-prompts`)
**Reviewer:** Automated grep sweep + manual code review
**Status:** CLOSED with tracked follow-ups (see findings table)

---

## 1. Secrets Handling

### 1.1 Grep Sweep — No Hardcoded Secrets

**Command run:**

```bash
grep -rnIE "(api[_-]?key|secret|password|token)\s*[:=]\s*[\"'][^\"']" \
  atlas-gateway atlas-agent-runtime atlas-mcp-citations \
  atlas-mcp-doc-search atlas-frontend atlas-infra atlas-prompts \
  --include="*.py" --include="*.ts" --include="*.tf" \
  --include="*.yaml" --include="*.yml" \
  --exclude-dir=".venv" --exclude-dir="node_modules" --exclude-dir=".git" \
  --exclude="*.example"
```

**Raw output (all hits, verbatim):**

```
atlas-gateway/tests/test_provider_registry_keys.py:26:    providers = default_providers(Settings(api_keys=("dev-key",), anthropic_api_key="sk-ant-test"))
atlas-gateway/tests/test_provider_registry_keys.py:36:    providers = default_providers(Settings(api_keys=("dev-key",), openai_api_key="sk-test"))
atlas-gateway/tests/test_provider_registry_keys.py:42:    providers = default_providers(Settings(api_keys=("dev-key",), google_api_key="g-test"))
atlas-gateway/tests/test_provider_registry_keys.py:51:            anthropic_api_key="sk-ant-test",
atlas-gateway/tests/test_provider_registry_keys.py:52:            openai_api_key="sk-test",
atlas-gateway/tests/test_provider_registry_keys.py:53:            google_api_key="g-test",
atlas-gateway/tests/test_provider_registry_keys.py:62:        default_providers(Settings(api_keys=("dev-key",), openai_api_key="sk-test"))
atlas-gateway/tests/test_content_policy.py:72:    secret = "sk-super-secret-token-value"
atlas-infra/platform/otel-collector/values-dev.yaml:303:        token: "${env:SPLUNK_HEC_TOKEN}"
atlas-infra/platform/otel-collector/values-dev.yaml:321:        token: "${env:SPLUNK_HEC_TOKEN}"
atlas-prompts/evals/runner/gateway_client.py:9:    client = HttpGatewayClient(base_url="http://gateway:8000", api_key="...")
```

**Assessment: CLEAN.** No real credentials present. Each hit is one of:

| File | Value | Classification |
|---|---|---|
| `test_provider_registry_keys.py` | `"sk-ant-test"`, `"sk-test"`, `"g-test"`, `"dev-key"` | Syntactically fake test tokens — `sk-ant-test` is not a valid Anthropic key (real keys are `sk-ant-api03-…`). Used to assert registry wiring, not to make real API calls. |
| `test_content_policy.py` | `"sk-super-secret-token-value"` | Test fixture string used as *input* to the content-policy guardrail to assert the guardrail catches leaked-credential patterns and never echoes the matched text in the rejection reason. |
| `otel-collector/values-dev.yaml` | `"${env:SPLUNK_HEC_TOKEN}"` | OTel Collector env-var interpolation — the value is `${env:…}`, not the secret itself. The real token is injected at runtime via CSI mount. |
| `gateway_client.py` docstring | `api_key="..."` | Three-dot placeholder in a `Usage` docstring, not executable code. The class receives the key as a constructor argument at runtime. |

**Second sweep — broader patterns (AWS keys, connection strings, base64 blobs):**

```bash
grep -rnIE "(AKIA[0-9A-Z]{16}|password\s*=\s*['\"][^'\"]+['\"]|DATABASE_URL\s*=\s*['\"][^'\"]+['\"])" \
  atlas-* --include="*.py" --include="*.ts" --include="*.tf" \
  --include="*.yaml" --include="*.yml" \
  --exclude-dir=".venv" --exclude-dir="node_modules" --exclude-dir=".git" \
  --exclude="*.example"
```

Result: **no output** (clean).

**Dockerfile sweep — `ENV SECRET=` / `ENV *_KEY=` patterns:**

```bash
grep -rE "ENV\s+(SECRET|API_KEY|PASSWORD|TOKEN)\s*=" atlas-*/Dockerfile* 2>/dev/null
```

Result: **no output** (clean). Only Dockerfile present is `atlas-frontend/Dockerfile` (nginx SPA); no credential-shaped `ENV` lines.

**No `.env` files committed** — `find atlas-* -name ".env" | grep -v ".venv" | grep -v example` returned empty.

**No `terraform.tfvars` committed** — only `.tfvars.example` files present; example files use `<placeholder>` values and carry header comments warning never to commit real values.

### 1.2 Secret-Loading Architecture

The production secret pipeline is end-to-end Key Vault:

```
Key Vault (RBAC mode, private endpoint, public_network_access_enabled=false)
  └── Secrets Store CSI Driver
        └── SecretProviderClass (per-service Helm template)
              └── Pod volume mount at /mnt/secrets (readOnly: true)
                    └── Application reads from filesystem path
```

- `app/config.py` (`atlas-gateway`) uses `pydantic_settings.BaseSettings` with `env_prefix="ATLAS_"`. Provider keys default to `None` — no real key is baked in. In tests the `Settings(openai_api_key="sk-test")` override injects the fake key without touching env.
- `SecretProviderClass` templates in every service chart inject `keyVaultName`, `tenantId`, and `userAssignedIdentityID` at deploy time from Terraform outputs / CI; none are hardcoded in the chart defaults.
- CI authenticates to Azure via Bitbucket OIDC → `BITBUCKET_STEP_OIDC_TOKEN`; no `ARM_CLIENT_SECRET` in pipeline variables.

**Gap:** No `.pre-commit-config.yaml` or `detect-secrets`/`trufflehog` config file was found in any repo. The architectural intent documented in `04 §3.3` (pre-commit + CI secret scan) is not yet backed by a committed hook config. → **Finding SEC-001.**

---

## 2. Network Policies and Private Endpoints

### 2.1 Azure NSGs (Terraform)

`atlas-infra/infra/terraform/modules/network/main.tf` provisions three NSGs with least-privilege rules:

| NSG | Allow inbound | Explicit deny |
|---|---|---|
| `nsg-system` | AzureLoadBalancer, workload→system | Internet→system (priority 4000) |
| `nsg-workload` | HTTPS:443 from Internet, AzureLoadBalancer, system→workload | Internet→workload non-443 (priority 4000) |
| `nsg-data` | workload→5432 (PG), workload→6380 (Redis TLS) | Internet→data (4000), system→data (4001) |

All NSGs are associated with their respective subnets via `azurerm_subnet_network_security_group_association`.

### 2.2 Private Endpoints

| Resource | Subnet | Private DNS zone |
|---|---|---|
| Key Vault | `subnet-data` | `privatelink.vaultcore.azure.net` |
| PostgreSQL Flexible Server | `subnet-data` | `privatelink.postgres.database.azure.com` |
| Redis Cache | `subnet-data` | (provisioned via data module) |
| Azure Blob Storage | `subnet-storage` | `privatelink.blob.core.windows.net` |
| ACR | `subnet-workload` | `privatelink.azurecr.io` (Premium SKU required) |

`public_network_access_enabled = false` is set on Key Vault in `modules/secrets/main.tf`. ACR `public_network_access_enabled` is parameterised and defaults to `false` at Premium SKU.

### 2.3 Kubernetes NetworkPolicy

The architecture documentation (`05 §6.3`) specifies Kubernetes `NetworkPolicy` resources enforcing default-deny with namespace-level allow-lists. **However, no `NetworkPolicy` manifests were found in any Helm chart** across the codebase (`grep -rl "kind: NetworkPolicy"` returned no results).

NSG rules at the subnet level provide partial isolation between node pools and the data tier, but pod-to-pod lateral movement within the workload namespace is not blocked by a Kubernetes network policy. → **Finding SEC-002 (gap).**

### 2.4 Storage Subnets

`atlas-infra/infra/terraform/envs/dev/terraform.tfvars.example` defines the doc's CIDR plan. Storage and Key Vault private endpoint subnets (`subnet-storage`, `subnet-keyvault`) referenced in the architecture diagram are not yet provisioned as separate subnet resources in `modules/network/main.tf` — the module provisions `system`, `workload`, and `data` subnets only. Private endpoints for storage and ACR share the `data` or `workload` subnets instead. → **Finding SEC-003 (minor gap).**

---

## 3. Least-Privilege Managed Identities

### 3.1 Identity Module

`atlas-infra/infra/terraform/modules/identity/main.tf` creates one `azurerm_user_assigned_identity` per service, one `azurerm_federated_identity_credential` binding the K8s `ServiceAccount` to the identity via the AKS OIDC issuer, and one `azurerm_role_assignment` per declared scope/role.

Role assignments from `terraform.tfvars.example`:

| Service | Key Vault role | Additional role |
|---|---|---|
| `gateway` | `Key Vault Secrets User` | `Storage Blob Data Reader` |
| `agent-runtime` | `Key Vault Secrets User` | `Storage Blob Data Contributor` |
| `mcp-doc-search` | `Key Vault Secrets User` | — |
| `mcp-citations` | `Key Vault Secrets User` | — |
| `mlflow` | `Key Vault Secrets User` | `Storage Blob Data Contributor` |
| `otel-collector` | `Key Vault Secrets User` | — |

`Key Vault Secrets User` is read-only (`Get` + `List` on secrets). No service holds `Key Vault Administrator` at runtime; that role is scoped to the bootstrap CI service principal only and is documented as `bootstrap only`.

`atlas-frontend` (nginx SPA) has no managed identity and no Key Vault access — correct, it has no server-side secrets.

### 3.2 Federated Credential Scoping

Each `azurerm_federated_identity_credential` is scoped to `system:serviceaccount:<namespace>:<service-name>` with audience `api://AzureADTokenExchange`. No credential uses a wildcard subject.

**Assessment: least-privilege posture is correctly modelled in Terraform.** The `gateway` has `Storage Blob Data Reader` where `agent-runtime` has `Storage Blob Data Contributor`; this is correct given the agent-runtime writes trace artefacts while the gateway only reads.

**Gap:** The `gateway` service holds `Storage Blob Data Reader` (trace read). This was not documented in `04 §3.2` — the table there shows `—` for the gateway's additional roles. It is present in `terraform.tfvars.example`. Verify whether this access is intentional. → **Finding SEC-004 (minor, verify).**

---

## 4. Image Scanning

### 4.1 ACR Quarantine and Scan-on-Push

`atlas-infra/infra/terraform/modules/storage/main.tf` sets:

```hcl
quarantine_policy_enabled = var.acr_sku == "Premium" ? var.acr_quarantine_policy_enabled : false
```

`var.acr_quarantine_policy_enabled` defaults to `true` and `var.acr_sku` defaults to `"Premium"`. This means quarantine is enabled at Premium SKU, preventing unscanned images from being pulled.

`trust_policy_enabled` defaults to `false` (content trust / Notary v1 not enabled by default).

`admin_enabled` is a variable with a validation comment noting it `must remain false for Atlas` — authentication is via managed identity.

Scan-on-push (Microsoft Defender for Containers) is available at all ACR tiers but requires Defender for Containers to be enabled at the subscription level. This is referenced in the variable description but **not provisioned by Terraform** — it depends on a subscription-level Defender plan. → **Finding SEC-005 (gap).**

### 4.2 Base Image Pins

The only Dockerfile present (`atlas-frontend/Dockerfile`) pins:
- `node:22.16.0-alpine3.22` — image tag is a specific version (not `latest`). Comment notes push date ≥14 days.
- `nginx:1.27.5-alpine3.21` — specific version pinned.

No Python service Dockerfiles were found in the codebase; the Python services do not yet have committed Dockerfiles. → **Finding SEC-006 (gap).**

### 4.3 Non-Root Containers

`atlas-gateway/deploy/values.yaml` sets:

```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 10001
  fsGroup: 10001
  seccompProfile:
    type: RuntimeDefault
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
```

This is the most restrictive baseline (non-root, no privilege escalation, read-only rootfs, all caps dropped, RuntimeDefault seccomp). The same pattern should exist in all service charts. A spot-check of `atlas-agent-runtime/deploy/values.yaml` shows the same `podSpec` helper pattern delegating security context to values.

**Gap:** `atlas-frontend/Dockerfile` uses the default nginx image which runs as `root` internally. The Helm chart for the frontend should set `runAsNonRoot: false` or use a non-root nginx image (`nginxinc/nginx-unprivileged`). The Dockerfile documents the intent (port 8080, not 80) but the process still starts as root inside the container. → **Finding SEC-007 (low).**

---

## 5. Findings Table

| ID | Area | Severity | Title | Status | Follow-up |
|---|---|---|---|---|---|
| **SEC-001** | Secrets — CI scan | **Medium** | No committed `detect-secrets` / `trufflehog` pre-commit config or CI pipeline step; the scan is documented in `04 §3.3` and the threat model but not backed by a config file in any repo | **Gap** | Add `.pre-commit-config.yaml` to each Python repo with `detect-secrets` hook; add `trufflehog` CI step to `bitbucket-pipelines.yml` template in `atlas-infra` |
| **SEC-002** | Network — K8s NetworkPolicy | **Medium** | No Kubernetes `NetworkPolicy` manifests exist. Architecture doc (`05 §6.3`) states default-deny + namespace-level allow-lists, but nothing enforces pod-to-pod isolation within the workload namespace | **Gap** | Add `NetworkPolicy` templates to each service Helm chart (default-deny + explicit allow per architecture doc); add to `atlas-infra/platform/` for platform services |
| **SEC-003** | Network — subnet layout | **Low** | `modules/network/main.tf` provisions only 3 subnets (`system`, `workload`, `data`). Architecture diagram shows 5 (`subnet-storage`, `subnet-keyvault` also listed). Storage and ACR private endpoints land in `data`/`workload` subnets instead of dedicated subnets | **Minor gap** | Optionally add `subnet-storage` and `subnet-keyvault` resources to the network module to match the documented CIDR plan; NSG rules would need updating accordingly |
| **SEC-004** | Identity — gateway role | **Info** | `gateway` identity holds `Storage Blob Data Reader` in `terraform.tfvars.example` but the role table in `04 §3.2` shows `—` for gateway additional roles | **Verify** | Confirm whether blob read access is required by the gateway (e.g., for trace artefacts). If not needed, remove from `terraform.tfvars.example`. Update `04 §3.2` to match actual config |
| **SEC-005** | Image scanning — Defender | **Medium** | Microsoft Defender for Containers (scan-on-push integration) is not provisioned by Terraform. The quarantine policy blocks unscanned images, but without Defender enabled the scan never runs and quarantine effectively becomes an empty gate | **Gap** | Enable `azurerm_security_center_subscription_pricing` resource for `ContainerRegistry` tier in `modules/storage/` or a top-level `security.tf`; alternatively document the out-of-band activation requirement |
| **SEC-006** | Image scanning — missing Dockerfiles | **Medium** | Python service repos (`atlas-gateway`, `atlas-agent-runtime`, `atlas-mcp-doc-search`, `atlas-mcp-citations`) have no committed `Dockerfile`. CI (`bitbucket-pipelines.yml`) references `docker build .` but there is nothing to build | **Gap** | Add hardened Dockerfiles to each Python service repo (non-root user, pinned base image ≥14 days old, no `ENV SECRET=` lines, multi-stage build) |
| **SEC-007** | Image scanning — nginx root | **Low** | `atlas-frontend/Dockerfile` uses `nginx:1.27.5-alpine3.21` which runs the master process as root. Port is 8080 (non-privileged), but root startup is still a hardening gap | **Follow-up** | Switch to `nginxinc/nginx-unprivileged:1.27.5-alpine` or add `USER nginx` after config copy; verify Helm `securityContext.runAsNonRoot: true` does not cause startup failures |
| **SEC-008** | Secrets — no .gitignore in repos | **Low** | No `.gitignore` files were found in any repo. The `terraform.tfvars` files are described as gitignored, but without a committed `.gitignore` there is no enforcement | **Gap** | Add `.gitignore` to each repo; at minimum `atlas-infra` needs `**/terraform.tfvars` and `**/.terraform/` excluded; Python repos need `.env`, `.venv/`, `__pycache__/` |

---

## 6. Summary — DoD Assessment

| DoD Criterion | Status |
|---|---|
| No secrets in code / images / tests | **PASS** — grep sweep clean; test values are clearly fake; no Dockerfiles with `ENV SECRET=`; no `.env` committed |
| Network policies in place (Azure NSGs) | **PASS** — NSGs at subnet level are correctly configured with least-privilege rules |
| Kubernetes NetworkPolicy in place | **FAIL** — manifests are absent (SEC-002) |
| Image scan clean | **PARTIAL** — ACR quarantine policy enabled in TF, but Defender for Containers not provisioned (SEC-005); Python Dockerfiles missing entirely (SEC-006) |
| Findings tracked | **PASS** — 8 findings in table above; all gaps are tracked, none are blocking secrets-in-code issues |

**Verdict:** No secrets found in code, images, or tests. The Azure infrastructure (NSGs, private endpoints, Key Vault + CSI + Workload Identity, least-privilege managed identities) is well-implemented. Two medium-severity gaps require follow-up before production: Kubernetes `NetworkPolicy` manifests (SEC-002) and Microsoft Defender for Containers activation (SEC-005). The missing secret-scan pre-commit config (SEC-001) and missing Python Dockerfiles (SEC-006) should also be closed before the first real deployment.

---

*Report generated for XCUT-1. Linked from [atlas-docs/README.md](../README.md#security).*
