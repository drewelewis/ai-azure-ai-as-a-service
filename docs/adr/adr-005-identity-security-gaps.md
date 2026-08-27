# ADR-005: Identity Security Gaps — CAF Review Findings

**Status:** In Remediation  
**Date:** 2026-04-23  
**Authors:** Platform Engineering  
**Reviewers:** Security Architecture, AI Platform Lead  
**Review Trigger:** Azure Architecture Center — "Provide custom authentication to Azure OpenAI in Foundry Models through a gateway" + CAF AI security guidance

---

## Context

During an April 2026 security review against the Microsoft Azure Architecture Center
guidance for AI gateway patterns, four identity and security gaps were assessed.
This ADR records the findings, the remediation decision for each, and tracks
resolution status.

Reference documents consulted:
- [Azure OpenAI gateway — custom authentication guide](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/guide/azure-openai-gateway-custom-authentication)
- [Azure OpenAI gateway guide](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/guide/azure-openai-gateway-guide)
- [CAF AI security best practices](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/scenarios/ai/security)

---

## Findings

### Gap 1 — APIM → Foundry: Managed Identity (✅ Compliant, No Action)

**Finding:** Microsoft guidance requires the gateway to authenticate to the AI
backend using a managed identity (Entra Bearer token), not a stored API key.

**Current state:** `infrastructure/bicep/foundry-apim-rbac.bicep` grants APIM's
system-assigned managed identity `Cognitive Services User` on both Foundry accounts.
The global APIM policy strips any inbound `api-key` header and injects an Entra
Bearer token using `authentication-managed-identity`. `disableLocalAuth: true` is
set on both AIServices accounts so key-based auth is disabled at the platform level.

**Decision:** Already compliant. No action required.

---

### Gap 2 — Identity Logging at APIM (⚠️ Partial)

**Finding:** Microsoft guidance requires the gateway to log the requesting client
and user identities on every call so that audit trails can be tied back to a specific
LOB, even though all traffic flows through a single MSI to Foundry.

**Current state:** APIM gateway diagnostics capture subscription-level identity,
request metadata, status, and routing information in Log Analytics with 90-day
retention. The removed custom audit stream is no longer present, so per-user JWT
claim extraction is not claimed by this platform.

**Decision:** Treat gateway metadata as operational telemetry. Workloads that require
per-user auditability must preserve validated Entra identity in their own audit system.

---

### Gap 3 — Per-LOB Routing to Separate Foundry Deployments (⚠️ Accepted Tradeoff)

**Finding:** Microsoft's recommended pattern for strong data isolation is to route
each LOB (or each security tier) to a dedicated Foundry project, so that model
deployments, vector stores, and agent state are never co-mingled.

**Current state:** The architecture uses a single shared Foundry instance
(Option A from [ADR-002](adr-002-foundry-integration.md)).  All LOBs share the same
model deployments and agent service namespace.  Isolation is enforced by APIM
subscription-key boundaries and RBAC at the Foundry level, not by physical project
separation.

**Tradeoff:** Per-LOB Foundry projects increase operational overhead significantly —
each new LOB requires a new AIServices account, private endpoint, DNS record, APIM
backend, and RBAC set.  The current single-hub model keeps onboarding simple and
cost-efficient.

**Mitigating controls in place:**
1. APIM subscription key is the only auth credential LOBs receive — they cannot
   reach Foundry directly.
2. APIM policies enforce model allowlists per product tier (Bronze/Silver/Gold).
3. Gold-tier subscriptions require manual approval and are limited to one per owner.
4. All requests are logged with caller identity (see Gap 2).

**Decision:** Accepted tradeoff. Re-evaluate if a Gold LOB requires agent state
isolation (e.g., private vector stores with confidential documents). At that point,
provision a dedicated Foundry project for Gold and route via a separate APIM backend.
See ADR-002 §"Option B" for the provisioning pattern.

**Owner:** Platform Engineering  
**Revisit trigger:** First Gold LOB onboarding request with agent state / RAG data.

