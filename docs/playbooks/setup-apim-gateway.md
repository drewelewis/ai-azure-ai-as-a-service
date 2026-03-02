# Playbook: Setup Azure API Management as Your AI Gateway

**Audience:** IT Managers, Platform Engineers  
**Time Required:** 2-3 hours  
**Complexity:** Intermediate

---

## Overview

This playbook walks you through setting up **Azure API Management as the central gateway** for all AI requests in your organization. After completion:

✅ All developers route requests through APIM  
✅ Token quotas enforced per department  
✅ Semantic caching reduces costs by ~40%  
✅ Audit trail logged to Application Insights  
✅ Developers use corporate identity (no key distribution)  

---

## Prerequisites

- [ ] Azure subscription with Contributor access
- [ ] Azure AI Foundry project created (see [setup-foundry-hub-project.md](setup-foundry-hub-project.md))
- [ ] Azure OpenAI resource deployed
- [ ] Application Insights instance
- [ ] Permissions to create APIM instances

---

## Step 1: Create APIM Instance

### Option A: Use Bicep (Recommended)

```bash
# 1. Clone the infrastructure repo
git clone <your-repo>
cd infrastructure/bicep

# 2. Update parameters
cat > apim-params.bicepparam << EOF
using './apim-gateway.bicep'

param apimName = 'your-company-ai'
param openaiResourceName = 'your-openai-instance'
@secure()
param openaiApiKey = 'your-azure-openai-key'
param appInsightsName = 'your-app-insights'
param location = 'eastus'
EOF

# 3. Deploy
az deployment group create \
  --resource-group your-rg \
  --template-file apim-gateway.bicep \
  --parameters @apim-params.bicepparam
```

### Option B: Manual Portal Setup

1. **Azure Portal** → Search "API Management"
2. Click **Create**
3. Configuration:
   - **Name:** `your-company-ai`
   - **Resource Group:** Same as Azure OpenAI
   - **Location:** Same as OpenAI (e.g., `eastus`)
   - **Organization Name:** `Your Company`
   - **Administrator Email:** `admin@your-company.com`
   - **Pricing Tier:** Standard ($400/month)
4. Click **Create** and wait 30-45 minutes

---

## Step 2: Configure Logger (Application Insights)

Once APIM is deployed:

1. **APIM Portal** → **Loggers** (under Monitoring)
2. Click **+ Add Logger**
3. Configuration:
   - **Name:** `ai-token-logger`
   - **Resource Type:** `Application Insights`
   - **Instrumentation Key:** [Paste from your App Insights resource]
4. Click **Save**

### Verify in Application Insights

```bash
# Check logs are flowing
az monitor app-insights query --app your-app-insights \
  --analytics "customMetrics | where name == 'ai-tokens-used' | limit 10"
```

---

## Step 3: Create API Products

Products are how you organize APIs and apply policies. Create three:

### Product 1: AI Inference

1. **APIM Portal** → **Products**
2. Click **+ Add Product**
3. Configuration:
   - **Display Name:** `AI Inference`
   - **Description:** `Model inference endpoints (GPT-4o, Llama, etc.)`
   - **Subscription Required:** ✅ Yes
   - **Requires Approval:** ❌ No
   - **State:** Published
4. Click **Create**
5. Go to **APIs** → **+ Add API**
6. Choose **Azure OpenAI Service** (if provided) or select **HTTP**
7. Configure:
   - **Display Name:** `Azure OpenAI Completions`
   - **Web Service URL:** `https://your-openai.openai.azure.com`
   - **API URL Suffix:** `openai`

### Product 2: AI Agents

1. Click **+ Add Product**
2. Configuration:
   - **Display Name:** `AI Agents`
   - **Description:** `Agent Service endpoints`
   - **Subscription Required:** ✅ Yes
3. Link to your Foundry project API

### Product 3: Admin Operations

1. Click **+ Add Product**
2. Configuration:
   - **Display Name:** `AI Admin`
   - **Description:** `Agent creation, quota management`
   - **Subscription Required:** ✅ Yes
   - **Requires Approval:** ✅ Yes (only admins)

---

## Step 4: Configure Rate Limiting Policies

Policies enforce governance. Create them per product.

### For AI Inference Product

1. Go to **AI Inference** product
2. Click **Policies** → **Code view**
3. Paste this policy:

```xml
<policies>
    <inbound>
        <!-- Extract department from header -->
        <set-variable name="department" value="@(context.Request.Headers.GetValueOrDefault("X-Department-Id", "unknown"))" />
        
        <!-- Rate limit: 50M tokens/month = ~1700/day -->
        <rate-limit-by-key 
            calls="1700" 
            renewal-period="86400"
            counter-key="@("tokens_" + context.Variables["department"])"
        />
    </inbound>
    <backend>
        <forward-request />
    </backend>
    <outbound>
        <set-header name="X-RateLimit-Remaining" value="@(context.Response.Headers["RateLimit-Remaining"][0])" />
    </outbound>
</policies>
```

Save policy.

---

## Step 5: Create Azure OpenAI Backend

1. Go to **APIM instance** → **Backends**
2. Click **+ Add** (or **+ Create**)
3. Configuration:
   - **Name:** `azure-openai-prod`
   - **Type:** HTTP
   - **URL:** `https://your-openai-resource.openai.azure.com`
   - **Headers:**
     - Name: `api-key`
     - Value: [Your Azure OpenAI key]
   - **Description:** `Azure OpenAI eastus region`
4. Click **Create**

