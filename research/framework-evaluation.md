# Atlas — Framework Evaluation & Selection

> **Status:** Ratified 2026-06-07 — the open decisions (§7) were accepted at their recommended defaults and codified as **ADR-016…020** in [`../02-tech-stack-and-adrs.md`](../02-tech-stack-and-adrs.md). This document remains the evidence base behind those ADRs.
> **Date:** 2026-06-07
> **Scope:** All 8 Atlas repos.

---

## 1. Purpose, scope & methodology

The user asked, across all 8 Atlas repos, **where a framework is appropriate and which one is most suitable**. This document answers that with an evidence-based evaluation rather than preference.

**Evidence sources:**

1. **Repo state** — manifests + READMEs of all 8 repos (only `atlas-gateway` has pinned code today; the rest are scaffolds that *declare intent* but pin nothing, several leaving choices explicitly open).
2. **Existing ADRs** — the 15 ratified records in [`02`](../02-tech-stack-and-adrs.md), which already draw the build-vs-adopt line implicitly (ADR-001 no-LiteLLM, ADR-006 no-LangGraph).
3. **The target stack** — Enhesa's **live job postings** (Greenhouse, June 2026), used as primary-source corroboration of what Atlas mirrors (§2).
4. **Current framework landscape** — 11 web searches (June 2026) across Python web frameworks, the MCP/agent ecosystem, LLM eval frameworks, Angular testing + state, Kubernetes dev-loops, and Terraform testing/policy. Every external claim below carries an inline source; all URLs are collected in §8.

**Governing question for each decision:** not "what is best in the abstract" but "what is most suitable *for Atlas* — given the Enhesa mirror mission, the I/O-bound workload, the polyrepo structure, and the portfolio thesis."

---

## 2. What Enhesa uses today (the target we mirror)

Atlas exists to mirror the stack of Enhesa's AI Platform / AI engineering team. The table below is drawn from Enhesa's **currently-live job postings** (Greenhouse, fetched 2026-06-07) — primary-source confirmation, not second-hand intel. The live board carries **AI Staff Software Engineer (Lisbon)**, **Senior AI Engineer (Lisbon)**, **Senior Cloud Engineer (Lisbon)**, and **Analytics Engineer (Lisbon)** — confirming the Lisbon AI hub.

### Enhesa stack, as named in live postings

| Layer | Named in postings | Atlas decision | Match |
|---|---|---|---|
| **Primary language** | Python (primary) | Python 3.12 + asyncio (ADR-002) | ✅ exact |
| **Compiled/systems language** | C#/.NET, C++, Go, **or** Rust (required secondary) | Python-only | ⚠️ divergence — see below |
| **Scala stack** | Scala + **Play Framework** (Senior AI Engineer) | out of scope (Atlas = Python AI-platform side) | ➖ intentional |
| **Cloud** | Azure (preferred); AWS/GCP secondary | Azure (ADR-003) | ✅ exact |
| **Orchestration** | Azure Kubernetes Service (AKS) | AKS (ADR-003) | ✅ exact |
| **IaC** | Terraform **or** Bicep | Terraform/azurerm | ✅ (within set) |
| **Relational DB** | SQL / PostgreSQL | Azure PostgreSQL Flexible Server (ADR-010) | ✅ exact |
| **Search** | Elasticsearch | Elasticsearch hybrid (ADR-005) | ✅ exact |
| **Vector DB** | Qdrant (Pinecone as alt) | Qdrant (ADR-004) | ✅ exact |
| **Event bus** | Kafka | Kafka (ADR-007) | ✅ exact |
| **Experiment tracking** | MLflow | MLflow (ADR-008) | ✅ exact |
| **LLM providers** | OpenAI, Anthropic, Google | all three via Provider Protocol (ADR-012) | ✅ exact |
| **Observability** | Splunk | OTel → Splunk (ADR-009) | ✅ exact |
| **CI/CD** | Bitbucket Pipelines, GitHub Actions, **Azure DevOps** | Bitbucket Pipelines (ADR-013) | ✅ (within set) |
| **Containers/registry** | Docker; (AKS implies a registry) | Docker + ACR | ✅ |
| **AI-assisted dev** | GitHub Copilot, **Claude Code**, Cursor | (dev-time culture) | ✅ aligned |

