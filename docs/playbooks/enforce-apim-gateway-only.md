# Enforce APIM Gateway Only Access

This guide ensures all agent and application traffic flows through APIM, preventing direct access to Foundry models and enforcing your token quotas, rate limits, and governance policies.

## Why This Matters

**Problem**: If agents can bypass APIM and call Foundry models directly, they circumvent:
- ❌ Token quota policies
- ❌ Rate limiting
- ❌ Circuit breakers
- ❌ Audit logging
- ❌ Cost controls

**Solution**: Use a defense-in-depth approach to force all traffic through APIM.

---

## Layer 1: Network Isolation (Strongest)

### Disable Public Network Access

Your Foundry resources are now configured to **deny public access** (see `infrastructure/bicep/foundry-hub-project.bicep`):

```bicep
publicNetworkAccess: 'Disabled'  // No internet access
```

This means:
- ✅ Direct calls to Foundry endpoints will **fail**
- ✅ APIM connects via private endpoint (configure separately)
- ✅ Even if someone has credentials, they can't reach the endpoint

### Configure Private Endpoints

Add private endpoints to your APIM Bicep:

```bicep
// Private endpoint for APIM to reach Foundry
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: 'pe-foundry-to-apim'
  location: location
  properties: {
    subnet: {
      id: apimSubnetId  // Where APIM is deployed
    }
    privateLinkServiceConnections: [{
      name: 'foundry-connection'
      properties: {
        privateLinkServiceId: foundryProject.id
        groupIds: ['workspace']
      }
    }]
  }
}
```

---

## Layer 2: Azure RBAC (Identity Controls)

### Grant Foundry Access ONLY to APIM

Your APIM needs permissions, but your apps should NOT:

APIM-to-Foundry access is declared in
`infrastructure/bicep/foundry-apim-rbac.bicep`. Apply it with `azd provision`.
Use read-only inventory to verify an application identity does not have direct access:

```bash
az role assignment list \
  --assignee YOUR_APP_IDENTITY \
  --scope /subscriptions/YOUR_SUB/resourceGroups/rg-ai/providers/Microsoft.CognitiveServices/accounts/FOUNDRY_ACCOUNT
# Should return empty []
```

### What Roles Apps Should Have

Your application identities should only have:
- ✅ **API Management Service Reader** on the APIM service (to discover it)
- ✅ No direct Foundry access
- ✅ No Azure OpenAI access

---

## Layer 3: Configuration Management

### Store ONLY APIM Endpoint

**❌ Don't Do This:**
```python
# Never hardcode direct endpoints!
FOUNDRY_ENDPOINT = "https://my-foundry.api.azureml.ms"  # BAD!
OPENAI_ENDPOINT = "https://my-openai.openai.azure.com"  # BAD!
```

**✅ Do This:**
```python
import os
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

# Read from Key Vault
kv_client = SecretClient(
    vault_url="https://your-keyvault.vault.azure.net",
    credential=DefaultAzureCredential()
)

APIM_ENDPOINT = kv_client.get_secret("AI-Gateway-Endpoint").value
# Returns: "https://your-company-ai.azure-api.net"
```

### Key Vault Setup

Store the gateway endpoint centrally:

```bash
az keyvault secret set \
  --vault-name your-keyvault \
  --name "AI-Gateway-Endpoint" \
  --value "https://your-company-ai.azure-api.net"

az keyvault secret set \
  --vault-name your-keyvault \
  --name "AI-Project-ID" \
  --value "ai-hub-project"
```

### Environment Variables (12-Factor App)

For containerized apps:

```yaml
# Azure Container Apps environment variables
env:
  - name: AI_GATEWAY_ENDPOINT
    secretRef: ai-gateway-endpoint
  - name: AI_PROJECT_ID
    value: "ai-hub-project"
```

---

## Layer 4: Code Patterns

### Python Agent Pattern

```python
import os
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

class AIAgentFactory:
    """Factory to create agents with enforced APIM routing."""
    
    def __init__(self):
        # Read from environment - fail fast if not configured
        self.endpoint = os.environ.get("AI_GATEWAY_ENDPOINT")
        self.project_id = os.environ.get("AI_PROJECT_ID")
        
        if not self.endpoint:
            raise ValueError(
                "AI_GATEWAY_ENDPOINT environment variable not set. "
                "All AI traffic must go through APIM gateway."
            )
        
        if not self.endpoint.endswith(".azure-api.net"):
            raise ValueError(
                f"Invalid endpoint: {self.endpoint}. "
                "Must be an APIM gateway URL (*.azure-api.net)"
            )
    
    def create_client(self) -> AIProjectClient:
        """Create AI client that ONLY talks to APIM."""
        return AIProjectClient(
            credential=DefaultAzureCredential(),
            project_id=self.project_id,
            endpoint=self.endpoint  # Always APIM
        )

# Usage
factory = AIAgentFactory()
client = factory.create_client()

agent = client.agents.create_agent(
    name="my-agent",
    model="gpt-4o",
    instructions="You are a helpful assistant."
)
```

