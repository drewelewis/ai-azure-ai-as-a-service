using Azure.AI.Projects;
using Azure.AI.Inference;
using Azure.Identity;
using Microsoft.Agents.AI;

/// <summary>
/// Example 1: Simple Chat via APIM Gateway (.NET)
/// 
/// For .NET developers using the Agent Framework.
/// Just point to your APIM gateway URL instead of direct Azure OpenAI.
/// </summary>

class SimpleChatExample
{
    private const string ProjectId = "my-hub-project";
    private const string ApimGatewayUrl = "https://your-company-ai.azure-api.net";

    static async Task Main(string[] args)
    {
        await RunSimpleChatAsync();
    }

    static async Task RunSimpleChatAsync()
    {
        // 1. Use DefaultAzureCredential (your corporate identity)
        var credential = new DefaultAzureCredential();

        // 2. Point to APIM gateway URL, NOT direct Azure OpenAI
        var client = new AIProjectClient(
            new Uri(ApimGatewayUrl),
            credential
        );

        // 3. Get the chat client
        var chatClient = client.GetChatClient("gpt-4o");

        // 4. Send a message
        var response = await chatClient.CompleteAsync(
            messages: new[]
            {
                new ChatMessage { Role = ChatCompletionRole.User, Content = "What's the capital of France?" }
            }
        );

        // 5. Print response
        Console.WriteLine($"Response: {response.Value.Content[0].Text}");
        Console.WriteLine($"Tokens: {response.Value.Usage.TotalTokens}");
    }
}
