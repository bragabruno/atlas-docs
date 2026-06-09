# atlas-docs — build system (single source of truth).
# Developers and CI run the same targets. Logic lives in scripts/, not here and
# not in the pipeline YAML. atlas-docs is a Markdown + diagrams repo, so the only
# active gates are lint (markdownlint) and test (diagram validation); the rest are
# N/A and skip cleanly. See scripts/README.md.
.DEFAULT_GOAL := help
SHELL := bash

.PHONY: help lint test coverage build docker infra security ci local

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-9s\033[0m %s\n",$$1,$$2}'

lint: ## Trunk → markdownlint (+ git-diff-check)
	@./scripts/lint.sh

test: ## Diagram validation (XCUT-6: Mermaid + PlantUML)
	@./scripts/test.sh

coverage: ## N/A — docs repo (skips)
	@./scripts/coverage.sh

build: ## N/A — docs repo, nothing to compile (skips)
	@./scripts/build.sh

docker: ## N/A — docs repo, no Dockerfile (skips)
	@./scripts/docker.sh

infra: ## N/A — docs repo, no deploy chart (skips)
	@./scripts/infra.sh

security: ## Secret scan (gitleaks via Trunk; advisory, ATLAS_SECURITY_STRICT=1)
	@./scripts/security.sh

ci: ## Run the full gate — what CI runs
	@./scripts/ci.sh

local: ## N/A — docs repo, no server (skips)
	@./scripts/local.sh
