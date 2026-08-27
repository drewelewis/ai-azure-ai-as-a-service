# TODO

## In Progress

- [ ] Enable multi-subscription filtering across the Platform Health TPM and RPM panels and redeploy the workbook to `dev1` (local parameter contract, JSON, diagnostics, and Bicep compilation validated; deployment pending).
- [ ] Remove confirmed azd environments other than `dev1`, including verified Azure teardown for `dev2` and reconstructed `dev4` plus stale local-state cleanup.
- [ ] Replace the E2E Trace subscription traffic chart with clustered, unstacked columns and redeploy the workbook to `dev1` (local JSON contract and Bicep compilation validated; run `steady-state-20260825163249` is complete, so deployment can proceed).

## Backlog

### Reliable End-to-End Deployment

- [ ] Make repeated deployment of the same azd environment convergent and idempotent; reserve environment deletion and recreation for explicit teardown or unrecoverable cases.

### Declarative Ownership and Security

- [ ] Design and implement optional Entra JWT validation at the APIM ingress using Bicep-owned `validate-jwt` policies, including issuer/audience validation, application and user claim extraction, authorization rules, privacy-safe telemetry, and a migration path that preserves subscription-key quota attribution. This is deferred; subscription keys remain the current client authentication mechanism.

### Configuration and Defaults

### Validation and Regression Coverage

- [ ] Add automated tests for generated-certificate sentinel and populated Key Vault certificate ID handling.
- [ ] Add Bicep build and lint validation for the top-level template and every module in CI.
- [ ] Add tests that verify enabled feature flags produce the corresponding resources and that mandatory modules cannot be skipped silently.
- [ ] Add an end-to-end deployment smoke test proving HTTPS traffic flows through Application Gateway to internal APIM and Foundry.
- [ ] Make deployment-critical Bicep, YAML, and PowerShell files ASCII-safe or explicitly enforce UTF-8 so Windows Azure CLI compilation does not fail with `UnicodeEncodeError`.

### Repository Guidance and Documentation

- [ ] Rewrite `.github/copilot-instructions.md` to require convergence on the existing environment, prohibit restart-from-scratch as routine troubleshooting, and define the complete-platform success criteria.
- [ ] Update `.github/copilot-instructions.md` so the declared Bicep ownership policy matches any narrowly scoped data-plane bootstrap exceptions.
- [ ] Correct `README.md`, deployment playbooks, Bicep comments, and script help so blank certificate behavior and `azd provision`, `azd deploy`, and `azd up` semantics are consistent.
- [ ] Document the exact deployment phase sequence, expected duration, validation gates, retry behavior, and recovery procedure without requiring environment recreation.
- [ ] Document which components are mandatory, which are optional by profile, and which permissions the deploying principal or CI identity requires.

### Post-Refactor Clean Deployment

- [ ] Create a fresh `dev` environment, run one clean `azd up`, and verify the complete-platform success criteria without manual repair steps or additional deployment passes outside the orchestrated command.

## Done

### 2026-08-26

- [x] Made Azure Load Testing launch and polling subscription-stable and fail with actionable diagnostics when repeated data-plane reads fail.

### 2026-08-25

- [x] Restored idempotent postprovision Application Gateway startup, added observed-state validation diagnostics, and verified all 25 `dev1` deployment checks.
- [x] Added a load-test readiness gate that starts and validates Application Gateway through the azd postprovision lifecycle before creating a run.

### 2026-08-22

- [x] Completed and validated the `dev1` deployment after replacing the certificate deployment script, correcting Application Gateway trusted-service access, enforcing Azure Load Testing display-name limits, and repairing the final validator for Windows Azure CLI output.

### 2026-08-21

