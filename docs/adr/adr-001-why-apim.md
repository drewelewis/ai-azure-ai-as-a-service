# ADR-001: Why Azure API Management as the AI Gateway

**Status:** Accepted  
**Date:** February 2026  
**Supersedes:** N/A

## Context

When deploying Azure AI (LLMs, Agents) to internal developers, IT managers face several challenges:

1. **Uncontrolled costs** - One runaway app can exhaust the entire org's Azure OpenAI quota
2. **Security & compliance** - No centralized audit trail; keys distributed to many teams
3. **Multi-region failover** - Manual retry logic if one region gets rate-limited
4. **Observability** - No single place to see all AI requests across teams
5. **Chargeback** - Hard to track spend by LOB, cost center, application

## Decision

**Use Azure API Management (APIM) as a centralized AI Gateway** in front of all Azure OpenAI and Azure AI Foundry endpoints.

APIM sits between developers and models, providing:
- Rate limiting & quota enforcement per team/app
- Circuit-state routing across regions
- Centralized audit logging
- Managed Identity auth (no key distribution)
- Request/response transformation

## Alternatives Considered

### ❌ Direct Azure OpenAI Endpoints
**Pros:** Simple, no additional layer
**Cons:** No centralized cost controls, keys scattered across teams, audit trails fragmented

### ❌ Custom Gateway (Python/Node.js)
**Pros:** Maximum flexibility
**Cons:** High maintenance, duplicate functionality, another service to operate

### ✅ Azure API Management (Chosen)
**Pros:** Enterprise SLA, built-in policies, deep Azure integration, managed-identity backends
**Cons:** Additional cost (~$100-500/mo depending on tier)

## Consequences

### Positive 🟢

1. **Cost Visibility** - Track tokens at the APIM layer and set quotas per subscription. APIM enforces Bronze 500 TPM / 60 RPM, Silver 1,000 TPM / 120 RPM, and Gold 2,000 TPM / 240 RPM; Foundry separately enforces aggregate deployment capacity.
    - **IT Manager** owns tier governance and approves LOB access or tier changes.
   - **Platform Engineer** owns infrastructure capacity: adjusts Foundry deployment `capacity` in Bicep (`azd provision`) and submits quota increase requests to Microsoft when platform-wide capacity is insufficient.
    - Developers escalate quota needs to the platform team. See [quota-management.md](../playbooks/quota-management.md).
2. **Resilience** - Auto-failover on rate limits without app code changes
3. **Security** - Managed Identity replaces scattered API keys
4. **Compliance** - Audit trail of every request at the gateway layer
5. **Flexibility** - Swap backend models without changing app code

### Negative 🔴

1. **Added Latency** - ~5-10ms per request (acceptable for AI workloads)
2. **Operational Complexity** - Another service to configure & monitor
3. **Cost** - APIM Premium tier pricing (~$4,000+/month for two units in two regions)
4. **Learning Curve** - Teams need to understand APIM policies

## Implementation

1. Deploy APIM in Premium tier (required for VNet injection and multi-region support)
2. Create three products: `/ai/inference`, `/ai/agents`, `/ai/completions`
3. Configure rate limiting policies (Bronze: 500 TPM / 60 RPM, Silver: 1,000 TPM / 120 RPM, Gold: 2,000 TPM / 240 RPM)
4. Enable Application Insights integration
5. Configure primary and secondary Foundry backends for circuit-state routing

## Cost Estimate

| Item | Cost/Month |
|------|-----------|
| APIM Premium (2 units × 2 regions) | ~$4,000 |
| Log Analytics (90-day retention) | ~$100 |
| **Total** | **~$4,200** |

## How Developers Experience This

❌ **Without APIM:**
```python
from openai import AzureOpenAI
client = AzureOpenAI(
    api_key="very-secret-key-shared-in-slack",
    azure_endpoint="https://my-org-eastus.openai.azure.com"
)
```

✅ **With APIM (This Design):**
```python
from openai import OpenAI
client = OpenAI(
    api_key=os.environ["APIM_SUBSCRIPTION_KEY"],
    base_url="https://my-org-ai.example.com/openai/v1"
)
```

Developers receive an application-specific APIM subscription key; Foundry credentials are never distributed.

## Related Decisions

- [ADR-002: Foundry Integration Pattern](adr-002-foundry-integration.md)

## References

- [AI Gateway in Azure API Management - Microsoft Learn](https://learn.microsoft.com/azure/api-management/api-management-features#api-gateway)

---

## Revision History

| Version | Date | Author | Change |
|---------|------|--------|--------|
| 1.0 | Feb 2026 | Platform Team | Initial version |
