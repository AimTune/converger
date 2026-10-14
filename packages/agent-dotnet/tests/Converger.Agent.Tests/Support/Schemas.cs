using System.Text.Json;
using System.Text.Json.Nodes;
using Json.Schema;

namespace Converger.Agent.Tests.Support;

/// <summary>The Protocol v1 schemas every frame the agent sends is validated against.</summary>
internal static class Schemas
{
    private const string Base = "https://converger.aimtune.dev/schemas/protocol/v1/";

    private static readonly Lazy<(JsonSchema Envelope, JsonSchema Hello)> Compiled = new(Load);

    public static JsonSchema Envelope => Compiled.Value.Envelope;

    public static JsonSchema Hello => Compiled.Value.Hello;

    /// <summary>Validates a frame the agent sent; returns null when valid, else the errors.</summary>
    public static string? Check(JsonNode frame)
    {
        var type = frame is JsonObject obj && obj["type"] is JsonValue v && v.TryGetValue<string>(out var t) ? t : null;
        if (type == "ping")
        {
            return null;
        }
        var schema = type == "hello" ? Hello : Envelope;
        return Check(schema, frame);
    }

    public static string? Check(JsonSchema schema, JsonNode frame)
    {
        using var doc = JsonDocument.Parse(frame.ToJsonString());
        var result = schema.Evaluate(doc.RootElement, new EvaluationOptions { OutputFormat = OutputFormat.List });
        if (result.IsValid)
        {
            return null;
        }
        var errors = (result.Details ?? [])
            .Where(d => d.Errors is { Count: > 0 })
            .SelectMany(d => d.Errors!.Select(e => $"{d.InstanceLocation} ({d.SchemaLocation}): {e.Key}: {e.Value}"));
        return string.Join("\n", errors.Take(20));
    }

    private static (JsonSchema, JsonSchema) Load()
    {
        var registry = new SchemaRegistry();
        var options = new BuildOptions { SchemaRegistry = registry };
        var files = Directory.EnumerateFiles(Repo.SchemaRoot, "*.schema.json", SearchOption.AllDirectories)
            .OrderBy(f => f, StringComparer.Ordinal)
            .ToList();
        var built = new Dictionary<string, JsonSchema>(StringComparer.Ordinal);
        // Schemas reference each other; build until every one resolves.
        var remaining = files;
        Exception? lastError = null;
        while (remaining.Count > 0)
        {
            var failed = new List<string>();
            foreach (var file in remaining)
            {
                var text = File.ReadAllText(file);
                var id = JsonNode.Parse(text)?["$id"]?.GetValue<string>();
                if (string.IsNullOrEmpty(id))
                {
                    continue;
                }
                try
                {
                    var schema = JsonSchema.FromText(text, options, new Uri(id));
                    built[id] = schema;
                    try
                    {
                        registry.Register(new Uri(id), schema);
                    }
                    catch (Exception)
                    {
                        // Already registered by the build.
                    }
                }
                catch (Exception e) when (e is RefResolutionException or JsonSchemaException)
                {
                    lastError = e;
                    failed.Add(file);
                }
            }
            if (failed.Count == remaining.Count)
            {
                throw new InvalidOperationException("schemas do not resolve: " + string.Join(", ", failed), lastError);
            }
            remaining = failed;
        }
        return (built[Base + "frames/channel/client-envelope.schema.json"], built[Base + "frames/client/hello.schema.json"]);
    }
}
