"""
ServiceNow Integration: Quota Increase Workflow
Handles token quota increase requests via ServiceNow REST API
"""

import os
import json
import requests
from typing import Dict, Any
from datetime import datetime


class QuotaManager:
    """
    Manages token quota increase requests via ServiceNow.
    
    Workflow:
    1. Developer requests quota increase
    2. System checks current usage vs limit
    3. Approval routing based on cost impact
    4. On approval, update APIM rate limits
    """
    
    def __init__(self, servicenow_url: str, username: str, password: str):
        self.servicenow_url = servicenow_url.rstrip('/')
        self.auth = (username, password)
        self.headers = {
            "Content-Type": "application/json",
            "Accept": "application/json"
        }
    
    def request_quota_increase(
        self,
        subscription_id: str,
        current_quota: int,
        requested_quota: int,
        justification: str,
        lob: str
    ) -> Dict[str, Any]:
        """
        Submit quota increase request to ServiceNow.
        """
        
        endpoint = f"{self.servicenow_url}/api/now/table/u_ai_quota_requests"
        
        # Calculate cost impact
        additional_tokens = requested_quota - current_quota
        cost_per_token = 0.00001  # $10 per 1M tokens (example)
        monthly_cost_increase = additional_tokens * cost_per_token
        
        payload = {
            "subscription_id": subscription_id,
            "line_of_business": lob,
            "current_quota_tokens": current_quota,
            "requested_quota_tokens": requested_quota,
            "increase_amount": additional_tokens,
            "estimated_monthly_cost_increase": monthly_cost_increase,
            "justification": justification,
            "state": "1",  # New
            "urgency": self._calculate_urgency(monthly_cost_increase),
            "short_description": f"Token Quota Increase: {subscription_id}",
            "submitted_date": datetime.utcnow().isoformat()
        }
        
        response = requests.post(
            endpoint,
            auth=self.auth,
            headers=self.headers,
            json=payload
        )
        
        response.raise_for_status()
        result = response.json()["result"]
        
        print(f"✅ Quota request created: {result['number']}")
        print(f"   Current: {current_quota:,} tokens/hour")
        print(f"   Requested: {requested_quota:,} tokens/hour")
        print(f"   Cost Impact: ${monthly_cost_increase:.2f}/month")
        print(f"   Urgency: {result['urgency']}")
        
        return result
    
    def _calculate_urgency(self, monthly_cost_increase: float) -> str:
        """Calculate approval urgency based on cost impact."""
        if monthly_cost_increase > 1000:
            return "2"  # High (requires VP approval)
        elif monthly_cost_increase > 100:
            return "3"  # Medium (requires manager approval)
        else:
            return "4"  # Low (automated approval if <$100/month)
    
    def approve_and_update_apim(
        self,
        sys_id: str,
        new_quota: int,
        approver: str
    ):
        """
        Approve quota request and update APIM rate limits.
        """
        
        # Update ServiceNow ticket
        endpoint = f"{self.servicenow_url}/api/now/table/u_ai_quota_requests/{sys_id}"
        
        payload = {
            "state": "3",  # Approved
            "approval": "approved",
            "approved_by": approver,
            "approved_date": datetime.utcnow().isoformat(),
            "work_notes": f"Approved. Updating APIM rate limit to {new_quota:,} tokens/hour"
        }
        
        response = requests.patch(
            endpoint,
            auth=self.auth,
            headers=self.headers,
            json=payload
        )
        
        response.raise_for_status()
        
        # Get subscription details
        ticket = response.json()["result"]
        subscription_id = ticket["subscription_id"]
        
        print(f"✅ Quota request approved: {ticket['number']}")
        
        # Update APIM policy
        self._update_apim_rate_limit(subscription_id, new_quota)
    
    def _update_apim_rate_limit(self, subscription_id: str, new_quota: int):
        """
        Update APIM rate limit policy for the subscription.
        
        In production, this would:
        1. Call APIM Management API to update policy
        2. Or update Azure Key Vault with new limits
        3. Or trigger Azure Function to modify policy XML
        """
        
        apim_endpoint = os.environ.get("APIM_MANAGEMENT_ENDPOINT")
        apim_key = os.environ.get("APIM_MANAGEMENT_KEY")
        
        if not apim_endpoint:
            print("⚠️ APIM endpoint not configured. Manual update required.")
            return
        
        # Example: Update product-level rate limit
        # In reality, you'd update the specific subscription policy
        
        policy_url = f"{apim_endpoint}/subscriptions/{subscription_id}/policy?api-version=2021-08-01"
        
        # Generate updated policy XML
        policy_xml = f"""
        <policies>
            <inbound>
                <rate-limit-by-key calls="{new_quota}" 
                                   renewal-period="3600" 
                                   counter-key="@(context.Subscription.Id)" />
                <base />
            </inbound>
        </policies>
        """.strip()
        
        headers = {
            "Content-Type": "application/vnd.ms-azure-apim.policy.raw+xml",
            "Authorization": f"SharedAccessSignature {apim_key}"
        }
        
        print(f"Updating APIM rate limit for {subscription_id}...")
        print(f"New limit: {new_quota:,} tokens/hour")
        
        # Uncomment for production
        # response = requests.put(policy_url, headers=headers, data=policy_xml)
        # response.raise_for_status()
        # print("✅ APIM rate limit updated")


# Example usage
if __name__ == "__main__":
    manager = QuotaManager(
        servicenow_url=os.environ["SERVICENOW_INSTANCE_URL"],
        username=os.environ["SERVICENOW_USERNAME"],
        password=os.environ["SERVICENOW_PASSWORD"]
    )
    
    # Scenario: Developer hits quota limit, requests increase
    print("Scenario: Token quota increase request")
    print("="*50)
    
    request = manager.request_quota_increase(
        subscription_id="retail-support-bot-prod",
        current_quota=100_000,  # 100K tokens/hour
        requested_quota=500_000,  # 500K tokens/hour
        justification="Black Friday traffic: 10x increase in customer queries. Need higher quota to handle load.",
        lob="retail"
    )
    
    print(f"\n✅ Request submitted: {request['number']}")
    print("Awaiting approval from LOB manager...")
    
    # Approval step (uncomment for demo)
    # print("\n" + "="*50)
    # print("Manager approves request")
    # manager.approve_and_update_apim(
    #     sys_id=request["sys_id"],
    #     new_quota=500_000,
    #     approver="manager@contoso.com"
    # )
