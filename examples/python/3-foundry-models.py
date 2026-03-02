"""
Example 3: Use Foundry Models (Not Just OpenAI)
================================================

One of the key benefits of Foundry: access to 1900+ models.
Switch between GPT-4o, Llama, Claude, etc. without code changes.

Your IT manager deploys models to Foundry. You just use them.
"""

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

PROJECT_ID = "my-hub-project"
APIM_GATEWAY_URL = "https://your-company-ai.azure-api.net"

def compare_models():
    """Compare responses from different models."""
    
    credential = DefaultAzureCredential()
    client = AIProjectClient(
        credential=credential,
        project_id=PROJECT_ID,
        endpoint=APIM_GATEWAY_URL
    )
    
    chat_client = client.inference.get_chat_completions_client()
    
    # List of models available in your Foundry project
    models = [
        "gpt-4o",                    # OpenAI (Microsoft-hosted)
        "meta-llama-3.1-405b",       # Meta's Llama (partner-hosted)
        "mistral-large",             # Mistral AI
        # "claude-opus-4" would be here if your org has approved it
    ]
    
    question = "Explain quantum computing in 2 sentences."
    
    print(f"Question: {question}\n")
    print("=" * 70)
    
    for model in models:
        try:
            response = chat_client.complete(
                model=model,
                messages=[{"role": "user", "content": question}]
            )
            
            answer = response.choices[0].message.content
            tokens = response.usage.total_tokens
            
            print(f"\n{model}:")
            print(f"  Answer: {answer}")
            print(f"  Tokens: {tokens}")
            print("  " + "-" * 60)
            
        except Exception as e:
            print(f"\n{model}:")
            print(f"  ❌ Error: {str(e)}")
            print("  (This model may not be deployed yet. Ask IT.)")
            print("  " + "-" * 60)

def switch_models_for_cost():
    """Example: Switch to cheaper model for simple tasks."""
    
    credential = DefaultAzureCredential()
    client = AIProjectClient(
        credential=credential,
        project_id=PROJECT_ID,
        endpoint=APIM_GATEWAY_URL
    )
    
    chat_client = client.inference.get_chat_completions_client()
    
    # Simple task → use cheaper model
    if is_simple_task("What's the weather?"):
        model = "meta-llama-3.1-70b"  # Cheaper
        print("Using budget model (Llama 3.1) for simple task")
    else:
        model = "gpt-4o"  # More capable
        print("Using premium model (GPT-4o) for complex task")
    
    response = chat_client.complete(
        model=model,
        messages=[{"role": "user", "content": "What's the weather?"}]
    )
    
    print(f"Response: {response.choices[0].message.content}")

def is_simple_task(query: str) -> bool:
    """Heuristic: is this a simple query?"""
    return len(query) < 50 and any(
        word in query.lower() 
        for word in ["weather", "time", "what is", "who is"]
    )

if __name__ == "__main__":
    print("Example: Compare Models\n")
    compare_models()
