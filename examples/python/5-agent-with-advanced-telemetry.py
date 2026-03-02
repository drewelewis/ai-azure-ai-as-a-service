"""
Pattern F: Agent with Tools + Advanced Telemetry
Shows distributed tracing across agent calls, tool executions, and nested spans
"""

import os
import json
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import FunctionTool
from azure.identity import DefaultAzureCredential
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry import trace, metrics
from opentelemetry.trace import Status, StatusCode

# Configure Application Insights
configure_azure_monitor(
    connection_string=os.environ["APPLICATIONINSIGHTS_CONNECTION_STRING"]
)

tracer = trace.get_tracer(__name__)
meter = metrics.get_meter(__name__)

# Custom metrics
tool_execution_counter = meter.create_counter(
    name="agent.tool_executions",
    description="Number of tool executions",
    unit="1"
)

token_usage_counter = meter.create_counter(
    name="agent.tokens_used",
    description="Total tokens consumed",
    unit="tokens"
)


def get_weather(location: str) -> str:
    """Simulated weather tool (instrumented)"""
    with tracer.start_as_current_span("tool.get_weather") as span:
        span.set_attribute("tool.name", "get_weather")
        span.set_attribute("tool.location", location)
        
        # Simulate API call
        result = f"Weather in {location}: 72°F, sunny"
        
        span.set_attribute("tool.result", result)
        tool_execution_counter.add(1, {"tool": "get_weather", "status": "success"})
        
        return result


def get_flight_price(origin: str, destination: str) -> str:
    """Simulated flight price tool (instrumented)"""
    with tracer.start_as_current_span("tool.get_flight_price") as span:
        span.set_attribute("tool.name", "get_flight_price")
        span.set_attribute("tool.origin", origin)
        span.set_attribute("tool.destination", destination)
        
        # Simulate pricing API
        result = f"Flight from {origin} to {destination}: $450"
        
        span.set_attribute("tool.result", result)
        tool_execution_counter.add(1, {"tool": "get_flight_price", "status": "success"})
        
        return result


def run_agent_with_telemetry(user_query: str):
    """
    Run an agent with tool calling, full telemetry, and distributed tracing.
    
    Telemetry captured:
    - Agent creation (once)
    - Thread creation (once)
    - Each run iteration (multiple if tool calls needed)
    - Each tool execution (nested spans)
    - Token usage per run
    - Total cost estimate
    """
    
    with tracer.start_as_current_span("agent_workflow") as workflow_span:
        workflow_span.set_attribute("user_query", user_query)
        
        # Initialize client
        client = AIProjectClient.from_connection_string(
            credential=DefaultAzureCredential(),
            conn_str=os.environ["AIPROJECT_CONNECTION_STRING"]
        )
        
        # Define tools
        tools = [
            FunctionTool(
                name="get_weather",
                description="Get current weather for a location",
                parameters={
                    "type": "object",
                    "properties": {
                        "location": {"type": "string", "description": "City name"}
                    },
                    "required": ["location"]
                }
            ),
            FunctionTool(
                name="get_flight_price",
                description="Get flight price between two cities",
                parameters={
                    "type": "object",
                    "properties": {
                        "origin": {"type": "string"},
                        "destination": {"type": "string"}
                    },
                    "required": ["origin", "destination"]
                }
            )
        ]
        
        # Create agent (traced)
        with tracer.start_as_current_span("agent.create") as span:
            agent = client.agents.create_agent(
                model="gpt-4o",
                name="travel-assistant",
                instructions="Help users plan trips. Use tools to check weather and flight prices.",
                tools=tools
            )
            span.set_attribute("agent.id", agent.id)
            span.set_attribute("agent.model", "gpt-4o")
        
        # Create thread (traced)
        with tracer.start_as_current_span("thread.create") as span:
            thread = client.agents.create_thread()
            span.set_attribute("thread.id", thread.id)
        
        # Add message
        with tracer.start_as_current_span("message.create") as span:
            client.agents.create_message(
                thread_id=thread.id,
                role="user",
                content=user_query
            )
            span.set_attribute("message.content", user_query)
        
        # Run agent
        with tracer.start_as_current_span("agent.run") as run_span:
            run = client.agents.create_run(thread_id=thread.id, agent_id=agent.id)
            run_span.set_attribute("run.id", run.id)
            
            total_tokens = 0
            tool_calls_count = 0
            
            # Poll for completion
            while run.status in ["queued", "in_progress", "requires_action"]:
                run = client.agents.get_run(thread_id=thread.id, run_id=run.id)
                
                if run.status == "requires_action":
                    tool_calls_count += 1
                    
                    with tracer.start_as_current_span("tools.execute_batch") as tools_span:
                        tool_outputs = []
                        
                        for tool_call in run.required_action.submit_tool_outputs.tool_calls:
                            # Parse arguments
                            args = json.loads(tool_call.function.arguments)
                            
                            # Execute tool (creates nested span)
                            if tool_call.function.name == "get_weather":
                                output = get_weather(args["location"])
                            elif tool_call.function.name == "get_flight_price":
                                output = get_flight_price(args["origin"], args["destination"])
                            else:
                                output = f"Unknown tool: {tool_call.function.name}"
                            
                            tool_outputs.append({
                                "tool_call_id": tool_call.id,
                                "output": output
                            })
                        
                        tools_span.set_attribute("tools.count", len(tool_outputs))
                        
                        # Submit tool outputs
                        run = client.agents.submit_tool_outputs(
                            thread_id=thread.id,
                            run_id=run.id,
                            tool_outputs=tool_outputs
                        )
            
            # Get final messages
            messages = client.agents.list_messages(thread_id=thread.id)
            final_response = messages.data[0].content[0].text.value
            
            # Record metrics
            run_span.set_attribute("run.status", run.status)
            run_span.set_attribute("run.tool_calls", tool_calls_count)
            run_span.set_attribute("response.length", len(final_response))
            
            if run.usage:
                total_tokens = run.usage.total_tokens
                run_span.set_attribute("run.tokens", total_tokens)
                token_usage_counter.add(total_tokens, {"agent": agent.id})
            
            workflow_span.set_attribute("workflow.status", "completed")
            workflow_span.set_status(Status(StatusCode.OK))
            
            return final_response


if __name__ == "__main__":
    print("Running agent with full telemetry...\n")
    
    query = "I'm planning a trip from Seattle to Miami. What's the weather in Miami and how much are flights?"
    
    response = run_agent_with_telemetry(query)
    
    print(f"\nAgent Response:\n{response}")
    print("\n✅ Telemetry sent to Application Insights!")
    print("\nView distributed traces:")
    print("  • Application Map: See agent → tool call relationships")
    print("  • Transaction search: Find slow tool executions")
    print("  • Custom metrics: agent.tool_executions, agent.tokens_used")
