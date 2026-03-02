# ADR-002: Azure AI Foundry as the Hub for Models & Agents

**Status:** Accepted  
**Date:** February 2026  
**Supersedes:** N/A

## Context

Organizations need a **single control plane** for:
- Exploring models (1900+ options: OpenAI, Meta, Llama, Claude, etc.)
- Creating and managing agents
- Evaluating model performance
- Managing knowledge bases (RAG)
- Audit logging and compliance

## Decision

**Use Azure AI Foundry as the central hub** for all AI model and agent lifecycle management. Route Foundry traffic through APIM (ADR-001).

This gives developers a consistent API contract whether they're using:
- GPT-4o (Microsoft-hosted)
- Llama (partner-hosted)
- Custom fine-tuned models

## Architecture

```
Developer App
    ↓
AIProjectClient (Foundry SDK)
    ↓
APIM Gateway (Cost Control, Caching, Auth)
    ↓
Azure AI Foundry Project
    ├─ Models (inference endpoint)
    ├─ Agent Service
    ├─ Knowledge Base (Azure AI Search)
    └─ Evaluations
    ↓
    Logs → Application Insights → Grafana
```

## Why Foundry Instead of Direct Azure OpenAI?

| Feature | Direct Azure OpenAI | Azure AI Foundry |
|---------|-------------------|-------------------|
| Model catalog access | ❌ GPT-4/3.5 only | ✅ 1900+ models |
| Agent Service | ❌ | ✅ Assistants API compatible |
| Fine-tuning UI | ❌ | ✅ Built-in |
| Evaluations | ❌ | ✅ Evaluate agent quality |
| Knowledge bases | ❌ | ✅ RAG built-in |
| Project isolation | ❌ | ✅ Multi-tenant safe |

**Bottom line:** Foundry is Azure's comprehensive AI platform; Azure OpenAI is just a component within it.

## Implementation Pattern: Hub Project

Create **one "Hub" Foundry Project** that all developers access through APIM:

```
Azure AI Foundry (Hub Project)
├─ Models Available
│  ├─ gpt-4o (Microsoft-hosted)
│  ├─ meta-llama-3-70b (partner)
│  ├─ claude-opus-4 (partner)
│  └─ custom-fine-tuned (your org)
├─ Shared Tools & Integrations
│  ├─ Function tools (your APIs)
│  ├─ Azure AI Search (knowledge)
│  └─ Azure Logic Apps (workflows)
└─ Evaluation & Testing
   ├─ Model comparison
   ├─ Agent performance metrics
   └─ Cost analysis per model
```

**All traffic routed through APIM** for cost control and audit.

## Developer Experience

### Simple Chat
```python
from azure.ai.projects import AIProjectClient
client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="hub-project",
    endpoint="https://my-org-ai.azure-api.net"
)

# Use any Foundry model
response = client.inference.get_chat_completions_client().complete(
    model="gpt-4o",  # or "meta-llama-3-70b", "claude-opus-4", etc.
    messages=[{"role": "user", "content": "Hello"}]
)
```

### Create & Run Agents
```python
# IT team deploys model → Foundry → APIM
# Developer uses unified API regardless of backend
agent = client.agents.create_agent(
    name="my-agent",
    model="gpt-4o"  # Foundry abstracts the actual backend
)
```

## Foundry Project Isolation vs. Hub

**Two deployment models:**

### Option A: Hub Project (Recommended)
- ✅ One shared project
- ✅ All teams use same models/evaluations
- ✅ Easier to manage costs centrally
- ✅ Simpler APIM routing
- ❌ Data mixed (mitigated by Foundry's multi-tenant isolation)

### Option B: Per-Team Projects
- ✅ Strict data isolation
- ✅ Per-team observability
- ❌ Duplicate infrastructure
- ❌ Complex APIM routing

**Recommendation:** Use **Option A (Hub)** with Foundry's role-based access control.

## Integration with ServiceNow

When developers request a new model or increase quota:

1. Ticket filed in ServiceNow
2. IT approves (via ADR-003 workflow)
3. Model deployed to Foundry Hub Project
4. APIM endpoint automatically updated
5. Developers get it without code changes

## Consequences

### Positive 🟢

1. **Model Flexibility** - Swap models without code changes
2. **Centralized Experiments** - All teams use same evaluation framework
3. **Cost Optimization** - Easy to identify cheapest model for a use case
4. **Knowledge Sharing** - Common knowledge bases (RAG) across teams
5. **Compliance** - Audit trail through Foundry + APIM + App Insights

### Negative 🔴

1. **Complexity** - Another platform to learn (vs. direct Azure OpenAI)
2. **Slower Iteration** - Changes to Foundry require IT approval
3. **Additional Costs** - Foundry Hub Project costs (~$50/month)

## Related Decisions

- [ADR-001: APIM as Gateway](adr-001-why-apim.md)
- [ADR-003: ServiceNow Workflow](adr-003-servicenow-workflow.md)

---

## Revision History

| Version | Date | Author | Change |
|---------|------|--------|--------|
| 1.0 | Feb 2026 | Platform Team | Initial version |