- [x] Preserved the disabled APIM legacy portal state across repeated deployments and verified the unintended enable transition is absent from the `dev1` preview.
- [x] Serialized APIM user and subscription provisioning to prevent concurrent control-plane writes from failing with ETag precondition errors.
- [x] Assigned the eight cataloged APIM subscriptions to declarative non-human owners so no user owns multiple subscriptions to the same product.
- [x] Replaced deprecating `gpt-4.1-nano` with GA `gpt-5-nano` and rejected non-deployable model lifecycle states during setup and preflight.
- [x] Prompted for every deployment configuration choice on each `_deploy.bat` run, using stored values only as explicit defaults.
- [x] Validated stored and newly selected setup regions against the exact Foundry model portfolio before saving them.
- [x] Made `_deploy.bat` select existing azd environments and create only new environment names before deployment.
- [x] Fixed first-run resource-group derivation and soft-delete cleanup scope when a non-default company prefix is selected.
- [x] Added `_deploy.bat` as a root wrapper that prompts for an environment name, then creates and deploys that azd environment.
- [x] Added a mandatory azd preprovision cleanup hook that purges all environment-owned soft-deleted APIM, Cognitive Services, and Key Vault resources and blocks deployment if any remain.
- [x] Defaulted first-run certificate setup to a persisted Bicep-generated development certificate choice so repeated azd deployments no longer prompt.

### 2026-08-20

- [x] Added `_loadtest.bat` as a root entry point for interactive and parameterized Azure Load Testing runs.
- [x] Made all five Azure Load Testing definitions fail closed on `snet-loadtest`, added deployed subnet validation, documented local launch of Azure-hosted runs and the private test path, and consolidated local launch into `load_tests/scripts/run_load_test.ps1` while retaining the JMX plans.
- [x] Replaced four dedicated APIM test subscriptions with eight catalog-driven LOB use-case subscriptions across Bronze, Silver, and Gold; updated reconciliation, load tests, validation, workbooks, and documentation with local executable validation.
- [x] Documented an illustrative four-LOB APIM subscription catalog with two independently managed use-case subscriptions per LOB in `README.md`.
- [x] Renamed the Bicep-owned APIM product IDs and active consumers from `ai-bronze`, `ai-silver`, and `ai-gold` to `bronze`, `silver`, and `gold`.
- [x] Simplified the repository to the Bicep/azd-owned Azure AI platform by removing obsolete Terraform/adoption, standalone policies, examples, the LOB application, dead Bicep/script paths, and orphan assets while preserving and genericizing all five APIM load tests.
- [x] Removed PCI-specific policies, infrastructure labels, documentation, and compliance claims while retaining general platform security and observability controls.
- [x] Unified TODO and changelog tracking into one delivery workflow, added a read-only auditor agent for large change sets, and removed stale automation backlog items identified by the audit.
- [x] Removed Managed Grafana and its dedicated RBAC, configuration, validation, dashboard assets, and documentation while retaining Azure Monitor telemetry and workbooks.
- [x] Replaced fixed Foundry model requirements with a configurable, quota-aware portfolio that deploys a validated breadth of chat and embedding models in both regions and derives APIM tier access from the same manifest.
- [x] Strengthened `.github/copilot-instructions.md` so Azure teardown must use `azd down`, direct Azure mutations are forbidden, and missing local azd state blocks deletion rather than permitting a bypass.
- [x] Removed obsolete imperative Azure mutation scripts, one-time rewrite helpers, duplicate diagnostics, and hard-coded traffic probes superseded by the supported azd/Bicep and smoke/load-test paths.
- [x] Inventoried all local and matching Azure environments, reviewed the exact deletion scope, and confirmed `dev` and `dev1` as project-owned azd environments.
- [x] Deleted the confirmed `dev` Azure environment through `azd down`, verified its resource group was removed, and removed its local azd state with `azd env remove`.
- [x] Reconstructed the confirmed `dev1` environment, deleted it through `azd down`, verified its resource group was removed, and removed its local azd state.
- [x] Removed ServiceNow workflows, the APIM subscription Function App, Event Grid automation, undeployed Event Hub policy references, and their obsolete infrastructure, validation, and documentation surfaces.

