using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Converger.Agent;

internal static class Json
{
    internal static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    internal static readonly JsonElement NullElement = JsonDocument.Parse("null").RootElement.Clone();

    /// <summary>The integer value of a JSON number (1 and 1.0 alike), else null.</summary>
    internal static long? AsInt(JsonNode? node)
    {
        if (node is not JsonValue value || value.GetValueKind() != JsonValueKind.Number)
        {
            return null;
        }
        if (value.TryGetValue<long>(out var l))
        {
            return l;
        }
        if (value.TryGetValue<int>(out var i))
        {
            return i;
        }
        if (value.TryGetValue<double>(out var d) && !double.IsInfinity(d) && d == Math.Floor(d)
            && d >= long.MinValue && d <= long.MaxValue)
        {
            return (long)d;
        }
        return null;
    }

    internal static string? Str(JsonNode? node) =>
        node is JsonValue value && value.GetValueKind() == JsonValueKind.String && value.TryGetValue<string>(out var s)
            ? s
            : null;

    internal static bool Bool(JsonNode? node) =>
        node is JsonValue value && value.GetValueKind() == JsonValueKind.True;

    /// <summary>A detached JSON tree of any value: a JsonNode (cloned), a JsonElement or a serializable object.</summary>
    internal static JsonNode? ToNode(object? value) => value switch
    {
        null => null,
        JsonNode node => node.DeepClone(),
        JsonElement element => JsonNode.Parse(element.GetRawText()),
        JsonDocument document => JsonNode.Parse(document.RootElement.GetRawText()),
        _ => JsonSerializer.SerializeToNode(value, value.GetType(), Options),
    };

    internal static JsonElement ToElement(JsonNode? node) =>
        node is null ? NullElement : JsonSerializer.SerializeToElement(node, Options);

    internal static byte[] Serialize(JsonNode node) => JsonSerializer.SerializeToUtf8Bytes(node, Options);
}
