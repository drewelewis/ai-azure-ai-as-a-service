# GitHub Copilot Instructions

## Solution Overview

This repo is **Azure AI as a Managed Service** — an enterprise platform that exposes Azure AI (LLMs, Agents) to internal lines-of-business (LOBs) through **Azure API Management (APIM)** as a governed gateway in front of **Azure AI Foundry**.

All Infrastructure, permissions, identities, policies, and application code are declared in Bicep and deployed through Azure Developer CLI (`azd`). No manual Azure Portal or `az` CLI mutations are allowed.

Any defects found in the provisioning of this platform must be fixed in the Bicep templates, not patched in Azure. The platform is designed to be **deterministic** and **idempotent** — any drift from the declared state must be reconciled through `azd provision`.

### Architecture in one sentence
> Developers call a single APIM endpoint with a subscription key. APIM enforces quotas, logs every request, applies circuit-state failover, and forwards traffic to Foundry over private endpoints using managed identity. No model keys are ever distributed.

### Key components

| Component | What it does |
|---|---|
| **APIM Premium (Internal VNet)** | AI gateway — rate limiting, failover, and audit logging |
| **Azure AI Foundry × 2** | Primary (East US) + Secondary (West US) with a configurable mirrored model portfolio |
| **Private Endpoints × 2** | Foundry reachable only inside the VNet — no public access |
| **Log Analytics (90-day)** | APIM gateway logs and metrics for operations and audit |
| **Application Insights** | Latency, token counts, HTTP status per request |
| **Azure Monitor Workbooks** | Token usage, request tracing, and performance views |
| **App Gateway / WAF** | Public ingress in front of APIM for production traffic |
| **ACI Jumpbox** | VNet-internal container for dev/test access to APIM |
| **Key Vault** | TLS certificate storage; managed identity access only |

### Subscription tiers (APIM products)

| Tier | APIM product ID | Models | TPM | RPM |
|---|---|---|---|---|
| **Bronze** | `ai-bronze` | Portfolio deployments tagged for Bronze | 500 | 60 |
| **Silver** | `ai-silver` | Portfolio deployments tagged for Silver + Agents API | 1,000 | 120 |
| **Gold** | `ai-gold` | Entire deployed portfolio + Agents API | 2,000 | 240 |

### Auth model
- **Client → APIM**: `Ocp-Apim-Subscription-Key` header (one key per LOB/app)
- **APIM → Foundry**: System-assigned managed identity (Entra Bearer token) — no keys stored anywhere

### Developer SDK usage
Developers use the standard OpenAI SDK with the APIM endpoint and subscription key:
```python
from openai import OpenAI
client = OpenAI(
    api_key=os.environ["APIM_SUBSCRIPTION_KEY"],
    base_url="https://<gateway-host>/openai/v1"
)
```

### Key policies
- Inline policies in `infrastructure/bicep/apim-gateway.bicep` own tier quotas, managed-identity backend authentication, and multi-region circuit-state routing.

## Infrastructure-as-Code: No Manual Azure Changes

**ALL Azure resource lifecycle changes MUST go through `azd`: create/update with
`azd provision` or `azd deploy`, and delete with `azd down`.** Teardown is an
infrastructure change and is subject to the same declarative ownership rules as
provisioning.

This project uses Azure Developer CLI (`azd`) with Bicep (`infrastructure/bicep/`) as the single source of truth for all Azure infrastructure and application deployments. Manual one-off changes made directly in the Azure Portal, via `az` CLI resource mutations, or any other out-of-band method will drift from the declared state and will be overwritten on the next provision.

### Rules

1. **Never suggest `az resource update`, `az storage account update`, `az functionapp config`, or similar mutating `az` commands as a fix.** If a resource is misconfigured, find the correct Bicep file in `infrastructure/bicep/` and fix it there, then run `azd provision`.

2. **Never suggest Portal changes.** If a setting needs changing, it goes in Bicep.

3. **This repository has no deployable application service.** Use `azd provision` for the declared platform.

4. **Infrastructure changes** (APIM policies, networking, storage, RBAC, app settings) → edit the relevant Bicep file, then `azd provision`.

