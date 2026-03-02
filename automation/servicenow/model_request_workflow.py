"""
ServiceNow Integration: Model Request Workflow
Demonstrates REST API calls to ServiceNow for AI model request approvals

Workflow:
1. Developer submits model request via form
2. ServiceNow creates incident/request ticket
3. Approval routing to AI governance team
4. On approval, trigger Azure automation (APIM subscription, RBAC)
"""

import os
import json
import requests
from typing import Dict, Any, Optional

class ServiceNowClient:
    """
    Client for ServiceNow REST API integration.
    
    Prerequisites:
    - ServiceNow instance URL
    - OAuth 2.0 credentials or basic auth
    - Custom tables: u_ai_model_requests, u_ai_quota_requests
    """
    
    def __init__(self, instance_url: str, username: str, password: str):
        self.instance_url = instance_url.rstrip('/')
        self.auth = (username, password)
        self.headers = {
            "Content-Type": "application/json",
            "Accept": "application/json"
        }
    
    def create_model_request(
        self,
        requester_email: str,
        model_name: str,
        use_case: str,
        lob: str,
        project_name: str,
        estimated_monthly_tokens: int
    ) -> Dict[str, Any]:
        """
        Create a new AI model request in ServiceNow.
        
        Returns: ServiceNow ticket details including sys_id
        """
        
        endpoint = f"{self.instance_url}/api/now/table/u_ai_model_requests"
        
        payload = {
            "requester": requester_email,
            "model_name": model_name,
            "use_case": use_case,
            "line_of_business": lob,
            "project_name": project_name,
            "estimated_monthly_tokens": estimated_monthly_tokens,
            "state": "1",  # New
            "urgency": "3",  # Low (unless production)
            "short_description": f"AI Model Request: {model_name} for {project_name}",
            "description": f"""
AI Model Access Request

Requester: {requester_email}
LOB: {lob}
Project: {project_name}

Model: {model_name}
Use Case: {use_case}
Estimated Usage: {estimated_monthly_tokens:,} tokens/month

Please review and approve if use case is valid and budget approved.
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
        
        print(f"✅ Request created: {result['number']}")
        print(f"   Sys ID: {result['sys_id']}")
        print(f"   State: {result['state']}")
        
        return result
    
    def get_request_status(self, sys_id: str) -> Dict[str, Any]:
        """Check status of an AI model request."""
        
        endpoint = f"{self.instance_url}/api/now/table/u_ai_model_requests/{sys_id}"
        
        response = requests.get(
            endpoint,
            auth=self.auth,
            headers=self.headers
        )
        
        response.raise_for_status()
        result = response.json()["result"]
        
        return {
            "number": result["number"],
            "state": result["state"],
            "approval_state": result.get("approval", "not_requested"),
            "sys_id": result["sys_id"]
        }
    
    def approve_request(self, sys_id: str, approver_comments: str) -> Dict[str, Any]:
        """
        Approve an AI model request (typically called by governance team).
        Triggers downstream automation.
        """
        
        endpoint = f"{self.instance_url}/api/now/table/u_ai_model_requests/{sys_id}"
        
        payload = {
            "state": "3",  # Approved
            "approval": "approved",
            "comments": approver_comments,
            "work_notes": f"Approved by governance team. Triggering Azure automation..."
        }
        
        response = requests.patch(
            endpoint,
            auth=self.auth,
            headers=self.headers,
            json=payload
        )
        
        response.raise_for_status()
        result = response.json()["result"]
        
        print(f"✅ Request approved: {result['number']}")
        
        # Trigger Azure automation via Business Rules / Flow Designer
        self._trigger_apim_provisioning(result)
        
        return result
    
    def _trigger_apim_provisioning(self, request_data: Dict[str, Any]):
        """
        Trigger APIM subscription creation via REST API.
        Called automatically after approval.
        """
        
        apim_endpoint = os.environ.get("APIM_MANAGEMENT_ENDPOINT")
        apim_key = os.environ.get("APIM_MANAGEMENT_KEY")
        
        if not apim_endpoint or not apim_key:
            print("⚠️ APIM credentials not configured. Skipping provisioning.")
            return
        
        # Extract request details
        lob = request_data.get("line_of_business")
        project = request_data.get("project_name")
        requester = request_data.get("requester")
        
        subscription_id = f"{lob}-{project}-prod".lower().replace(" ", "-")
        
        # Create APIM subscription
        apim_url = f"{apim_endpoint}/subscriptions/{subscription_id}?api-version=2021-08-01"
        
        apim_payload = {
            "properties": {
                "displayName": f"{lob} - {project}",
                "scope": "/products/ai-standard",  # Or ai-premium based on request
                "ownerId": f"/users/{requester}",
                "state": "active"
            }
        }
        
        apim_headers = {
            "Content-Type": "application/json",
            "Authorization": f"SharedAccessSignature {apim_key}"
        }
        
        print(f"Creating APIM subscription: {subscription_id}")
        
        response = requests.put(
            apim_url,
            headers=apim_headers,
            json=apim_payload
        )
        
        if response.status_code in [200, 201]:
            print(f"✅ APIM subscription created: {subscription_id}")
            
            # Update ServiceNow ticket with provisioning details
            self._update_provisioning_status(
                request_data["sys_id"],
                subscription_id,
                "provisioned"
            )
        else:
            print(f"❌ APIM provisioning failed: {response.text}")
            self._update_provisioning_status(
                request_data["sys_id"],
                subscription_id,
                "failed"
            )
    
    def _update_provisioning_status(self, sys_id: str, subscription_id: str, status: str):
        """Update ServiceNow ticket with provisioning results."""
        
        endpoint = f"{self.instance_url}/api/now/table/u_ai_model_requests/{sys_id}"
        
        payload = {
            "state": "4" if status == "provisioned" else "7",  # Closed or Failed
            "apim_subscription_id": subscription_id,
            "provisioning_status": status,
            "work_notes": f"APIM subscription {subscription_id} {status}"
        }
        
        requests.patch(
            endpoint,
            auth=self.auth,
            headers=self.headers,
            json=payload
        )


# Example usage
if __name__ == "__main__":
    # Initialize client (use OAuth in production)
    client = ServiceNowClient(
        instance_url=os.environ["SERVICENOW_INSTANCE_URL"],  # https://contoso.service-now.com
        username=os.environ["SERVICENOW_USERNAME"],
        password=os.environ["SERVICENOW_PASSWORD"]
    )
    
    # Workflow 1: Developer submits request
    print("Step 1: Developer submits model request")
    request = client.create_model_request(
        requester_email="alice@contoso.com",
        model_name="gpt-4o",
        use_case="Customer support chatbot for e-commerce",
        lob="retail",
        project_name="support-bot",
        estimated_monthly_tokens=5_000_000
    )
    
    sys_id = request["sys_id"]
    print(f"\nRequest ID: {request['number']}")
    print(f"Status: Pending Approval")
    
    # Workflow 2: Check status
    print("\n" + "="*50)
    print("Step 2: Check request status")
    status = client.get_request_status(sys_id)
    print(json.dumps(status, indent=2))
    
    # Workflow 3: Governance team approves (uncomment for demo)
    # print("\n" + "="*50)
    # print("Step 3: Governance team approves")
    # approved = client.approve_request(
    #     sys_id=sys_id,
    #     approver_comments="Approved. Use case aligns with company AI policy."
    # )
    # print("✅ Request approved and APIM subscription provisioned")