---

### Gap 4 — Response Caching (Not Deployed)

The platform does not cache prompts or model responses. This avoids cross-subscription
data-isolation risk and keeps APIM behavior explicit. Any future caching design must
scope entries by subscription identity, define retention behavior, and be implemented
in the Bicep-owned inline policies before documentation claims it.

---

### Gap 5 — Entra Agent ID Inventory (🟡 Open — Governance)

**Finding:** Microsoft CAF AI security guidance recommends maintaining an inventory
of all agents using [Entra Agent ID](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/workload-id-agent-id-overview).
This provides visibility into which agents exist, which users/apps are running them,
and enables conditional access policies to restrict which agents can be registered.

**Current state:** The platform does not grant individual developer access to Foundry.
There is no Entra Agent ID registration requirement or catalog of running agents.

**Risk:** Without an agent inventory, a compromised developer credential could be
used to create a rogue agent that exfiltrates data through tool calls, with no
platform-level detection.

**Recommended remediation:**
1. Enable Entra Agent ID in the Foundry project settings (requires Entra P2).
2. Add a Conditional Access policy that requires agent registrations to be approved
  by the Security team for privileged users.
3. Export the agent inventory monthly to Log Analytics for governance review.

**Priority:** Medium — required before privileged LOBs use autonomous agents with
sensitive downstream tool access.

**Owner:** Identity & Access Management team  
**Target:** Gold tier GA date

---

### Gap 6 — Deployment Data-Plane Network Access (⚠️ Accepted Deployment Boundary)

**Finding:** The Function deployment storage account and certificate Key Vault have
public network routing enabled. They are not anonymous or key-authenticated public
services, but their data-plane endpoints are reachable from public networks.

**Current state:** Two deployment operations originate outside the platform VNet:

1. `azd deploy` uploads the Function package from a developer workstation or hosted
   CI runner to the Flex Consumption deployment container.
2. `Microsoft.Resources/deploymentScripts` runs an Azure-managed container that
   creates or verifies the default Key Vault certificate during provisioning.

**Compensating controls:**

- Storage explicitly disables shared-key access, anonymous blob access, and
  cross-tenant replication, defaults clients to OAuth, and grants the deploying
  principal only Storage Blob Data Contributor.
- The Function runtime uses its system-assigned identity for blob, queue, and table
  access; no storage connection-string secret is configured.
- Key Vault uses RBAC, purge protection, and soft delete. The certificate deployment
  script has a dedicated user-assigned identity with only Key Vault Certificates
  Officer, while Application Gateway receives only Key Vault Certificate User.
- Both deployment paths are declared and reconciled through Bicep/azd; no manual
  firewall or credential changes are permitted.

**Decision:** Retain public routing for these two deployment paths until deployments
run from a self-hosted VNet-connected agent and the certificate deployment script is
attached to a private subnet. At that point, set both resources to deny public
network access and remove the policy exception. Public routing is not an exception
to authentication: all data access remains Entra RBAC-only.

---

## Summary Table

| Gap | Severity | Status | File(s) Affected |
|-----|----------|--------|-----------------|
| 1 — APIM MSI to Foundry | ✅ Compliant | No action | `foundry-apim-rbac.bicep` |
| 2 — Identity logging | ⚠️ Partial | Gateway metadata only | `apim-gateway.bicep` |
| 3 — Per-LOB Foundry routing | ⚠️ Accepted | Revisit at Gold GA | `adr-002-foundry-integration.md` |
| 4 — Response caching | ✅ Not exposed | Not deployed | `apim-gateway.bicep` |
| 5 — Entra Agent ID inventory | 🟡 Governance | Open | Entra + Foundry config |
| 6 — Deployment data-plane network access | ⚠️ Accepted | Compensating controls | `supporting-infra.bicep` |

---

## Consequences

- Response caching remains disabled unless a subscription-scoped design receives
  security review and is implemented declaratively in Bicep.