Sources: Enhesa [AI Staff Software Engineer (Lisbon)](https://job-boards.greenhouse.io/enhesa/jobs/4186034009), [Senior AI Engineer (Lisbon)](https://job-boards.greenhouse.io/enhesa/jobs/4078742009), [Senior Cloud Engineer (Lisbon)](https://job-boards.greenhouse.io/enhesa/jobs/4087540009), [Enhesa Careers](https://www.enhesa.com/careers/).

### What the live postings *add* to prior intel

- **A compiled language is a stated requirement** (C#/.NET, C++, Go, or Rust) alongside Python. Atlas is Python-only by ADR-002. This is the one genuine divergence.
- **Bicep** is accepted alongside Terraform; **Azure DevOps** and **GitHub Actions** alongside Bitbucket. Atlas's choices sit inside Enhesa's named set, so they transfer.
- **Scala + Play Framework** is real on the broader team. Atlas deliberately models the *Python AI-platform* surface, not the Scala data services — worth naming explicitly so the scope boundary is intentional, not an omission.
- **AI-assisted development (Copilot, Claude Code, Cursor) is part of the culture** — building Atlas *with* Claude Code is itself on-stack.

### The one divergence to own: Python-only vs "Python + a compiled language"

ADR-002 rejected Go/Rust for the gateway (knowledge-transfer + I/O-bound workload). The live JD shows Enhesa wants Python **and** a systems language. Recommendation: **keep Python-only for Phase 1**, but make the latency note in [§3 of `02`](../02-tech-stack-and-adrs.md) explicit in interviews — "the gateway is I/O-bound so Python is correct here; for a CPU-bound path I'd extract a Go/Rust component behind the OpenAI-compatible facade." That answer *demonstrates* the compiled-language judgment without contradicting the mirror. Optionally, a future spike could add one small Rust/Go component (e.g. a token-counting or hashing sidecar) purely to evidence the skill — tracked as a stretch ticket, not Phase 1.

---

## 3. The governing principle: the build-vs-adopt frontier

`★ Insight ─────────────────────────────────────`
Atlas already draws this line — ADR-001 (build the gateway primitives) and ADR-006 (build the agent loop) are the *build* side; everything else is *adopt*. The rule underneath both:
**Build what you must own the failure modes of, and what demonstrates the competency Enhesa screens for. Adopt the undifferentiated commodity.**
`─────────────────────────────────────────────────`

| Build (own it) | Adopt (commodity) |
|---|---|
| Provider routing, alias resolution, failover | HTTP serving (**FastAPI**) |
| Redis circuit breaker, token-bucket limiter | DB driver/ORM (**asyncpg / SQLAlchemy / Alembic**) |
| Cost accounting over the 4 token fields | MCP protocol (**official `mcp` SDK**) |
| Guardrail chain + citation enforcement | Retry/backoff (**tenacity**) |
| The eval **gate** + promotion state machine | Eval **metrics** (candidate: DeepEval) |
| The thin agent loop + hard caps (ADR-006) | IaC (**Terraform**), UI (**Angular**), tracking (**MLflow**) |

**Smell test for "should we hand-roll this?":** does writing it *show* platform-engineering judgment (routing, breaking, accounting, the gate), or is it plumbing every shop solves the same way (request parsing, DI wiring, test runners, ORM sessions)? Plumbing → adopt the boring, proven thing.

---

## 4. Per-repo framework map

| Repo | Component type | Framework appropriate for… | Recommended | Status |
|---|---|---|---|---|
| **atlas-gateway** | Async HTTP API (the platform) | HTTP serving + data access | **FastAPI** + asyncpg/SQLAlchemy 2.0/Alembic + redis-py + tenacity; **build** the primitives | Locked (FastAPI pinned) |
| **atlas-agent-runtime** | Agent execution service | the loop is *built*; everything around it adopted | Hand-rolled loop (ADR-006) + **FastAPI** trigger surface *(gap)* + `mcp` client + SQLAlchemy + OTel + PyYAML | Loop locked; **trigger API open** |
| **atlas-mcp-doc-search** | MCP server (hybrid retrieval) | the MCP protocol | Official **`mcp` SDK / FastMCP** + Streamable HTTP + ES/Qdrant clients | Evidence-settled |
| **atlas-mcp-citations** | MCP server (citation lookup) | the MCP protocol | Official **`mcp` SDK / FastMCP** | Evidence-settled |
| **atlas-prompts** | Prompts + eval-gate ("money demo") | eval metrics + templating + tracking | Jinja2 + MLflow + generated gateway client; **metrics = open** | **Open** (custom vs DeepEval vs promptfoo) |
| **atlas-frontend** | Angular SPA | UI + state + testing | **Angular** + **Vitest** + Angular CDK/Material; **state = open** | Angular locked; state **open**, test settled (Vitest) |
| **atlas-infra** | Terraform IaC + dev-loop | IaC + K8s tooling + testing | **Terraform/azurerm** + Helm + **dev-loop open** + `terraform test` + Checkov | TF locked; **dev-loop open** |
| **atlas-docs** | Docs + diagrams | none needed | Markdown + Mermaid + PlantUML; *optional* MkDocs Material later | No framework (correct) |

---

## 5. Decision deep-dives

### 5.1 Python HTTP framework — FastAPI vs Litestar vs Django REST

| | FastAPI | Litestar | Django REST |
|---|---|---|---|
| Paradigm | Async-first ASGI | Async-first ASGI | Sync-first (async partial) |
| Serialization | Pydantic v2 | msgspec (faster) | DRF serializers (overhead) |
| Best for | Microservices, API gateways, I/O-heavy AI backends | Performance + strong DI | CRUD/admin/relational apps |
| Ecosystem / hiring | Largest; "powers APIs at OpenAI/Anthropic/Microsoft" | Smaller — "higher ecosystem and hiring risk" | Large, mature |
| Atlas fit | **Exact** — async LLM proxy, OpenAPI contract (ADR-014), Enhesa-named | Tempting but off-mirror | Wrong shape (no admin/CRUD need) |

**2026 evidence:** FastAPI is "the default greenfield choice in 2026 because it is async-first, works naturally with Pydantic v2, has strong OpenAPI support, and fits modern AI and LLM backend workloads" ([domainindia](https://domainindia.com/support/kb/django-fastapi-flask-comparison-2026)). Litestar is "the most technically compelling challenger… but carries higher ecosystem and hiring risk" ([same](https://domainindia.com/support/kb/django-fastapi-flask-comparison-2026)); DRF is "the strongest choice for enterprise CRUD systems, admin-heavy products." Under realistic DB-paginated workloads "the gap between the four narrows to within network and database variance."

**Recommendation: FastAPI across every Python HTTP service** (gateway + agent-runtime trigger surface). The "organization" concern that prompted the Litestar question is solved by internal layering (§5.2), not by changing frameworks. Switching would cost consistency + the Enhesa match for a benchmark edge that disappears under real DB load. → *No new ADR needed; the stack table already pins FastAPI. §5.2 formalizes the internal structure.*

### 5.2 Internal service organization ("Spring-style" layering)

The gateway today is flat (`api/v1/chat.py` mixes HTTP + business logic + provider calls). The README's module map is **capability-sliced** (`providers/`, `cache/`, `limits/`…) by request flow, not by layer. "Spring organization" = impose a **layered spine** over those capability modules.

| Option | Shape | Verdict |
|---|---|---|
| Flat (today) | everything in the router | doesn't scale past a few endpoints |
| Pure n-tier | one big `services/` + `repositories/` | god-packages mixing unrelated concerns |
| **Layered spine + capability adapters** | `api → services → repositories → domain`, capability modules as adapters/`@Component`s, FastAPI `Depends` as the DI container | **recommended** — Spring's separation without Spring's magic |
| Hexagonal/ports-adapters | ports in `domain`, adapters around | good but heavier ceremony than needed now |

**Recommended structure (gateway, generalizes to all Python services):**

```
app/
├── api/         # controllers: HTTP only (parse, auth, serialize) + deps.py (DI providers)
├── services/    # use-cases / orchestration — the ONLY place business logic lives
├── repositories/# DB access (asyncpg/SQLAlchemy) behind interfaces
├── domain/      # entities, DTOs, protocols (the contracts) — no framework deps
├── providers/, cache/, limits/, … # capability adapters the services compose
└── main.py      # composition root (DI wiring)  · config.py  # settings
```

This gives controller→service→repository separation + testability, keeps FastAPI's async grain, and makes the wave-1 "module-first, wire-later" plan clean (cache/guardrails land as modules; a thin commit wires them into `services/`). → **Proposed ADR-016.**

### 5.3 Agent runtime — hand-rolled vs frameworks

| Framework | Sweet spot | Atlas fit |
|---|---|---|
| **Hand-rolled (ADR-006)** | full control of caps/failure modes; inspectable | the portfolio thesis — *demonstrates* the competency |
| **Pydantic AI** | type-safe agents, OTel-instrumented, lightweight | **closest "adopt" option** — already on pydantic v2 + OTel |
| LangGraph | complex stateful graphs (Klarna, Uber, LinkedIn, JPMorgan) | overkill for one bounded RAG agent; hides failure paths |
| CrewAI | multi-agent role collaboration, fast prototyping | wrong shape (single agent) |
| OpenAI Agents SDK | simple OpenAI-only tool loops | single-vendor; Atlas is multi-provider |
| Claude Agent SDK | production agents w/ hooks, MCP, skills | Anthropic-native; off the multi-vendor mirror |

**2026 evidence:** the official Python `mcp` SDK now *includes* FastMCP as its server interface; LangGraph is "the default for complex stateful workflows," CrewAI "fastest to prototype," **Pydantic AI** "brings Pydantic's type safety… with the framework handling validation plus OpenTelemetry instrumentation" ([speakeasy](https://www.speakeasy.com/blog/ai-agent-framework-comparison), [dev.to](https://dev.to/linou518/the-2026-ai-agent-framework-decision-guide-langgraph-vs-crewai-vs-pydantic-ai-b2h)).

**Recommendation: keep the hand-rolled loop** — it's the Enhesa parallel and the strongest "I built it" story, and ADR-006's cost (~2 sprint-weeks) is already accepted. **But name Pydantic AI as the sanctioned fallback** if timeline compresses: it's type-safe + OTel-native (so it wouldn't hide failure modes the way LangGraph does) and composes with the existing stack. → *Confirms ADR-006; add a one-line "fallback: Pydantic AI" note.*

**Gap flagged:** `atlas-agent-runtime`'s README module map has **no trigger surface** — nothing receives a run request. It needs either a thin **FastAPI** endpoint (`POST /v1/agent/runs`) or a **Kafka consumer** (off a new `atlas.agent.requests.v1` topic). Not captured in any ticket. → §7.

### 5.4 MCP servers — official SDK / FastMCP

**2026 evidence:** the official `mcp` SDK (1.27.x) ships **FastMCP** as its core server interface; FastMCP 3.0 (Feb 2026) "powers ~70% of MCP servers across all languages" at "4M daily downloads," and **Streamable HTTP** "is the current standard for remote MCP… works behind load balancers and proxies" ([python-sdk](https://github.com/modelcontextprotocol/python-sdk), [gofastmcp](https://gofastmcp.com/getting-started/welcome)).

**Recommendation: official `mcp` SDK / FastMCP + Streamable HTTP transport** for both `atlas-mcp-doc-search` and `atlas-mcp-citations` (matches ADR's "no vendored fork"). No web framework needed — the SDK *is* the server. The only built logic is the RRF fusion (small). → *No new ADR; confirms the stack-table choice.*

### 5.5 Eval stack — custom vs DeepEval vs promptfoo vs Ragas

| Tool | Role | Idiom |
|---|---|---|
| **DeepEval** | CI-gate metrics: 50+ incl. faithfulness/citation, multi-turn/agents | Python (pytest-like) |
| **promptfoo** | YAML test matrix across 30+ providers + red-team | YAML/CLI |
| **Ragas** | RAG-specific retrieval metrics | Python |
| Custom runner (README today) | full control, mirrors "build primitives" | Python |

**2026 evidence:** "Promptfoo runs at PR time as a CI gate"; "DeepEval… fits teams whose AI stack has matured into production-grade systems involving agents and multi-turn conversations with established CI/CD pipelines"; Ragas is "RAG-only." A common setup is "one tool in CI plus one tool for continuous monitoring." Cost: "~$200–$600/month in judge LLM tokens" at 10k RAG traces/day on GPT-4o ([genai.qa](https://genai.qa/blog/promptfoo-vs-deepeval-vs-ragas/), [Confident AI](https://www.confident-ai.com/knowledge-base/compare/best-llm-evaluation-tools)).

**Recommendation (default): DeepEval for the *metrics* + a thin custom `gate.py`/promotion.** Adopt commodity metric implementations (semantic match, citation validity, LLM-as-judge) instead of reinventing them; keep the Atlas-specific gate (baseline comparison, server-side promotion enforcement, REG-13) hand-built. Integrates with locked MLflow (ADR-008). The judge-token cost is the thing to watch for the nightly drift eval (POL-3). → *Proposed ADR-017. **User decision — §7.***

### 5.6 Frontend — state + testing

**Testing (evidence-settled): Vitest.** "With Angular 21, Vitest officially replaces Karma as the default testing framework"; "Karma is now deprecated and does not accept new features or general bug fixes" ([angular.dev](https://angular.dev/guide/testing/migrating-to-vitest), [angulararchitects](https://www.angulararchitects.io/blog/migrate-from-karma-to-vitest/)). → Update the frontend README's "Karma/Jest" to **Vitest**.

**State management (open):**

| Option | When | Atlas fit |
|---|---|---|
| **Pure Signals / service-store** | "primitive values or small, isolated states" | right-sized for chat + citations + cost |
| **NgRx SignalStore** | "shared state across multiple modules… strong debugging tools… structure most larger teams want" | a recognizable enterprise pattern to signal for Enhesa |
| Classic NgRx Store | "complex, shared application-wide state" | overkill at this app size |

"For very simple things, use pure signals… if you want structure and are cooperating with other developers, use signal state" ([Multitude/Medium](https://medium.com/multitude-it-labs/ngrx-signal-store-vs-signal-state-vs-simple-signal-33ceb2f5ee1d), [Nx](https://nx.dev/blog/angular-state-management-2025)).

**Recommendation (default): Signals service-store**, with NgRx SignalStore as the step-up if you want a more enterprise-looking artifact. → *Proposed ADR-018 (state + Vitest). **User decision — §7.***

### 5.7 Infra — dev-loop + Terraform testing

**Dev-loop (open):**

| | Skaffold | Tilt |
|---|---|---|
| Interface | CLI | browser UI + service dashboard |
| Update model | rebuild/redeploy | live file-sync / hot reload |
| Config | YAML | Starlark (Python-like) |
| Community | larger, more mature | smaller |
| Best for | "veteran K8s engineers," Helm/Kustomize/kubectl, GCP | "complex microservice architectures," visual feedback, faster setup |

Both support Helm ([wallarm](https://www.wallarm.com/cloud-native-products-101/skaffold-vs-tilt-local-kubernetes-development), [vcluster](https://www.vcluster.com/blog/skaffold-vs-tilt-vs-devspace)).

**Recommendation (default): Skaffold** — Helm-native and declarative, parallel to the Argo Rollouts/Helm CD path (the umbrella loop builds→ACR→Helm→AKS). Tilt is the better *DX* (live reload + dashboard for 8 services) and is a defensible pick if inner-loop speed matters more than CD parity. → *Proposed ADR-019. **User decision — §7.***

**Terraform testing/policy (recommended, no decision needed):**

- **`terraform test`** (native, 1.6+, HCL, no deploy) for module-logic validation — no Go barrier.
- **Checkov** for security/compliance (CIS/GDPR/PCI; also scans Helm/K8s — Python-native, matches the team language).
- **tflint** as the linter (provider mistakes/deprecated syntax — "not a security scanner").
- **Trivy** (`trivy config`) not tfsec — "Trivy is the successor to tfsec… no reason to start a new pipeline on tfsec in 2026."
- **Terratest** (Go) only for the top-1–2 critical modules if real-deploy assertions are needed — flagged optional due to the Go language barrier.
Sources: [env0](https://www.env0.com/blog/terratest-vs-terraform-opentofu-test-in-depth-comparison), [Spacelift scanning tools](https://spacelift.io/blog/terraform-scanning-tools). → folds into **ADR-019**.

---

## 6. Recommendations summary

| # | Decision | Recommendation | Status | Codified by |
|---|---|---|---|---|
| 1 | Python HTTP framework (all services) | **FastAPI** | Locked | stack table (existing) |
| 2 | Internal service organization | **Layered spine + capability adapters + `Depends` DI** | Proposed | **ADR-016** |
| 3 | Agent runtime | **Hand-rolled** (fallback: Pydantic AI) | Confirms ADR-006 | ADR-006 note |
| 4 | Agent-runtime trigger surface | FastAPI endpoint **or** Kafka consumer | **Open** | ADR-016 / new ticket |
| 5 | MCP servers | **`mcp` SDK / FastMCP + Streamable HTTP** | Evidence-settled | stack table |
| 6 | Eval stack | **DeepEval metrics + custom gate** | **Open** | **ADR-017** |
| 7 | Frontend test runner | **Vitest** (Karma EOL) | Evidence-settled | **ADR-018** |
| 8 | Frontend state | **Signals service-store** (or NgRx SignalStore) | **Open** | **ADR-018** |
| 9 | Infra dev-loop | **Skaffold** (or Tilt) | **Open** | **ADR-019** |
| 10 | Terraform testing/policy | **`terraform test` + Checkov + tflint + Trivy** | Recommended | ADR-019 |
| 11 | Python-only vs compiled language | Python-only Phase 1; articulate the compiled-language judgment | Note | §2 / interview talking point |

---

## 7. Open decisions to ratify

These are the genuine judgment calls; the rest are locked or evidence-settled. Each has a recommended default.

1. **Eval stack** (§5.5) — *default:* DeepEval metrics + custom gate. Alternatives: fully custom, or promptfoo.
2. **Frontend state** (§5.6) — *default:* Signals service-store. Alternative: NgRx SignalStore for a more "enterprise" artifact.
3. **Infra dev-loop** (§5.7) — *default:* Skaffold. Alternative: Tilt for richer inner-loop DX.
4. **Agent-runtime trigger surface** (§5.3) — *default:* thin FastAPI endpoint. Alternative: Kafka consumer. Needs a new ticket either way.
5. **Revisit ADR-006?** — *default:* no (keep hand-rolled); record Pydantic AI as the sanctioned fallback.

On ratification, the follow-up work is: write **ADR-016…019** into [`02`](../02-tech-stack-and-adrs.md); update the frontend README (Karma→Vitest), the agent-runtime README (trigger surface), and `TICKETS.md`; add the trigger-surface ticket in Linear.

---

## 8. References

**Enhesa (primary-source, June 2026):**
[AI Staff Software Engineer — Lisbon](https://job-boards.greenhouse.io/enhesa/jobs/4186034009) · [Senior AI Engineer — Lisbon](https://job-boards.greenhouse.io/enhesa/jobs/4078742009) · [Senior Cloud Engineer — Lisbon](https://job-boards.greenhouse.io/enhesa/jobs/4087540009) · [Analytics Engineer — Lisbon](https://job-boards.greenhouse.io/enhesa/jobs/4264806009) · [Enhesa Careers](https://www.enhesa.com/careers/)

**Python web frameworks:**
[FastAPI — Alternatives](https://fastapi.tiangolo.com/alternatives/) · [Django vs FastAPI vs Flask 2026](https://domainindia.com/support/kb/django-fastapi-flask-comparison-2026) · [DRF vs FastAPI 2026 — Planeks](https://www.planeks.net/fastapi-vs-django-rest-framework/) · [FastAPI vs Django 2026 — Lasting Dynamics](https://www.lastingdynamics.com/blog/fastapi-vs-django/)

**MCP & agent frameworks:**
[Official Python MCP SDK](https://github.com/modelcontextprotocol/python-sdk) · [FastMCP](https://gofastmcp.com/getting-started/welcome) · [Agent framework comparison — Speakeasy](https://www.speakeasy.com/blog/ai-agent-framework-comparison) · [LangGraph vs CrewAI vs Pydantic AI 2026 — dev.to](https://dev.to/linou518/the-2026-ai-agent-framework-decision-guide-langgraph-vs-crewai-vs-pydantic-ai-b2h) · [Agent framework comparison — Langfuse](https://langfuse.com/blog/2025-03-19-ai-agent-comparison)

**LLM eval frameworks:**
[promptfoo vs DeepEval vs RAGAS 2026 — genai.qa](https://genai.qa/blog/promptfoo-vs-deepeval-vs-ragas/) · [Top LLM eval tools 2026 — Confident AI](https://www.confident-ai.com/knowledge-base/compare/best-llm-evaluation-tools) · [LLM testing tools 2026 — contextQA](https://contextqa.com/blog/llm-testing-tools-frameworks-2026/)

**Angular testing & state:**
[Migrating from Karma to Vitest — angular.dev](https://angular.dev/guide/testing/migrating-to-vitest) · [Migrate from Karma to Vitest — AngularArchitects](https://www.angulararchitects.io/blog/migrate-from-karma-to-vitest/) · [Vitest in Angular 21](https://javascript-conference.com/blog/angular-21-vitest-testing/) · [Angular State Management 2025 — Nx](https://nx.dev/blog/angular-state-management-2025) · [NgRx SignalStore vs signalState vs Signal — Multitude](https://medium.com/multitude-it-labs/ngrx-signal-store-vs-signal-state-vs-simple-signal-33ceb2f5ee1d) · [NgRx Signals Guide](https://ngrx.io/guide/signals)

**Kubernetes dev-loop:**
[Skaffold vs Tilt — Wallarm](https://www.wallarm.com/cloud-native-products-101/skaffold-vs-tilt-local-kubernetes-development) · [Skaffold vs Tilt vs DevSpace — vCluster](https://www.vcluster.com/blog/skaffold-vs-tilt-vs-devspace) · [From Skaffold to Tilt — Tilt docs](https://docs.tilt.dev/skaffold.html)

**Terraform testing & policy:**
[Terratest vs Terraform Test — env0](https://www.env0.com/blog/terratest-vs-terraform-opentofu-test-in-depth-comparison) · [How to test Terraform — Spacelift](https://spacelift.io/blog/terraform-test) · [Terraform scanning tools 2026 — Spacelift](https://spacelift.io/blog/terraform-scanning-tools)
