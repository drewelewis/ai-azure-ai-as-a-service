/*
 * Pattern E: Simple Chat with Application Insights Telemetry
 * Shows how to enable tracing for all operations via App Insights
 */

using Azure.AI.Projects;
using Azure.Core.Diagnostics;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using OpenTelemetry;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using System.Diagnostics;

var builder = Host.CreateApplicationBuilder(args);

// Configure Application Insights via OpenTelemetry
builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource.AddService("AIGatewayClient"))
    .WithTracing(tracing => tracing
        .AddSource("Azure.*")
        .AddSource("AIGatewayClient")
        .AddAzureMonitorTraceExporter(options =>
        {
            options.ConnectionString = Environment.GetEnvironmentVariable("APPLICATIONINSIGHTS_CONNECTION_STRING");
        })
    );

// Configure Azure SDK logging
using AzureEventSourceListener listener = AzureEventSourceListener.CreateConsoleLogger(EventLevel.Informational);

var host = builder.Build();

// Get tracer for custom spans
var tracerProvider = host.Services.GetRequiredService<TracerProvider>();
var activitySource = new ActivitySource("AIGatewayClient");

using var activity = activitySource.StartActivity("ChatWithTelemetry", ActivityKind.Client);
activity?.SetTag("user.message", "What are three benefits of Azure API Management?");
activity?.SetTag("model", "gpt-4o");
activity?.SetTag("team", "engineering");

try
{
    // Initialize AIProjectClient (APIM gateway URL from IT)
    var connectionString = Environment.GetEnvironmentVariable("AIPROJECT_CONNECTION_STRING");
    var projectClient = new AIProjectClient(connectionString, new DefaultAzureCredential());
    
    // Get chat client
    var chatClient = projectClient.GetChatClient();
    
    // Create chat completion request
    var chatMessages = new ChatMessage[]
    {
        new SystemChatMessage("You are a helpful assistant."),
        new UserChatMessage("What are three benefits of Azure API Management?")
    };
    
    // Send request (auto-instrumented)
    var response = await chatClient.CompleteChatAsync(chatMessages, new ChatCompletionOptions
    {
        Model = "gpt-4o"
    });
    
    // Extract response
    var reply = response.Value.Content[0].Text;
    var tokensUsed = response.Value.Usage.TotalTokens;
    var costEstimate = tokensUsed * 0.00001;
    
    // Add result attributes
    activity?.SetTag("response.length", reply.Length);
    activity?.SetTag("tokens.used", tokensUsed);
    activity?.SetTag("cost.estimate_usd", costEstimate);
    activity?.SetStatus(ActivityStatusCode.Ok);
    
    Console.WriteLine($"Response: {reply}");
    Console.WriteLine($"\nTokens used: {tokensUsed}");
    Console.WriteLine($"Cost estimate: ${costEstimate:F5}");
    
    Console.WriteLine("\n✅ Telemetry sent to Application Insights!");
    Console.WriteLine("View traces in:");
    Console.WriteLine("  1. Azure Portal: Application Insights → Transaction search");
    Console.WriteLine("  2. VS Code: Azure Extension → Application Insights");
    Console.WriteLine("  3. Managed Grafana: Explore → Azure Monitor datasource");
}
catch (Exception ex)
{
    // Log error to App Insights
    activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
    activity?.RecordException(ex);
    Console.WriteLine($"Error: {ex.Message}");
    throw;
}
finally
{
    // Ensure telemetry is flushed
    await tracerProvider.ForceFlushAsync();
}

await host.RunAsync();
