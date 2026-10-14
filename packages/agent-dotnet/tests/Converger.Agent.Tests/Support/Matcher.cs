using System.Text.Json;
using System.Text.Json.Nodes;

namespace Converger.Agent.Tests.Support;

/// <summary>The fixture pattern rules of packages/conformance/README.md.</summary>
internal static class Matcher
{
    /// <summary>Replaces {{name}} with captured values, in keys and string values.</summary>
    public static JsonNode? Subst(JsonNode? node, IReadOnlyDictionary<string, string> caps) => node switch
    {
        JsonObject obj => new JsonObject(obj.Select(kv => KeyValuePair.Create(SubstString(kv.Key, caps), Subst(kv.Value, caps)))),
        JsonArray array => new JsonArray(array.Select(item => Subst(item, caps)).ToArray()),
        JsonValue value when value.GetValueKind() == JsonValueKind.String => JsonValue.Create(SubstString(value.GetValue<string>(), caps)),
        null => null,
        _ => node.DeepClone(),
    };

    public static string SubstString(string s, IReadOnlyDictionary<string, string> caps)
    {
        foreach (var (name, value) in caps)
        {
            s = s.Replace("{{" + name + "}}", value, StringComparison.Ordinal);
        }
        return s;
    }

    /// <summary>
    /// Checks actual against a fixture pattern ("$any", "$capture:name", "{{name}}"; objects need exactly the same
    /// keys, arrays the same length, numbers compare numerically). Returns null on a match, else the mismatch.
    /// </summary>
    public static string? Match(JsonNode? pattern, JsonNode? actual, Dictionary<string, string> caps, string path)
    {
        switch (pattern)
        {
            case JsonValue p when p.GetValueKind() == JsonValueKind.String:
            {
                var s = p.GetValue<string>();
                if (s == "$any")
                {
                    return null;
                }
                if (s.StartsWith("$capture:", StringComparison.Ordinal))
                {
                    if (StringOf(actual) is not { Length: > 0 } captured)
                    {
                        return $"{path}: expected a string to capture, got {Show(actual)}";
                    }
                    caps[s["$capture:".Length..]] = captured;
                    return null;
                }
                var want = SubstString(s, caps);
                return StringOf(actual) == want ? null : $"{path}: expected \"{want}\", got {Show(actual)}";
            }
            case JsonObject p:
            {
                if (actual is not JsonObject a)
                {
                    return $"{path}: expected an object, got {Show(actual)}";
                }
                var substituted = p.ToDictionary(kv => SubstString(kv.Key, caps), kv => kv.Value, StringComparer.Ordinal);
                var wantKeys = substituted.Keys.OrderBy(k => k, StringComparer.Ordinal).ToList();
                var gotKeys = a.Select(kv => kv.Key).OrderBy(k => k, StringComparer.Ordinal).ToList();
                if (!wantKeys.SequenceEqual(gotKeys))
                {
                    return $"{path}: expected keys [{string.Join(", ", wantKeys)}], got [{string.Join(", ", gotKeys)}]";
                }
                foreach (var key in wantKeys)
                {
                    if (Match(substituted[key], a[key], caps, path + "." + key) is { } error)
                    {
                        return error;
                    }
                }
                return null;
            }
            case JsonArray p:
            {
                if (actual is not JsonArray a || a.Count != p.Count)
                {
                    return $"{path}: expected {p.ToJsonString()}, got {Show(actual)}";
                }
                for (var i = 0; i < p.Count; i++)
                {
                    if (Match(p[i], a[i], caps, $"{path}[{i}]") is { } error)
                    {
                        return error;
                    }
                }
                return null;
            }
            case JsonValue p when p.GetValueKind() == JsonValueKind.Number:
                return actual is JsonValue n && n.GetValueKind() == JsonValueKind.Number
                       && decimal.Parse(n.ToJsonString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture)
                       == decimal.Parse(p.ToJsonString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture)
                    ? null
                    : $"{path}: expected {p.ToJsonString()}, got {Show(actual)}";
            case null:
                return actual is null ? null : $"{path}: expected null, got {Show(actual)}";
            default:
                return actual is not null && JsonNode.DeepEquals(pattern, actual)
                    ? null
                    : $"{path}: expected {pattern.ToJsonString()}, got {Show(actual)}";
        }
    }

    private static string? StringOf(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    private static string Show(JsonNode? node) => node?.ToJsonString() ?? "null";
}
