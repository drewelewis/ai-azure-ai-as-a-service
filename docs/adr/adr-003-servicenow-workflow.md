# ADR-003: ServiceNow as the AI Governance Workflow Engine

**Status:** Accepted  
**Date:** February 2026  
**Supersedes:** N/A

## Context

As your Azure AI platform grows, governance becomes critical:

- **Model Requests** - "Can we use Claude?" → Evaluate cost/capability → Approve/deny
- **Quota Increases** - "We need more tokens" → Check current spend → Approve/deny
- **Infrastructure Changes** - "We need a new region" → Plan → Deploy
- **Access Control** - "New team needs AI access" → Onboard → Provision

Without a workflow engine, these become **ad-hoc email chains and tribal knowledge.**

## Decision

**Use ServiceNow as the IT Governance Workflow Engine** for all AI platform requests.

ServiceNow provides:
- Request forms (model requests, quota increases, access requests)
- Approval workflows (manager → IT architect → CFO if high spend)
- Integration with APIM/Foundry (auto-provision on approval)
- Audit trail for compliance
- SLA tracking for response times

## Architecture

```
Developer Submits Request
    ↓
ServiceNow Intake Form
    ├─ Model Request
    ├─ Quota Increase
    ├─ Access Request
    └─ New Tool/Integration
    ↓
Approval Workflow
    ├─ Manager approval (if budget impact)
    ├─ IT architect approval (if arch impact)
    └─ CFO approval (if high cost)
    ↓
Approved
    ↓
Automation Triggers
    ├─ Deploy model to Foundry
    ├─ Update APIM endpoint
    ├─ Increase quota in APIM policies
    └─ Notify developer → Ticket closed
```

## Workflow 1: Model Request

**Developer Wants:** "Use Llama 3.1 instead of GPT-4o"

```
1. ServiceNow Form
   ├─ Model: Llama 3.1 70B
   ├─ Reason: "Cost savings, company data never leaves Azure"
   ├─ Use case: "Email classification"
   ├─ Estimated monthly tokens: 10M
   └─ Cost impact: $200/month vs. $500/mo for GPT-4o

2. Routing
   └─ → IT Architect (evaluate capability match)

3. Decision
   ├─ ✅ Approved (Llama is cost-effective for classification)
   └─ Triggers: Deploy Llama 3.1 to Foundry Hub

4. Automation (In Background)
   ├─ Add "meta-llama-3-70b" to Foundry project
   ├─ Create APIM route: /ai/inference/llama-3-70b
   ├─ Tag with cost $0.15/1M tokens in Foundry
   ├─ Configure rate limit: 10M/month for this team
   └─ Notify developer: "Llama 3.1 is now available"
```

## Workflow 2: Quota Increase

**Developer Wants:** "Our token quota is exhausted; we need 2x"

```
1. ServiceNow Form
   ├─ Current quota: 50M tokens/month ($250)
   ├─ Requested quota: 100M tokens/month ($500)
   ├─ Reason: "New customer onboarded"
   └─ Business justification: "Revenue impact: $500K/quarter"

2. Routing
   ├─ → Team manager (budget approval)
   ├─ → CFO tier (if >$1K/month delta)
   └─ → IT Operations (technical feasibility)

3. Decision
   ├─ ✅ Approved
   └─ Triggers: Update APIM rate limit

4. Automation
   ├─ Update APIM policy: New RPM limit = 100M/30 days
   ├─ Log change in audit trail
   ├─ Email team: "Quota increased to 100M tokens"
   ├─ Alert: Monitor if they exceed 80M usage
   └─ Ticket closed
```

## Workflow 3: New Tool Integration

**Developer Wants:** "Our agent needs to call the HR API"

```
1. ServiceNow Form
   ├─ Tool: "HR System API" (https://hr-internal.company.com/api)
   ├─ Security: "Requires OAuth 2.0, company domain only"
   ├─ Owner: "hr-platform-team@company.com"
   └─ Use case: "Agent resolves employee benefits questions"

2. Routing
   ├─ → HR Platform Team (technical validation)
   ├─ → Security (OAuth correctness, data exposure risk)
   └─ → IT Operations (integration feasibility)

3. Decision
   ├─ ✅ Approved
   └─ Triggers: Add tool to APIM & Foundry

4. Automation
   ├─ Create APIM backend for HR API
   ├─ Store OAuth credentials in Key Vault (secure)
   ├─ Add tool definition to Foundry
   ├─ Update agent function schema
   ├─ Enable logging & auditing
   └─ Notify developer: "hr-lookup tool is ready"
```

## How This Scales

As you grow:

| Stage | Manual Approvals | ServiceNow automation |
|-------|---------|---------------------------|
| 3 teams, 5 models | Email chains | ✅ Done automatically |
| 20 teams, 50 models | Chaos | ✅ Workflows handle volume |
| 100 teams, 500 features | Bottleneck | ✅ Self-service with guardrails |

## Integration Points

### ServiceNow ↔ Azure

```python
# When a request is approved in ServiceNow:
import os
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient

# 1. ServiceNow approval trigger webhook
def on_model_approved(request_id: str, model_name: str, team: str):
    
    # 2. Add model to Foundry
    credential = DefaultAzureCredential()
    client = AIProjectClient(..., credential=credential)
    
    # 3. Update APIM (via Azure CLI or REST)
    # apim_policy = generate_rate_limit_policy(team, new_quota)
    # update_apim(apim_policy)
    
    # 4. Close ServiceNow ticket
    # servicenow_client.update_ticket(request_id, state="approved")
```

## Consequences

### Positive 🟢

1. **Governance at Scale** - Workflows + audit trails instead of emails
2. **Cost Control** - Every AI expenditure tracked & justified
3. **Self-Service** - Developers don't wait for IT; automation does the work
4. **Compliance** - Full audit trail for regulatory requirements
5. **Chargeback** - ServiceNow tracks spend by team for billing back to LOBs

### Negative 🔴

1. **Overhead** - ServiceNow setup & maintenance cost (~$50K/year licensing)
2. **Latency** - Approval workflows take time (but justified)
3. **Complexity** - Requires ServiceNow skills in your IT team

## Alternative: No Workflow (Ad-Hoc)

❌ **Rejected** because:
- No audit trail for compliance
- Uncontrolled costs (no approval gates)
- "Tribal knowledge"—when IT person leaves, history is lost
- Doesn't scale beyond 3-5 teams

## Related Decisions

- [ADR-001: APIM as Gateway](adr-001-why-apim.md)
- [ADR-002: Foundry Integration](adr-002-foundry-integration.md)

---

## Revision History

| Version | Date | Author | Change |
|---------|------|--------|--------|
| 1.0 | Feb 2026 | Platform Team | Initial version |