### C# Agent Pattern

```csharp
using Azure.AI.Projects;
using Azure.Identity;

public class AIAgentFactory
{
    private readonly string _endpoint;
    private readonly string _projectId;
    
    public AIAgentFactory()
    {
        _endpoint = Environment.GetEnvironmentVariable("AI_GATEWAY_ENDPOINT")
            ?? throw new InvalidOperationException("AI_GATEWAY_ENDPOINT not configured");
        
        _projectId = Environment.GetEnvironmentVariable("AI_PROJECT_ID")
            ?? throw new InvalidOperationException("AI_PROJECT_ID not configured");
        
        // Validate it's an APIM endpoint
        if (!_endpoint.Contains(".azure-api.net"))
        {
            throw new InvalidOperationException(
                $"Invalid endpoint: {_endpoint}. Must be APIM gateway (*.azure-api.net)");
        }
    }
    
    public AIProjectClient CreateClient()
    {
        return new AIProjectClient(
            new Uri(_endpoint),
            new DefaultAzureCredential()
        );
    }
}

// Usage
var factory = new AIAgentFactory();
var client = factory.CreateClient();
```

---

## Layer 5: Monitoring & Detection

### Set Up Alerts for Direct Access

Create an Azure Monitor alert if anyone tries to bypass APIM:

```kql
// Query: Direct access to Foundry (should be zero)
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.MACHINELEARNINGSERVICES"
| where OperationName has "inference"
| where CallerIpAddress != "YOUR_APIM_IP"  // Traffic not from APIM
| summarize DirectAccessCount=count() by CallerIpAddress, Identity_s
```

### Azure Monitor Workbook

Add the bypass query to the deployed Azure Monitor workbooks so operators can review direct-access attempts alongside APIM traffic.

---

## Verification Checklist

Use this checklist after deployment:

### ✅ Network Layer
- [ ] Foundry `publicNetworkAccess` is `Disabled`
- [ ] Private endpoint exists from APIM to Foundry
- [ ] Direct HTTP calls to Foundry endpoint fail (test with curl)

### ✅ Identity Layer
- [ ] APIM managed identity has "Azure AI Developer" role on Foundry
- [ ] App managed identities DO NOT have direct Foundry access
- [ ] Service principals used by apps DO NOT have Foundry access

### ✅ Configuration Layer
- [ ] Key Vault contains `AI-Gateway-Endpoint` secret
- [ ] No Foundry/OpenAI endpoints stored anywhere else
- [ ] Apps read endpoint from Key Vault or environment variables

### ✅ Code Layer
- [ ] All `AIProjectClient` instances use APIM endpoint
- [ ] Code validates endpoint ends with `.azure-api.net`
- [ ] No hardcoded direct endpoints in codebase

### ✅ Monitoring Layer
- [ ] Alert configured for non-APIM traffic
- [ ] Azure Monitor workbook shows APIM vs direct traffic
- [ ] Weekly review process established

---

## Testing

### Test 1: Verify APIM Works

```python
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="ai-hub-project",
    endpoint="https://your-company-ai.azure-api.net"  # APIM
)

response = client.inference.get_chat_completions_client().complete(
    model="gpt-4o",
    messages=[{"role": "user", "content": "test"}]
)

print("✅ APIM access works!")
```

### Test 2: Verify Direct Access Fails

```python
# This should FAIL after you disable public access
client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="ai-hub-project",
    endpoint="https://my-foundry.api.azureml.ms"  # Direct (should fail)
)

try:
    client.inference.get_chat_completions_client().complete(
        model="gpt-4o",
        messages=[{"role": "user", "content": "test"}]
    )
    print("❌ SECURITY ISSUE: Direct access still works!")
except Exception as e:
    print(f"✅ Direct access blocked: {e}")
```

---

## Troubleshooting

### Issue: APIM Can't Reach Foundry After Disabling Public Access

**Cause**: Private endpoint not configured.

**Fix**: Add private endpoint in your Bicep (see Layer 1 above) and redeploy.

### Issue: App Returns "Forbidden" When Using APIM

**Cause**: App identity doesn't have access to APIM.

**Fix**: Client applications authenticate with an APIM subscription key, not an
Azure control-plane role. Declare the subscription under the appropriate product
in `infrastructure/bicep/apim-gateway.bicep`, then run `azd provision`.

### Issue: Developers Complain About "Too Restrictive"

**Response**: This is intentional! Show them:
1. APIM enforces per-subscription quotas
2. APIM keeps Foundry credentials away from clients
3. APIM logs requests for operations and troubleshooting
4. They can still call any model, just through the gateway

---

## References

- [APIM Gateway Setup](./setup-apim-gateway.md)
- [APIM gateway infrastructure](../../infrastructure/bicep/apim-gateway.bicep)
- [Developer Quickstart](../developer-quickstart.md)
