# ANSWERS TO YOUR CRITICAL QUESTIONS

## Your Questions Answered

### 1. Will ALL subsequent SDK calls use the endpoint parameter?

**Answer: ⚠️ UNVERIFIED - This is a critical assumption that needs validation**

**What your code assumes:**
```python
client = AIProjectClient(
    endpoint="https://my-apim.azure-api.net",
    ...
)
# Assumption: create_agent, create_thread, create_run, etc. ALL use this endpoint
```

**The risk:** If the SDK internally constructs Azure-specific URLs for certain operations, 
they would bypass APIM, defeating your governance controls.

**What we don't know:**
- Does `create_agent()` use the endpoint or query discovery APIs directly?
- Does `create_thread()` construct its own `*.api.azureml.ms` URLs?
- Does `create_run()` make direct ARM API calls?
- Does the inference client honor the endpoint for model calls?

**Evidence from your repository:**
- All examples ASSUME endpoint parameter works for everything
- No actual SDK source code verification found
- No Microsoft documentation confirming this behavior
- Comments like "This ensures ALL traffic goes through APIM" are assumptions, not verified facts

---

### 2. Does the SDK expect a specific endpoint format?

**Answer: LIKELY YES - Azure SDKs typically expect Azure service URLs**

**Expected formats:**
- `https://<region>.api.azureml.ms` (Azure ML / Foundry)
- `https://<workspace>.cognitiveservices.azure.com` (Cognitive Services)
- `https://<instance>.openai.azure.com` (Azure OpenAI)

**Your APIM format:**
- `https://<name>.azure-api.net`

**Potential issues:**
1. **URL path expectations:** SDK might expect specific URL structures
   ```
   Expected: https://westus.api.azureml.ms/discovery/workspaces/{id}
   Your APIM: https://my-apim.azure-api.net/???
   ```
   
2. **Header expectations:** SDK might add headers like `x-ms-azureml-endpoint` that APIM needs to proxy

3. **Authentication:** SDK might try to get tokens for `https://ml.azure.com` scope, not your APIM URL

**What could break:**
- SDK initialization might fail with endpoint validation errors
- Some operations might work, others fail mysteriously
- SDK might ignore your endpoint and query Azure directly

---

### 3. What does the SDK source code show?

**Answer: NOT REVIEWED - You need to check it yourself**

**To verify, examine:**
```bash
# Clone Azure SDK
git clone https://github.com/Azure/azure-sdk-for-python
cd azure-sdk-for-python/sdk/ai/azure-ai-projects

# Check these files:
# - azure/ai/projects/_client.py (main client)
# - azure/ai/projects/agents/_client.py (agents operations)
# - azure/ai/projects/inference/_client.py (model inference)
```

**What to look for:**

✅ **Good signs:**
```python
class AIProjectClient:
    def __init__(self, endpoint, ...):
        self._endpoint = endpoint
        self._agents = AgentsClient(endpoint=self._endpoint)  # Passes through
```

❌ **Red flags:**
```python
# Hardcoded URLs
BASE_URL = "https://westus.api.azureml.ms"

# Discovery that bypasses endpoint
def _get_real_endpoint(self):
    discovery_url = "https://management.azure.com/..."
    return requests.get(discovery_url).json()['endpoint']

# Missing endpoint parameter
class AgentsClient:
    def __init__(self, credential, project_id):  # No endpoint!
        self._url = self._build_url(project_id)
```

**See detailed investigation guide:** [SDK-SOURCE-CODE-INVESTIGATION.md](SDK-SOURCE-CODE-INVESTIGATION.md)

---

### 4. Are there Microsoft docs examples?

**Answer: NO - No examples found showing custom endpoints with AIProjectClient**

**What Microsoft docs show:**
- Standard Azure OpenAI endpoints
- Azure AI Foundry project endpoints (*.api.azureml.ms)
- Direct cognitive services endpoints

**What Microsoft docs DON'T show:**
- Using APIM gateway URLs with AIProjectClient
- Custom endpoint validation or requirements
- List of operations that honor/ignore endpoint parameter
- Architecture diagrams showing APIM + azure-ai-projects SDK

**Found examples:**
- APIM with Azure OpenAI directly (not via azure-ai-projects SDK): ✅
- APIM as AI Gateway for inference: ✅
- Custom endpoints with AIProjectClient: ❌ NOT FOUND

**Action:** You should request Microsoft add this to their documentation.

---

## What This Means for Your Architecture

### Current State: RISKY

```
Your App
   ↓ AIProjectClient(endpoint=APIM_URL)
   ↓
   ↓ ???  <- UNVERIFIED: Does ALL traffic go here?
   ↓
APIM Gateway
   ↓
Azure AI Foundry
```

**If SDK bypasses endpoint parameter for some operations:**
- ❌ Token quotas not enforced
- ❌ Semantic caching not applied
- ❌ Circuit breakers won't trigger
- ❌ Audit logs incomplete
- ❌ Cost attribution wrong

### Recommended: Defense in Depth

```
Your App
   ↓ AIProjectClient(endpoint=APIM_URL)
   ↓
APIM Gateway (application layer)
   ↓ Private Link ONLY
   ↓
Azure AI Foundry
   publicNetworkAccess: Disabled  <- Network layer enforcement
```

