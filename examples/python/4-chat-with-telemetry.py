"""
Pattern E: Simple Chat with Application Insights Telemetry
Shows how to enable tracing for all agent operations via App Insights
"""

import os
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode

# Configure Application Insights (auto-instruments HTTP, Azure SDK calls)
configure_azure_monitor(
    connection_string=os.environ["APPLICATIONINSIGHTS_CONNECTION_STRING"]
)

# Get a tracer for custom spans
tracer = trace.get_tracer(__name__)

def chat_with_telemetry(user_message: str) -> str:
    """
    Send a chat message and trace the operation in App Insights.
    
    This creates a custom span that will appear in App Insights:
    - Operation name: chat_with_telemetry
    - Custom properties: user_message, model
    - Automatic child spans: HTTP calls to APIM, token counts
    """
    
    with tracer.start_as_current_span("chat_with_telemetry") as span:
        # Add custom attributes to the span
        span.set_attribute("user_message", user_message)
        span.set_attribute("model", "gpt-4o")
        span.set_attribute("team", "marketing")
        
        try:
            # Initialize client (APIM gateway URL from IT)
            client = AIProjectClient.from_connection_string(
                credential=DefaultAzureCredential(),
                conn_str=os.environ["AIPROJECT_CONNECTION_STRING"]
            )
            
            # Send message - HTTP calls are auto-traced
            response = client.inference.get_chat_completions(
                model="gpt-4o",
                messages=[
                    {"role": "system", "content": "You are a helpful assistant."},
                    {"role": "user", "content": user_message}
                ]
            )
            
            # Extract response
            reply = response.choices[0].message.content
            
            # Add result attributes
            span.set_attribute("response_length", len(reply))
            span.set_attribute("tokens_used", response.usage.total_tokens)
            span.set_attribute("cost_estimate_usd", response.usage.total_tokens * 0.00001)
            span.set_status(Status(StatusCode.OK))
            
            return reply
            
        except Exception as e:
            # Log error to App Insights
            span.set_status(Status(StatusCode.ERROR, str(e)))
            span.record_exception(e)
            raise

if __name__ == "__main__":
    # Must set environment variables:
    # APPLICATIONINSIGHTS_CONNECTION_STRING (from IT)
    # AIPROJECT_CONNECTION_STRING (from IT)
    
    print("Sending chat request with telemetry enabled...")
    
    response = chat_with_telemetry("What are three benefits of Azure API Management?")
    print(f"\nResponse: {response}")
    
    print("\n✅ Telemetry sent to Application Insights!")
    print("View traces in:")
    print("  1. Azure Portal: Application Insights → Transaction search")
    print("  2. VS Code: Azure Extension → Application Insights")
    print("  3. Managed Grafana: Explore → Azure Monitor datasource")
