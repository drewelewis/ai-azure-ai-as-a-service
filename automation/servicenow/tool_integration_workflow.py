"""
ServiceNow Integration: Tool Integration Request Workflow
Handles requests for custom tool access in AI agents
"""

import os
import json
import requests
from typing import Dict, Any, List


class ToolIntegrationManager:
    """
    Manages tool integration requests via ServiceNow.
    
    Tools = External APIs/databases agents can call (e.g., CRM, ERP, custom APIs)
    
    Workflow:
    1. Developer requests tool integration
    2. Security review for data access
    3. IT provisions credentials/API keys
    4. Tool definition added to Azure AI Foundry
    """
    
    def __init__(self, servicenow_url: str, username: str, password: str):
        self.servicenow_url = servicenow_url.rstrip('/')
        self.auth = (username, password)
        self.headers = {
            "Content-Type": "application/json",
            "Accept": "application/json"
        }
    
    def request_tool_integration(
        self,
        requester_email: str,
        tool_name: str,
        tool_type: str,  # "rest_api", "database", "azure_service", "third_party"
        tool_endpoint: str,
        data_classification: str,  # "public", "internal", "confidential", "restricted"
        use_case: str,
        required_permissions: List[str],
        project_name: str,
        lob: str
    ) -> Dict[str, Any]:
        """
        Submit tool integration request to ServiceNow.
        """
        
        endpoint = f"{self.servicenow_url}/api/now/table/u_ai_tool_requests"
        
        payload = {
            "requester": requester_email,
            "tool_name": tool_name,
            "tool_type": tool_type,
            "tool_endpoint": tool_endpoint,
            "data_classification": data_classification,
            "use_case": use_case,
            "required_permissions": ", ".join(required_permissions),
            "project_name": project_name,
            "line_of_business": lob,
            "state": "1",  # New
            "security_review_required": "yes" if data_classification in ["confidential", "restricted"] else "no",
            "short_description": f"AI Tool Integration: {tool_name}",
            "description": f"""
Tool Integration Request

Requester: {requester_email}
Project: {project_name} ({lob})

Tool Details:
- Name: {tool_name}
- Type: {tool_type}
- Endpoint: {tool_endpoint}
- Data Classification: {data_classification}

Use Case:
{use_case}

Required Permissions:
{chr(10).join('• ' + p for p in required_permissions)}

Security Review: {"REQUIRED" if data_classification in ["confidential", "restricted"] else "NOT REQUIRED"}
            """.strip()
        }
        
        response = requests.post(
            endpoint,
            auth=self.auth,
            headers=self.headers,
            json=payload
        )
        
        response.raise_for_status()
        result = response.json()["result"]
        
        print(f"✅ Tool request created: {result['number']}")
        print(f"   Tool: {tool_name}")
        print(f"   Type: {tool_type}")
        print(f"   Data Classification: {data_classification}")
        print(f"   Security Review: {result['security_review_required']}")
        
        return result
    
    def approve_and_provision(
        self,
        sys_id: str,
        approver: str
    ):
        """
        Approve tool request and provision credentials.
        
        Steps:
        1. Create Azure Key Vault secret for tool credentials
        2. Grant project managed identity access to secret
        3. Add tool definition to Foundry project
        4. Notify developer with tool schema
        """
        
        # Update ServiceNow ticket
        endpoint = f"{self.servicenow_url}/api/now/table/u_ai_tool_requests/{sys_id}"
        
        payload = {
            "state": "3",  # Approved
            "approval": "approved",
            "approved_by": approver,
            "work_notes": "Approved. Provisioning tool access..."
        }
        
        response = requests.patch(
            endpoint,
            auth=self.auth,
            headers=self.headers,
            json=payload
        )
        
        response.raise_for_status()
        
        ticket = response.json()["result"]
        
        print(f"✅ Tool request approved: {ticket['number']}")
        
        # Provision tool access
        self._provision_tool_access(ticket)
    
    def _provision_tool_access(self, ticket: Dict[str, Any]):
        """
        Provision tool access via Azure automation.
        
        In production, this would:
        1. Store API keys in Azure Key Vault
        2. Grant project MI Key Vault Secrets User role
        3. Register tool in AI Foundry catalog
        4. Generate Python/C# code sample
        """
        
        tool_name = ticket["tool_name"]
        tool_endpoint = ticket["tool_endpoint"]
        project_name = ticket["project_name"]
        
        print(f"\nProvisioning tool: {tool_name}")
        print(f"1. Creating Key Vault secret: kv-{project_name}/tool-{tool_name}-key")
        print(f"2. Granting project MI access to Key Vault")
        print(f"3. Registering tool in Foundry catalog")
        
        # Generate tool definition for developer
        tool_definition = {
            "name": tool_name,
            "description": ticket["use_case"],
            "type": "function",
            "function": {
                "name": tool_name.lower().replace(" ", "_"),
                "description": ticket["use_case"],
                "parameters": {
                    "type": "object",
                    "properties": {
                        # Developer fills this in based on API
                    }
                }
            },
            "authentication": {
                "type": "key_vault_secret",
                "secret_name": f"tool-{tool_name.lower().replace(' ', '-')}-key"
            }
        }
        
        print(f"\n4. Tool definition generated:")
        print(json.dumps(tool_definition, indent=2))
        
        # Update ticket with provisioning details
        endpoint = f"{self.servicenow_url}/api/now/table/u_ai_tool_requests/{ticket['sys_id']}"
        
        update_payload = {
            "state": "4",  # Provisioned
            "tool_definition_json": json.dumps(tool_definition),
            "key_vault_secret_name": f"tool-{tool_name.lower().replace(' ', '-')}-key",
            "work_notes": "Tool provisioned. Developer notified."
        }
        
        requests.patch(
            endpoint,
            auth=self.auth,
            headers=self.headers,
            json=update_payload
        )
        
        print(f"✅ Tool provisioning complete")


# Example usage
if __name__ == "__main__":
    manager = ToolIntegrationManager(
        servicenow_url=os.environ["SERVICENOW_INSTANCE_URL"],
        username=os.environ["SERVICENOW_USERNAME"],
        password=os.environ["SERVICENOW_PASSWORD"]
    )
    
    # Scenario: Developer needs CRM access for agent
    print("Scenario: CRM integration for sales agent")
    print("="*50)
    
    request = manager.request_tool_integration(
        requester_email="alice@contoso.com",
        tool_name="Salesforce Lead Lookup",
        tool_type="rest_api",
        tool_endpoint="https://contoso.salesforce.com/services/data/v57.0",
        data_classification="confidential",  # Triggers security review
        use_case="Sales agent needs to look up lead information to provide personalized responses",
        required_permissions=[
            "Read access to Lead objects",
            "Read access to Contact objects",
            "No write/delete permissions"
        ],
        project_name="sales-assistant",
        lob="sales"
    )
    
    print(f"\n✅ Request submitted: {request['number']}")
    print("Routed to: Security team (confidential data classification)")
    
    # Approval step (uncomment for demo)
    # print("\n" + "="*50)
    # print("Security team approves after review")
    # manager.approve_and_provision(
    #     sys_id=request["sys_id"],
    #     approver="security@contoso.com"
    # )
