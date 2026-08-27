# Changelog

## 2026-08-26

### Fixed

- Made `load_tests/scripts/invoke_load_test.ps1` resolve the gateway and load-testing resource in the selected azd subscription, use subscription-scoped data-plane REST calls with Azure's required merge-patch media type for run creation, and stop after three consecutive polling failures with the underlying error; documented the behavior in `load_tests/readme.md`.

## 2026-08-25

### Changed

- Made `load_tests/scripts/invoke_load_test.ps1` verify Application Gateway readiness before every Azure Load Testing run and invoke the repository-owned azd postprovision lifecycle when startup is required; documented the preflight in `load_tests/readme.md`.

### Fixed

- Restored fail-closed Application Gateway runtime reconciliation in `azure.yaml` and added observed provisioning and operational states to failures from `scripts/validate-deployment.ps1`.

## 2026-08-22

### Changed

- Replaced the VNet-injected certificate deployment script with local development PFX generation and native Key Vault secret provisioning in `scripts/ensure-development-certificate.ps1`, `infrastructure/bicep/appgw-certificate.bicep`, and the top-level Bicep parameter wiring.

### Fixed

- Allowed authenticated trusted Azure services through the otherwise private-only Key Vault firewall in `infrastructure/bicep/supporting-infra.bicep`, enabling Application Gateway to retrieve its TLS secret while public network access remains disabled.
- Enforced Azure Load Testing's 2-50 character display-name limit before reconciliation and shortened the multi-subscription test label in `scripts/configure-load-test.ps1`.
- Made `scripts/validate-deployment.ps1` accept empty diagnostics for successful checks and replaced Windows-sensitive Azure CLI JMESPath expressions with PowerShell JSON parsing.
- Reconciled all five `dev1` Azure Load Testing definitions and validated the complete-development profile with all 25 deployment checks passing.

## 2026-08-21

### Added

- Added `_deploy.bat` as a root Windows wrapper that prompts for an environment name, selects it when it already exists or creates it when new, then runs `azd up -e` with fail-fast exit-code propagation.
- Added `scripts/purge-soft-deleted-resources.ps1` as a mandatory `azure.yaml` preprovision hook that purges environment-owned APIM, Cognitive Services, and Key Vault tombstones before deployment and fails if any remain.

### Changed

- Replaced the deprecating `gpt-4.1-nano` portfolio deployment with `gpt-5-nano` version `2025-08-07` using `GlobalStandard` in `infrastructure/model-portfolio.json` and aligned `README.md`.
- Changed `azure.yaml` deployment setup to prompt for every user-configurable value on every run, using persisted azd values only as defaults that users explicitly confirm or replace.
- Changed first-run certificate setup to default to a Bicep-generated self-signed certificate and persist that choice so subsequent `azd provision` runs do not prompt again.

### Fixed

- Preserved `legacyPortalStatus: 'Disabled'` in `infrastructure/bicep/apim-gateway.bicep` so repeated provisioning does not re-enable the deprecated APIM portal.
- Fixed intermittent `PreconditionFailed: Resource was modified since last retrieval` errors by serializing the APIM user and subscription resource loops with `@batchSize(1)` in `infrastructure/bicep/apim-subscriptions.bicep`.
- Fixed APIM subscription provisioning by creating one non-human APIM user per use-case subscription in `infrastructure/bicep/apim-subscriptions.bicep`, preventing multiple subscriptions to the same product from sharing an owner while preserving all eight catalog subscriptions.
- Fixed `azure.yaml` region compatibility checks and `scripts/test-deployment-preflight.ps1` to reject catalog entries in `Deprecating` or `Deprecated` lifecycle states before provisioning.
- Fixed certificate reconfiguration so switching from generated mode to a Key Vault certificate never offers the internal `__GENERATE__` sentinel as a secret-ID default.
- Fixed `azure.yaml` first-run setup to live-check stored and newly selected regions against every model, version, and SKU in `infrastructure/model-portfolio.json`, report incompatible requirements, and prompt for a replacement before deployment preflight.
- Fixed `_deploy.bat` to select an existing local azd environment instead of failing by attempting to recreate it.
- Fixed `azure.yaml` to derive the resource-group default after company-prefix selection and fixed `scripts/purge-soft-deleted-resources.ps1` to scope cleanup to the resource group declared by Bicep instead of a stale azd value.

## 2026-08-20

### Added

- Added `_loadtest.bat` as a root Windows entry point that forwards interactive and parameterized runs to `load_tests/scripts/run_load_test.ps1`.
- Added a four-LOB, eight-use-case APIM subscription catalog in `infrastructure/subscriptions/catalog.json`, including stable IDs, product tiers, and onboarding metadata.
- Added `infrastructure/model-portfolio.json` as the single source for model identity, regional capacity, capability, and APIM tier membership.
- Added `.github/skills/delivery-tracking/SKILL.md` as the unified primary-agent workflow for TODO state, validation evidence, changelog updates, and large-change auditing.
- Added `.github/agents/delivery-auditor.agent.md` as a read-only subagent that checks large diffs against delivery tracking and validation claims.