**With network-level enforcement:**
- ✅ Even if SDK tries to bypass, network blocks it
- ✅ Your Bicep already has `publicNetworkAccess: 'Disabled'`
- ✅ APIM needs private endpoint to reach Foundry
- ✅ Apps CANNOT bypass APIM at network level

**Your infrastructure/bicep/foundry-hub-project.bicep already has this:**
```bicep
resource foundryProject 'Microsoft.MachineLearningServices/workspaces@2023-04-01' = {
  properties: {
    publicNetworkAccess: 'Disabled'  // ✅ Good!
  }
}
```

---

## Immediate Action Items

### 1. Run Traffic Capture Test

```bash
# Install mitmproxy
pip install mitmproxy

# Start proxy
mitmproxy --port 8080

# Configure environment
export HTTPS_PROXY=http://localhost:8080
export HTTP_PROXY=http://localhost:8080

# Run your agent code
python examples/python/6-foundry-agent-via-apim.py

# Watch mitmproxy output:
# ✅ ALL requests should go to: your-company-ai.azure-api.net
# ❌ ZERO requests should go to: *.api.azureml.ms
```

**If you see direct azureml.ms requests → SDK is bypassing APIM!**

### 2. Run Mock Test

```bash
python tests/test-sdk-endpoint-routing.py
```

This test patches HTTP libraries to capture all outgoing requests.

### 3. Review SDK Source Code

Follow: [SDK-SOURCE-CODE-INVESTIGATION.md](SDK-SOURCE-CODE-INVESTIGATION.md)

### 4. Deploy Network Enforcement

```bash
# Ensure Foundry has public access disabled
az ml workspace update \
  --name ai-hub-project \
  --public-network-access Disabled

# Create private endpoint from APIM to Foundry
az network private-endpoint create \
  --name pe-foundry \
  --resource-group rg-ai \
  --vnet-name vnet-apim \
  --subnet snet-apim \
  --private-connection-resource-id $(az ml workspace show --name ai-hub-project --query id -o tsv) \
  --group-id workspace \
  --connection-name foundry-connection
```

### 5. Open Microsoft Support Ticket

**Subject:** "AIProjectClient endpoint parameter behavior with Azure API Management"

**Body:**
```
We are implementing an enterprise AI governance platform using Azure API Management 
as a gateway for Azure AI Foundry projects. Our architecture requires ALL SDK 
operations to route through APIM for:
- Token quota enforcement
- Semantic caching
- Audit logging
- Cost control

Question: Does AIProjectClient honor the endpoint parameter for ALL operations?

Example code:
```python
client = AIProjectClient(
    credential=DefaultAzureCredential(),
    endpoint="https://our-apim.azure-api.net",  # Custom APIM gateway
    project_id="our-project"
)

# Do ALL of these use the APIM endpoint?
client.agents.create_agent(...)
client.agents.create_thread(...)
client.agents.create_run(...)
client.inference.get_chat_completions_client().complete(...)
```

Specifically:
1. Does the SDK construct any Azure-specific URLs (*.api.azureml.ms) that bypass 
   the custom endpoint?
2. What is the expected endpoint format for AIProjectClient?
3. Are there any operations (discovery, telemetry, etc.) that directly contact 
   Azure services?

Critical: If any operations bypass the endpoint, our governance controls fail.

Please provide:
- Official documentation confirming behavior
- Architecture guidance for APIM + AIProjectClient
- List of operations that honor/ignore endpoint parameter
```

---

## Your Best Path Forward

### Short-term (This Week)

1. ✅ Run traffic capture with mitmproxy
2. ✅ Verify network enforcement is configured (`publicNetworkAccess: Disabled`)
3. ✅ Test all SDK operations (agent creation, threads, runs, inference)
4. ✅ Document findings

### Medium-term (This Month)

1. ✅ Review SDK source code on GitHub
2. ✅ Open Microsoft support ticket
3. ✅ Configure Azure Monitor alerts for direct Foundry access
4. ✅ Update team documentation with findings

### Long-term (Next Quarter)

1. ✅ Contribute documentation to Microsoft if gaps found
2. ✅ Share findings with Azure community
3. ✅ Consider SDK wrapper if bypass detected
4. ✅ Evaluate alternative AI gateway solutions if needed

---

## Key Takeaway

**Your architecture's success depends on an UNVERIFIED assumption:**
> "Setting endpoint on AIProjectClient routes ALL operations through that endpoint"

**This might be true, but you MUST verify it.**

**Your Bicep has a critical safety net:**
```bicep
publicNetworkAccess: 'Disabled'
```

**This means even if the SDK tries to bypass, the network blocks it.**  
**Keep this configuration!**

---

## Files Created for You

1. **tests/test-sdk-endpoint-routing.py** - HTTP capture test
2. **docs/SDK-ENDPOINT-VERIFICATION.md** - Complete risk analysis
3. **docs/SDK-SOURCE-CODE-INVESTIGATION.md** - Source code review guide
4. **This file** - Direct answers to your questions

## Next Steps

1. Read [SDK-ENDPOINT-VERIFICATION.md](SDK-ENDPOINT-VERIFICATION.md) for full analysis
2. Run the traffic capture test
3. Review SDK source code
4. Open Microsoft support ticket
5. Report back findings

**Bottom line:** Don't trust "This ensures ALL traffic goes through APIM" comments until you VERIFY it.
