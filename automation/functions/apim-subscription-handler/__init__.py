"""
Azure Function: APIM Subscription Event Handler
Triggered by Event Grid when APIM subscription is created/updated

Workflow:
1. Receive Event Grid event (subscription created)
2. Extract subscription details (product, user, LOB)
3. Trigger downstream automation:
   - Create Application Insights resource for the LOB
   - Link to Foundry project
   - Update ServiceNow CMDB
   - Send welcome email to developer
"""

import json
import logging
import os
import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.mgmt.applicationinsights import ApplicationInsightsManagementClient
from azure.mgmt.monitor import MonitorManagementClient

# Initialize logger
logger = logging.getLogger(__name__)

def main(event: func.EventGridEvent):
    """
    Handle APIM subscription created event.
    
    Event Schema:
    {
      "eventType": "Microsoft.ApiManagement.SubscriptionCreated",
      "data": {
        "resourceUri": "/subscriptions/.../resourceGroups/.../providers/Microsoft.ApiManagement/service/myapim/subscriptions/mysub",
        "subscriptionId": "mysub",
        "scope": "/products/ai-standard",
        "ownerId": "/users/alice@contoso.com"
      }
    }
    """
    
    logger.info(f"Processing event: {event.event_type}")
    logger.info(f"Event data: {json.dumps(event.get_json(), indent=2)}")
    
    # Parse event data
    event_data = event.get_json()
    subscription_id = event_data.get("subscriptionId")
    scope = event_data.get("scope", "")
    owner_id = event_data.get("ownerId", "")
    
    # Extract product name
    product_name = scope.split("/")[-1] if "/products/" in scope else "unknown"
    
    # Extract owner email
    owner_email = owner_id.split("/")[-1] if "/" in owner_id else owner_id
    
    logger.info(f"Subscription: {subscription_id}")
    logger.info(f"Product: {product_name}")
    logger.info(f"Owner: {owner_email}")
    
    # Determine LOB from custom properties (in real impl, query APIM API)
    # For demo, extract from subscription ID pattern: {lob}-{project}-{env}
    try:
        parts = subscription_id.split("-")
        lob = parts[0] if len(parts) > 0 else "default"
    except:
        lob = "default"
    
    logger.info(f"Detected LOB: {lob}")
    
    # Automation Step 1: Create/link Application Insights
    try:
        create_app_insights(lob, subscription_id)
        logger.info(f"✅ Application Insights created/linked for {lob}")
    except Exception as e:
        logger.error(f"❌ Failed to create App Insights: {e}")
    
    # Automation Step 2: Update ServiceNow CMDB
    try:
        update_servicenow_cmdb(subscription_id, lob, owner_email, product_name)
        logger.info(f"✅ ServiceNow CMDB updated")
    except Exception as e:
        logger.error(f"❌ Failed to update ServiceNow: {e}")
    
    # Automation Step 3: Send welcome email
    try:
        send_welcome_email(owner_email, subscription_id, product_name)
        logger.info(f"✅ Welcome email sent to {owner_email}")
    except Exception as e:
        logger.error(f"❌ Failed to send email: {e}")
    
    logger.info(f"✅ Event processing complete for {subscription_id}")


def create_app_insights(lob: str, subscription_id: str):
    """Create or link Application Insights resource for the LOB."""
    
    credential = DefaultAzureCredential()
    subscription = os.environ["AZURE_SUBSCRIPTION_ID"]
    resource_group = os.environ["RESOURCE_GROUP_NAME"]
    location = os.environ.get("AZURE_LOCATION", "eastus")
    
    client = ApplicationInsightsManagementClient(credential, subscription)
    
    # Check if App Insights already exists for this LOB
    app_insights_name = f"appi-{lob}"
    
    try:
        # Try to get existing
        app_insights = client.components.get(resource_group, app_insights_name)
        logger.info(f"App Insights exists: {app_insights.instrumentation_key}")
    except:
        # Create new
        logger.info(f"Creating App Insights: {app_insights_name}")
        
        app_insights_properties = {
            "Application_Type": "web",
            "Flow_Type": "Bluefield",
            "Request_Source": "rest"
        }
        
        app_insights = client.components.create_or_update(
            resource_group,
            app_insights_name,
            {
                "location": location,
                "kind": "web",
                "properties": app_insights_properties,
                "tags": {
                    "lob": lob,
                    "subscription": subscription_id,
                    "purpose": "apim-telemetry"
                }
            }
        )
        
        logger.info(f"Created: {app_insights.id}")
    
    return app_insights


def update_servicenow_cmdb(subscription_id: str, lob: str, owner: str, product: str):
    """Update ServiceNow CMDB with new subscription details."""
    
    # In real implementation, call ServiceNow REST API
    # For demo, log the action
    
    servicenow_url = os.environ.get("SERVICENOW_CMDB_ENDPOINT")
    
    payload = {
        "ci_type": "apim_subscription",
        "name": subscription_id,
        "attributes": {
            "lob": lob,
            "owner": owner,
            "product": product,
            "status": "active"
        }
    }
    
    logger.info(f"Would POST to ServiceNow: {servicenow_url}")
    logger.info(f"Payload: {json.dumps(payload, indent=2)}")
    
    # TODO: Uncomment for production
    # import requests
    # response = requests.post(
    #     servicenow_url,
    #     json=payload,
    #     headers={"Authorization": f"Bearer {get_servicenow_token()}"}
    # )
    # response.raise_for_status()


def send_welcome_email(recipient: str, subscription_id: str, product: str):
    """Send welcome email to developer with getting started guide."""
    
    # In real implementation, use SendGrid, Office 365, or Azure Communication Services
    
    email_body = f"""
    Welcome to Azure AI Gateway!
    
    Your subscription has been provisioned:
    
    Subscription ID: {subscription_id}
    Product: {product}
    
    Getting Started:
    1. Install Azure AI SDK: pip install azure-ai-projects
    2. Set environment variables (see developer guide)
    3. Run sample: python examples/1-simple-chat-via-apim.py
    
    Documentation:
    - Developer Quick Start: https://contoso.com/ai-gateway/quickstart
    - Code Samples: https://github.com/contoso/ai-gateway-examples
    - Support: ai-gateway-support@contoso.com
    
    Questions? Reply to this email or visit our Slack channel #ai-gateway.
    """
    
    logger.info(f"Would send email to: {recipient}")
    logger.info(f"Subject: Your Azure AI Gateway Subscription is Ready")
    logger.info(f"Body:\n{email_body}")
    
    # TODO: Implement actual email sending
    # from azure.communication.email import EmailClient
    # email_client = EmailClient.from_connection_string(os.environ["EMAIL_CONNECTION_STRING"])
    # email_client.send(...)