5. **Policy changes** → edit the inline APIM policies in `infrastructure/bicep/apim-gateway.bicep`, then run `azd provision`.

6. **RBAC assignments** → defined in Bicep modules such as `infrastructure/bicep/foundry-apim-rbac.bicep`. Do not assign roles ad hoc with `az role assignment create` as a permanent fix.

7. **Environment teardown** → use `azd down` for each confirmed azd environment.
   Never delete a resource group, individual resource, role assignment, deployment,
   or lock directly with Azure CLI, PowerShell, REST, or the Portal.

8. **Direct `az` usage is read-only only.** Permitted operations are diagnostics and
   inventory such as `az account show`, `az group list`, `az resource list`, and
   `az role assignment list`. Commands that create, update, delete, assign, purge,
   register, start, stop, or restart Azure state are prohibited.

9. **Never run or suggest destructive bypasses**, including `az group delete`,
   `az resource delete`, `az role assignment delete`, `Remove-AzResourceGroup`, or
   equivalent REST/Portal operations. User approval does not override this rule;
   approval authorizes the corresponding `azd` lifecycle operation only.

10. **Missing local azd state is a blocker, not permission to bypass azd.** If an
    Azure resource group appears project-owned but its azd environment is not listed
    locally, stop before deletion. Reconstruct or import/select the environment with
    supported `azd env` commands, verify its subscription and resource-group scope,
    obtain explicit confirmation, and then use `azd down`. If azd cannot own the
    teardown safely, report the blocker and do not mutate Azure.

11. **Destructive workflow is mandatory:** inventory with read-only commands, map
    every environment to subscription and resource group, review the exact scope
    with the user, receive explicit confirmation, run `azd down` one environment at
    a time, verify removal read-only, and only then remove local azd environment
    state using `azd env` commands.

### Key files

| What to change | File |
|---|---|
| APIM gateway, products, subscriptions | `infrastructure/bicep/apim-gateway.bicep` |
| Networking, private endpoints | `infrastructure/bicep/networking.bicep` |
| RBAC for Foundry / APIM | `infrastructure/bicep/foundry-apim-rbac.bicep` |
| Key Vault, supporting resources | `infrastructure/bicep/supporting-infra.bicep` |
| Top-level wiring | `infrastructure/bicep/main.bicep` |

### Deploy commands

```bash
# Deploy application code only (fast)
azd deploy

# Provision infrastructure (Bicep) + deploy code
azd provision && azd deploy

# Full up (provision + deploy in one command)
azd up
```

### Teardown command

```bash
# Delete resources owned by one confirmed azd environment.
azd down -e <environment> --purge
```

Do not substitute an `az`, `Remove-Az*`, REST, or Portal deletion when `azd down`
fails. Diagnose the azd failure or stop and report the blocker.

### When diagnosing a broken deployment

Before suggesting an `az` CLI mutation as a fix:
1. Check whether the Bicep already declares the correct value.
2. If yes → the Azure resource has drifted. Run `azd provision` to reconcile — do not patch Azure directly.
3. If no → update the Bicep, commit, then run `azd provision`.

> **Example of what NOT to do**: `az storage account update --public-network-access Enabled`  
> **Correct approach**: update the owning Bicep module, commit, and run `azd provision`.


## Delivery Tracking Requirement

Whenever implementation work is planned, started, completed, or blocked, follow the unified workflow in `.github/skills/delivery-tracking/SKILL.md`.

The primary implementation agent owns all edits to `todo.md` and `changelog.md`. Do not delegate tracker edits to a subagent.

For a large delivery, invoke the read-only `delivery-auditor` subagent before final tracker updates. A delivery is large when it meets any of these thresholds:

- 10 or more changed files.
- 500 or more changed lines.
- Changes spanning 3 or more top-level repository areas.

The auditor reports omissions and inconsistencies only. The primary agent evaluates its findings, applies justified tracker updates, and performs final validation.

Do not finalize implementation work unless `todo.md` reflects its actual state and `changelog.md` records only completed, validated changes. Entries must be factual, must include impacted paths where practical, and must never contain secrets or private data.