### Changed

- Renamed the Bicep-owned APIM product IDs to `bronze`, `silver`, and `gold` and aligned workbook formatting, policy inspection, and operator documentation.
- Removed obsolete Terraform and adoption guidance, standalone APIM policy samples, examples, the investment-platform LOB application, dead Bicep and script paths, and orphan assets while retaining the active Bicep/azd platform.
- Genericized all five APIM load tests around cataloged LOB subscriptions, with definition reconciliation owned by azd postprovision and Azure Load Testing runners limited to executing existing tests.
- Replaced four dedicated APIM test subscriptions with eight enabled LOB use-case subscriptions distributed across Bronze, Silver, and Gold in `infrastructure/subscriptions/catalog.json` and `infrastructure/bicep/apim-subscriptions.bicep`; retained the retired `test-*` IDs only as reconciliation tombstones.
- Updated `scripts/configure-load-test.ps1`, local JMeter runners, and the multi-subscription and steady-state JMX plans to use all eight real LOB subscription keys, while focused smoke and failover tests use representative catalog subscriptions.
- Updated deployment validation, README guidance, and the token-quota workbook mapping for the eight cataloged subscription display names and product caps.
- Changed Azure Load Testing reconciliation to require and verify `LOAD_TEST_SUBNET_ID` for all five tests, clear legacy key-bearing environment variables, inject APIM keys only through temporary USER_PROPERTIES artifacts, and avoid logging key prefixes.
- Removed local JMeter execution and consolidated the managed Azure run wrappers into `load_tests/scripts/run_load_test.ps1` with interactive and `-TestId` modes plus a shared `invoke_load_test.ps1` helper; retained all five JMX plans and documented workstation prerequisites, VNet injection, private DNS, and the managed-identity network path.
- Extended `scripts/validate-deployment.ps1` to require all five managed test IDs and verify that Azure reports the Bicep-declared private subnet for each definition.
- Changed `infrastructure/bicep/foundry-hub-project.bicep` and `infrastructure/bicep/main.bicep` to deploy a mirrored, serialized portfolio of at least five chat and embedding deployments instead of requiring fixed model families.
- Changed `infrastructure/bicep/apim-gateway.bicep` so Bronze and Silver model allowlists derive from portfolio tiers while Gold permits the entire deployed portfolio.
- Changed `scripts/test-deployment-preflight.ps1` and `scripts/validate-deployment.ps1` to validate portfolio shape, capability breadth, regional catalog availability, incremental quota, and every selected deployment in both regions.
- Updated `README.md`, `azure.yaml`, and `infrastructure/bicep/main.parameters.json` to describe and configure the portfolio-based lifecycle without the obsolete Phi deployment toggle.
- Strengthened `.github/copilot-instructions.md` to require `azd down` for teardown, restrict direct Azure CLI usage to read-only inventory, and prohibit direct deletion even after user confirmation.
- Simplified `scripts/` by removing obsolete ARM mutation utilities, one-time workbook rewrites, duplicate policy/subscription inspectors, and hard-coded traffic probes superseded by Bicep and the supported smoke/load-test tooling.
- Consolidated `scripts/check-subscriptions.ps1` into a key-safe read-only subscription view and removed the unsupported imperative PowerShell adoption guide.
- Simplified the platform to infrastructure-only provisioning by removing the ServiceNow workflows, APIM subscription Function App, Event Grid module and hooks, deployable azd service, automation flags, validation checks, and unused Function subnet.
- Removed undeployed Event Hub-dependent APIM reference policies and updated PCI, tracing, quota, onboarding, and architecture documentation to describe the actual inline APIM policies and Log Analytics/Application Insights telemetry.
- Removed Managed Grafana, its subscription-scoped Monitoring Reader assignment, azd configuration and validation, dashboard assets, and current documentation references while retaining Log Analytics, Application Insights, and Azure Monitor workbooks.
- Replaced the separate TODO and changelog enforcer instructions with one delivery workflow, mandatory audit thresholds for large change sets, and primary-agent ownership of tracker edits in `.github/copilot-instructions.md`.
- Removed obsolete Function App and Event Grid backlog items from `todo.md` after the delivery auditor identified that they referenced deleted components.
- Removed PCI-specific policy artifacts, compliance documentation, infrastructure labels, product claims, and cross-document guidance while retaining TLS, WAF Prevention, private networking, managed identity, body-free diagnostics, and operational audit logging.
- Changed Log Analytics retention from the PCI-driven 395-day period to a 90-day operational period in `infrastructure/bicep/supporting-infra.bicep` and aligned current documentation.
- Renamed the APIM diagnostic setting from `pci-dss-audit-diagnostics` to `apim-audit-diagnostics` in `infrastructure/bicep/apim-gateway.bicep`.

### Fixed