**Do NOT** put API keys directly here. Instead:
- Store keys in **Azure Key Vault**
- Reference via [Named Values](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-properties) in policies

---

## Step 6: Create Subscriptions (Developer Access)

Subscriptions are what developers use to call your APIs.

### Create Subscription for Data Science Team

1. **APIM Portal** → **Subscriptions**
2. Click **+ Add Subscription**
3. Configuration:
   - **Name:** `data-science-team`
   - **User:** [Select or Create]
   - **Product:** `AI Inference`
   - **Display Name:** `Data Science - Monthly Quota: 50M tokens`
4. Click **Create**
5. Copy the **Primary Key** → Share with team lead securely

### Create More Subscriptions

| Department | Product | Monthly Quota |
|-----------|---------|--------------|
| Data Science | AI Inference | 50M tokens |
| Customer Success | AI Inference | 10M tokens |
| Engineering | AI Inference | 100M tokens |
| Finance | AI Inference | 5M tokens |

---

## Step 7: Test the Gateway

### Test 1: Simple API Call

```bash
# 1. Get your subscription key (from Step 6)
SUBSCRIPTION_KEY="your-subscription-key"
DEPT_ID="data-science"

# 2. Call the gateway
curl -X POST "https://your-apim.azure-api.net/openai/deployments/gpt-4o/chat/completions?api-version=2024-02-15-preview" \
  -H "api-key: $SUBSCRIPTION_KEY" \
  -H "X-Department-Id: $DEPT_ID" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 100
  }'

# Expected response: JSON chat completion
```

### Test 2: Verify Logging

```bash
# Check Application Insights
az monitor app-insights query --app your-app-insights --analytics "
  customEvents
  | where name == 'api_call'
  | where customDimensions['department'] == 'data-science'
  | limit 10
"
```

---

## Step 8: Configure Authentication (Production)

Replace API key auth with **Managed Identity** or **Azure AD tokens**.

### Option A: Managed Identity (Recommended)

1. **APIM instance** → **System Assigned** (Identity tab)
2. Toggle **Status** to **On**
3. In your code (developer):

```python
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient

credential = DefaultAzureCredential()  # Uses managed identity
client = AIProjectClient(
    credential=credential,
    project_id="your-project",
    endpoint="https://your-apim.azure-api.net"
)
```

### Option B: Azure AD OAuth (Enterprise)

1. Register APIM as app in Azure AD
2. Create Authorization Server in APIM
3. Add OAuth2 validation policy

---

## Step 9: Set Up Monitoring Dashboards

Create dashboards in Application Insights to track:

```kusto
// Token usage by department (daily)
customEvents
| where name == "token_consumption"
| summarize TotalTokens = sum(todouble(customDimensions["tokens"])) by 
  customDimensions["department"], 
  bin(timestamp, 1d)
| render timechart

// Latency by model
customEvents
| summarize AvgLatencyMs = avg(todouble(customDimensions["latency"])) by 
  customDimensions["model"]
| render columnchart

// Error rate by department
customEvents
| where customDimensions["status"] == "error"
| summarize ErrorCount = count() by customDimensions["department"]
| render piechart
```

---

## Step 10: Communicate to Developers

Send developers this info:

```
Subject: New AI Platform - APIM Gateway Live

Hi Team,

Your new managed AI platform is ready!

Gateway URL: https://your-company-ai.azure-api.net

To get started:
1. Get your subscription key: https://dev.azure.com/your-org/ai-platform/_wiki?wikiVersion=GBmaster&pagePath=%2FGetting%20Started
2. Install SDK: pip install azure-ai-projects
3. Use this code:

    from azure.ai.projects import AIProjectClient
    from azure.identity import DefaultAzureCredential
    
    client = AIProjectClient(
        credential=DefaultAzureCredential(),
        project_id="my-project",
        endpoint="https://your-company-ai.azure-api.net"  # ← NEW
    )

That's it! All requests are now:
✅ Governed by quota
✅ Logged for audit
✅ Cached for cost reduction
✅ Routed through security policies

Questions? See the Developer Quick Start guide.
```

---

## Troubleshooting

### "401 Unauthorized"

```bash
# Check subscription key is correct
az rest --method get \
  --url "https://your-apim.azure-api.net/api-version-sets?api-version=2021-12-01-preview" \
  --headers "api-key=$SUBSCRIPTION_KEY"
```

### "429 Rate Limited"

Your team hit the token quota. Either:
1. Increase quota through ServiceNow
2. Use a cheaper model
3. Optimize prompts to use fewer tokens

### "502 Bad Gateway"

Backend (Azure OpenAI) is unreachable. Check:
- Azure OpenAI resource is running
- API key in backend config is correct
- Network connectivity

---

## Next Steps

1. ✅ Developers are connecting
2. 👉 Set up [ServiceNow integration](servicenow-workflow.md) for quota requests
3. 👉 Configure [Grafana dashboards](../infrastructure/bicep/grafana-dashboard.bicep) for multi-team visibility
4. 👉 Document in [organizational wiki](../docs/)

---

## Costs

| Component | Monthly Cost |
|-----------|--------|
| APIM (Standard) | $400 |
| Application Insights (1GB/day) | $50 |
| Azure AI Search (standard) | $100 |
| **Total** | **~$550** |

**ROI:** Semantic caching alone saves 30-40% of token costs, paying for infrastructure.

---

**Questions?** See [ADR-001: Why APIM](../docs/adr/adr-001-why-apim.md) for architectural rationale.
