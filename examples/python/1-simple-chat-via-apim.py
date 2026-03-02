"""
Example 1: Simple Chat via APIM Gateway
=========================================

This is the simplest possible example. Developers just need:
1. Azure AI project ID (provided by IT)
2. APIM gateway URL (provided by IT)
3. Their corporate identity (they already have it!)

No API keys to manage. No direct Azure OpenAI endpoints. Just simple, governed AI.
"""

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

# Configuration (your IT manager provides these)
PROJECT_ID = "my-hub-project"  # Ask IT for your project ID
APIM_GATEWAY_URL = "https://your-company-ai.azure-api.net"

def simple_chat():
    """Ask a simple question."""
    
    # 1. Authenticate using corporate identity
    credential = DefaultAzureCredential()
    
    # 2. Create client pointing to your APIM gateway (NOT direct Azure OpenAI)
    client = AIProjectClient(
        credential=credential,
        project_id=PROJECT_ID,
        endpoint=APIM_GATEWAY_URL
    )
    
    # 3. Get the inference client
    chat_client = client.inference.get_chat_completions_client()
    
    # 4. Send a message
    response = chat_client.complete(
        model="gpt-4o",  # Any model available in your Foundry project
        messages=[
            {"role": "user", "content": "What is the capital of France?"}
        ]
    )
    
    # 5. Print the response
    print(f"Response: {response.choices[0].message.content}")
    print(f"Tokens used: {response.usage.total_tokens}")

if __name__ == "__main__":
    simple_chat()