- Removed fixed Phi quota as a deployment prerequisite while preserving the stable `gpt-4o-mini` routing alias used by smoke and failover tooling.
- Closed the teardown-policy gap that allowed direct `az group delete` commands instead of the repository-owned azd lifecycle.
- Removed stale investment-platform ServiceNow documentation and a broken test that imported a nonexistent integration module.

## 2026-08-19

### Added

- Added `todo.md` with the analyzed deployment reliability, certificate bootstrap, identity, RBAC, Function App, Event Grid, validation, and documentation remediation backlog.
- Added a deferred post-refactor sequence to inventory and delete project environments and Azure resources before validating a clean `dev` deployment.
- Added `infrastructure/bicep/appgw-identity.bicep` to provision Application Gateway managed identities and deterministic Key Vault certificate-read assignments.
- Added `infrastructure/bicep/appgw-certificate.bicep` to create the default TLS certificate through a managed-identity Bicep deployment script.
- Added `scripts/validate-deployment.ps1` as a read-only complete-platform validator and final `azd up` success gate.
- Added `infrastructure/bicep/grafana-monitoring-rbac.bicep` for deterministic subscription-scoped Monitoring Reader ownership.
- Added `scripts/test-deployment-preflight.ps1` to validate azd configuration, Azure account context, provider registration, regional capabilities, incremental Foundry model quota, and ARM permissions/policy before provisioning.
- Added an accepted deployment data-plane boundary and compensating controls to `docs/adr/adr-005-identity-security-gaps.md`.
- Added explicit `production` and `complete-development` profile validation to `azure.yaml`, `scripts/test-deployment-preflight.ps1`, and `scripts/validate-deployment.ps1`.

### Changed

- Changed `infrastructure/bicep/main.bicep` and `infrastructure/bicep/waf-appgw.bicep` so the primary Application Gateway consumes a pre-provisioned identity and always receives a declared certificate.
- Changed `scripts/create-appgw-cert.ps1` into a read-only certificate and JMeter trust-artifact exporter.
- Changed `azure.yaml` to run a strict postdeploy Function discovery, Bicep reconciliation, and Event Grid subscription health check.
- Changed `infrastructure/bicep/event-grid-automation.bicep` to configure required Function runtime settings and target the deployed `apim-subscription-handler` function name.
- Changed mandatory `azure.yaml` postprovision and postdeploy hooks to propagate failures instead of reporting partial success.
- Changed `scripts/configure-load-test.ps1` to fail when load-test setup or the Application Gateway endpoint is unavailable.
- Changed `azure.yaml` and `infrastructure/bicep/main.parameters.json` to initialize and wire company prefix, Grafana administrator, Phi model, load-test, and Event Grid configuration.
- Changed `infrastructure/bicep/main.bicep` complete-platform defaults and added gateway verification outputs.
- Changed `azure.yaml` to reconcile subscription and tenant identifiers, register all resource providers used by the Bicep graph with completion waits, and require the preflight gate before provisioning.
- Changed Function Application Insights ingestion to use system-assigned managed identity with resource-scoped Monitoring Metrics Publisher RBAC in `infrastructure/bicep/event-grid-automation.bicep`.
- Corrected `README-pci.md` to describe managed-identity telemetry and remove the undeployed Key Vault private endpoint claim.
- Changed Managed Grafana naming in `infrastructure/bicep/main.bicep` to use the shared collision-resistant global suffix.
- Changed `scripts/configure-load-test.ps1` to skip cleanly for the production profile and remain mandatory for complete development deployments.
- Updated `README.md` with the supported `azd up` lifecycle, profile contract, complete CI values, and Bicep-managed blank-certificate behavior.

### Fixed

- Fixed Key Vault access wiring in `infrastructure/bicep/supporting-infra.bicep` to grant the deploying principal least-privilege certificate access.
- Removed recursive certificate reprovisioning, empty-value regex parsing, and nonzero-exit success handling from `azure.yaml`.
- Removed the obsolete `infrastructure/bicep/kv-cert-rbac.bicep` ownership path.
- Fixed top-level Event Grid subscription parameter wiring in `infrastructure/bicep/main.bicep` and `main.parameters.json`.
- Removed recursive provision success heuristics and added explicit zero-exit and health requirements.
- Removed the imperative Grafana Monitoring Reader role-assignment hook from `azure.yaml`.
- Fixed repeat-provision quota validation to exclude matching model capacity already owned by the current azd environment.

### Security

- Replaced imperative identity and RBAC mutations with deterministic Bicep role assignments and a dedicated Key Vault Certificates Officer managed identity.
- Removed Key Vault Administrator escalation from the local certificate helper.
- Removed the unused custom Event Grid topic access key from Function App settings.
- Disabled Function storage shared-key authentication, anonymous blob access, and cross-tenant replication in `infrastructure/bicep/event-grid-automation.bicep`.
- Disabled unused Managed Grafana API-key authentication in `infrastructure/bicep/managed-grafana.bicep`.
- Fixed `scripts/validate-deployment.ps1` to validate required deployment IDs independently on both Foundry accounts and include Phi only when selected.
