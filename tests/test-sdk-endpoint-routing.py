"""
CRITICAL TEST: Verify AIProjectClient Routes ALL Traffic Through APIM
======================================================================

This test uses HTTP mocking to capture every URL the SDK calls.
If ANY request goes to *.api.azureml.ms instead of your APIM URL,
you have a bypass!

Run this BEFORE deploying to production.
"""

import os
from unittest.mock import patch, MagicMock
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
import urllib.parse


# Track all HTTP requests
captured_urls = []


def mock_request(*args, **kwargs):
    """Capture the URL of every HTTP request."""
    url = args[0] if args else kwargs.get('url', '')
    captured_urls.append(url)
    
    # Return a mock response
    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.json.return_value = {
        "id": "test-123",
        "status": "completed"
    }
    return mock_response


def test_all_operations_use_apim_endpoint():
    """
    Test that create_agent, create_thread, create_run, etc.
    ALL use the APIM endpoint and don't bypass it.
    """
    apim_endpoint = "https://your-company-ai.azure-api.net"
    project_id = "test-project"
    
    global captured_urls
    captured_urls = []
    
    # Patch HTTP library (requests/aiohttp/httpx depending on SDK)
    with patch('requests.Session.request', side_effect=mock_request), \
         patch('aiohttp.ClientSession.request', side_effect=mock_request), \
         patch('httpx.Client.request', side_effect=mock_request):
        
        try:
            client = AIProjectClient(
                credential=DefaultAzureCredential(),
                project_id=project_id,
                endpoint=apim_endpoint
            )
            
            # Test operations
            print("\n🔍 Testing SDK Operations...")
            
            # 1. Create agent
            print("   Testing: create_agent")
            try:
                client.agents.create_agent(
                    model="gpt-4o",
                    name="test-agent",
                    instructions="test"
                )
            except Exception as e:
                print(f"      (Expected error: {type(e).__name__})")
            
            # 2. Create thread
            print("   Testing: create_thread")
            try:
                client.agents.create_thread()
            except Exception as e:
                print(f"      (Expected error: {type(e).__name__})")
            
            # 3. Inference call
            print("   Testing: inference.get_chat_completions_client")
            try:
                chat_client = client.inference.get_chat_completions_client()
                chat_client.complete(
                    model="gpt-4o",
                    messages=[{"role": "user", "content": "test"}]
                )
            except Exception as e:
                print(f"      (Expected error: {type(e).__name__})")
            
        except Exception as e:
            print(f"\n❌ Error during test: {e}")
    
    # Analyze captured URLs
    print(f"\n📊 Analysis of {len(captured_urls)} HTTP Requests:")
    print("=" * 70)
    
    apim_requests = []
    bypass_requests = []
    
    for url in captured_urls:
        parsed = urllib.parse.urlparse(url)
        print(f"   • {parsed.scheme}://{parsed.netloc}{parsed.path[:50]}")
        
        if apim_endpoint in url:
            apim_requests.append(url)
        elif "api.azureml.ms" in url or "cognitiveservices.azure.com" in url:
            bypass_requests.append(url)
    
    print("\n" + "=" * 70)
    print(f"✅ Requests through APIM: {len(apim_requests)}")
    print(f"❌ Requests BYPASSING APIM: {len(bypass_requests)}")
    
    if bypass_requests:
        print("\n⚠️  CRITICAL SECURITY ISSUE DETECTED!")
        print("   The following requests bypassed your APIM gateway:")
        for url in bypass_requests:
            print(f"   • {url}")
        print("\n   This means:")
        print("   - Token quotas are NOT enforced")
        print("   - Semantic caching is NOT applied")
        print("   - Audit logs are INCOMPLETE")
        return False
    else:
        print("\n✅ All requests properly routed through APIM")
        return True


def alternative_test_with_network_capture():
    """
    Alternative: Run actual SDK calls with network capture.
    Use Fiddler, Charles Proxy, or mitmproxy to intercept traffic.
    """
    print("\n" + "=" * 70)
    print("📡 ALTERNATIVE TEST: Network Traffic Capture")
    print("=" * 70)
    print("""
To verify endpoint routing with real network traffic:

1. Install mitmproxy:
   pip install mitmproxy

2. Start proxy:
   mitmproxy --port 8080

3. Set environment:
   export HTTPS_PROXY=http://localhost:8080
   export HTTP_PROXY=http://localhost:8080

4. Run your agent code:
   python examples/python/6-foundry-agent-via-apim.py

5. Check mitmproxy logs:
   - ALL requests should go to: your-company-ai.azure-api.net
   - ZERO requests should go to: *.api.azureml.ms

If you see direct azureml.ms requests, the SDK is bypassing APIM!
""")


if __name__ == "__main__":
    print("=" * 70)
    print("CRITICAL TEST: SDK Endpoint Routing Verification")
    print("=" * 70)
    
    result = test_all_operations_use_apim_endpoint()
    
    if not result:
        print("\n❌ TEST FAILED: SDK bypasses APIM for some operations")
        print("   ACTION REQUIRED: Review SDK source code or contact Microsoft")
    
    alternative_test_with_network_capture()
    
    print("\n" + "=" * 70)
    print("RECOMMENDATION:")
    print("=" * 70)
    print("""
1. Run this test in your dev environment
2. Use network capture (mitmproxy) for real verification
3. Check azure-ai-projects SDK source code on GitHub:
   https://github.com/Azure/azure-sdk-for-python/tree/main/sdk/ai/azure-ai-projects
4. Contact Microsoft support to confirm endpoint behavior
5. Consider API Gateway at network level (not just SDK parameter)
""")
