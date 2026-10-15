using System.Text.Json.Nodes;

namespace Converger.Agent;

/// <summary>
/// One user turn: a message frame with <c>from: "user"</c> of one conversation.
/// </summary>
public sealed class Turn
{
    /// <summary>The conversation the turn belongs to.</summary>
    public required string ConversationId { get; init; }

    /// <summary>The activity id of the message.</summary>
    public string? Id { get; init; }

    /// <summary>The seq of the message in the conversation.</summary>
    public long Seq { get; init; }

    /// <summary><c>data.text</c>, or the empty string for messages without text.</summary>
    public string Text { get; init; } = "";

    /// <summary>The turn's typed message.</summary>
    public required TurnMessage Message { get; init; }

    /// <summary>The frame's sender, null when absent.</summary>
    public Participant? Participant { get; init; }

    /// <summary>The per-turn context (mekik/1 <c>meta</c>), never stored.</summary>
    public JsonObject? Meta { get; init; }

    /// <summary>The stored activity metadata.</summary>
    public JsonObject? Metadata { get; init; }

    /// <summary><c>metadata.action</c>: the button or chip the user tapped, if any.</summary>
    public AgentAction? Action { get; init; }

    /// <summary>The frame's <c>replyTo</c> (<c>{id, seq}</c>) when the turn answers an activity.</summary>
    public JsonObject? ReplyTo { get; init; }

    /// <summary>The message timestamp in Unix milliseconds, when present.</summary>
    public long? Timestamp { get; init; }

    internal static Turn FromFrame(string conversationId, JsonObject frame)
    {
        var data = frame["data"] as JsonObject;
        Participant? participant = null;
        if (frame["sender"] is JsonObject sender)
        {
            participant = new Participant(Json.Str(sender["id"]) ?? "", Json.Str(sender["role"]) ?? "", Json.Str(sender["name"]));
        }
        var metadata = frame["metadata"] as JsonObject;
        AgentAction? action = null;
        if (metadata?["action"] is JsonObject act)
        {
            action = new AgentAction(Json.Str(act["label"]) ?? "", act["value"]?.DeepClone(), Json.Str(act["url"]));
        }
        return new Turn
        {
            ConversationId = conversationId,
            Id = Json.Str(frame["id"]),
            Seq = Json.AsInt(frame["seq"]) ?? 0,
            Text = Json.Str(data?["text"]) ?? "",
            Message = new TurnMessage(Json.Str(frame["type"]) ?? "", data, frame),
            Participant = participant,
            Meta = frame["meta"] as JsonObject,
            Metadata = metadata,
            Action = action,
            ReplyTo = frame["replyTo"] as JsonObject,
            Timestamp = Json.AsInt(frame["timestamp"]),
        };
    }
}

/// <summary>A turn's typed message.</summary>
/// <param name="Type">The message type (text, buttons, file, ...).</param>
/// <param name="Data">The message data, null when absent.</param>
/// <param name="Raw">The whole frame as received.</param>
public sealed record TurnMessage(string Type, JsonObject? Data, JsonObject Raw);

/// <summary>A frame's sender.</summary>
/// <param name="Id">The participant id.</param>
/// <param name="Role">The participant role (user, bot, agent, ...).</param>
/// <param name="Name">The display name, if any.</param>
public sealed record Participant(string Id, string Role, string? Name);

/// <summary>
/// A tappable chip or button. When <see cref="Value"/> is null it is omitted and the answer is the label.
/// </summary>
public sealed class AgentAction
{
    /// <summary>Creates an action.</summary>
    /// <param name="label">The text shown to the user.</param>
    /// <param name="value">The value sent back when tapped (any JSON value), or null for the label.</param>
    /// <param name="url">A link to open instead of sending a value.</param>
    public AgentAction(string label, JsonNode? value = null, string? url = null)
    {
        Label = label;
        Value = value;
        Url = url;
    }

    /// <summary>The text shown to the user.</summary>
    public string Label { get; }

    /// <summary>The value sent back when tapped; null means the label.</summary>
    public JsonNode? Value { get; }

    /// <summary>A link to open, if any.</summary>
    public string? Url { get; }

    internal JsonObject ToJson()
    {
        var obj = new JsonObject { ["label"] = Label };
        if (Value is not null)
        {
            obj["value"] = Value.DeepClone();
        }
        if (!string.IsNullOrEmpty(Url))
        {
            obj["url"] = Url;
        }
        return obj;
    }

    internal static JsonArray? ToJsonArray(IEnumerable<AgentAction>? actions)
    {
        if (actions is null)
        {
            return null;
        }
        var array = new JsonArray();
        foreach (var action in actions)
        {
            array.Add(action.ToJson());
        }
        return array.Count > 0 ? array : null;
    }
}

/// <summary>Confirms a stored message send.</summary>
/// <param name="ClientId">The clientId of the send.</param>
/// <param name="Id">The activity id the server stored the message under.</param>
/// <param name="Seq">The seq of the message in the conversation.</param>
/// <param name="Timestamp">The server timestamp in Unix milliseconds, when present.</param>
/// <param name="Duplicate">Whether the server had already stored this clientId (a re-sent message).</param>
public sealed record Ack(string ClientId, string? Id, long Seq, long? Timestamp, bool Duplicate)
{
    internal static Ack FromFrame(JsonObject frame) => new(
        Json.Str(frame["clientId"]) ?? "",
        Json.Str(frame["id"]),
        Json.AsInt(frame["seq"]) ?? 0,
        Json.AsInt(frame["timestamp"]),
        Json.Bool(frame["duplicate"]));
}

/// <summary>
/// The data of a <c>tool_call</c> frame, upserted by <see cref="Id"/> as it advances running, then completed or
/// error. Null fields are omitted.
/// </summary>
public sealed class ToolCall
{
    /// <summary>The tool call id; frames with the same id update one tool call.</summary>
    public required string Id { get; init; }

    /// <summary>The tool name.</summary>
    public required string Name { get; init; }

    /// <summary>running, completed or error.</summary>
    public required string Status { get; init; }

    /// <summary>A human-readable description.</summary>
    public string? Description { get; init; }

    /// <summary>The tool parameters.</summary>
    public JsonObject? Params { get; init; }

    /// <summary>The tool result.</summary>
    public JsonNode? Result { get; init; }

    /// <summary>The error message when the call failed.</summary>
    public string? Error { get; init; }

    /// <summary>Start time in Unix milliseconds.</summary>
    public long? StartedAt { get; init; }

    /// <summary>End time in Unix milliseconds.</summary>
    public long? EndedAt { get; init; }

    internal JsonObject ToJson()
    {
        var obj = new JsonObject { ["id"] = Id, ["name"] = Name, ["status"] = Status };
        if (Description is not null)
        {
            obj["description"] = Description;
        }
        if (Params is not null)
        {
            obj["params"] = Params.DeepClone();
        }
        if (Result is not null)
        {
            obj["result"] = Result.DeepClone();
        }
        if (Error is not null)
        {
            obj["error"] = Error;
        }
        if (StartedAt is long started)
        {
            obj["startedAt"] = started;
        }
        if (EndedAt is long ended)
        {
            obj["endedAt"] = ended;
        }
        return obj;
    }
}