### 2026-08-19

- [x] Moved the Application Gateway managed identities and deterministic Key Vault Certificate User assignments into `infrastructure/bicep/appgw-identity.bicep`.
- [x] Wired `AZURE_DEPLOYING_USER_OBJECT_ID` to least-privilege Key Vault Certificate User access in `infrastructure/bicep/supporting-infra.bicep`.
- [x] Added Bicep-managed default TLS certificate creation through `infrastructure/bicep/appgw-certificate.bicep` with a dedicated Key Vault Certificates Officer identity.
- [x] Removed the certificate-empty gateway skip, recursive `azd provision`, regex certificate-state parsing, and nonzero-exit success heuristic from `infrastructure/bicep/main.bicep` and `azure.yaml`.
- [x] Limited `scripts/create-appgw-cert.ps1` to read-only export of the declared Key Vault certificate and local JMeter trust artifact generation.
- [x] Removed the obsolete `infrastructure/bicep/kv-cert-rbac.bicep` module and consolidated certificate RBAC ownership.
- [x] Wired Event Grid subscription desired state through `infrastructure/bicep/main.bicep`, `main.parameters.json`, and `event-grid-automation.bicep`.
- [x] Added a strict `azure.yaml` postdeploy stage that discovers the deployed function, reconciles infrastructure through `azd provision`, and verifies Event Grid subscription health.
- [x] Added required Function runtime settings and corrected the Event Grid destination to `functions/apim-subscription-handler`.
- [x] Removed the unused custom Event Grid topic and its static endpoint and key settings.
- [x] Added `scripts/validate-deployment.ps1` as the final complete-platform `azd up` gate for resources, models, endpoints, identities, RBAC, Function code, Event Grid, Grafana, jumpbox, and load testing.
- [x] Made mandatory postprovision and postdeploy hooks fail on errors, including load-test configuration and Application Gateway startup.
- [x] Removed recursive provision success heuristics and require zero exit codes plus explicit resource health validation.
- [x] Moved Grafana Monitoring Reader to deterministic subscription-scoped Bicep ownership in `infrastructure/bicep/grafana-monitoring-rbac.bicep` and removed the mutating hook.
- [x] Inventoried deployment-hook mutations and retained only non-resource lifecycle operations for provider registration, azd desired state, and Application Gateway operational startup.
- [x] Standardized Bicep role assignment ownership on stable principal-role-scope GUIDs.
- [x] Aligned complete-platform defaults and wired company prefix, Grafana administrator, Phi model, load-test, and Event Grid inputs across `azure.yaml`, `main.bicep`, and `main.parameters.json`.
- [x] Added secure Application Gateway certificate, identity, resource ID, and FQDN outputs for deployment validation.
- [x] Added `scripts/test-deployment-preflight.ps1` and an `azure.yaml` preprovision gate for azd values, account context, provider registration, regional resource availability, exact Foundry model quota, and ARM RBAC/policy validation.
- [x] Explicitly disabled Function storage shared-key, anonymous blob, and cross-tenant replication access and made OAuth the default authentication mode.
- [x] Configured Function Application Insights ingestion for system-assigned managed identity and granted deterministic, resource-scoped Monitoring Metrics Publisher access.
- [x] Documented the Entra-only public routing boundary required by local/hosted azd package upload and the managed certificate deployment script in `docs/adr/adr-005-identity-security-gaps.md`.
- [x] Verified every global and region-global namespace uses the tenant/subscription/environment/company suffix and corrected Managed Grafana naming.
- [x] Disabled unused Managed Grafana API-key authentication.
- [x] Added explicit `production` and `complete-development` deployment profiles, with profile-aware preflight, load-test setup, and final validation.
- [x] Corrected final deployment validation to require each selected Foundry deployment on both accounts instead of mixing deployment IDs with model family names.
