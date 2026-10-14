using System.Text.Json.Nodes;

namespace Converger.Agent;

/// <summary>
/// An <c>error</c> frame of Protocol v1 (docs/protocol/v1.md section 12): a refused send, an error about
/// one conversation, or a connection-level error. <see cref="Exception.Message"/> is the server's message.
/// </summary>
public class ConvergerException : Exception
{
    /// <summary>Creates an error with a machine-readable code and a human-readable message.</summary>
    public ConvergerException(string code, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        Code = code;
    }

    /// <summary>The machine-readable error code, e.g. <c>conversation_closed</c> or <c>token_expired</c>.</summary>
    public string Code { get; }

    /// <summary>The numeric error code of the protocol (0 when absent).</summary>
    public int Number { get; init; }

    /// <summary>Whether retrying the same operation later can succeed.</summary>
    public bool Retryable { get; init; }

    /// <summary>How long to wait before retrying, when the server said so.</summary>
    public TimeSpan? RetryAfter { get; init; }

    /// <summary>The clientId of the refused send, if the error refers to one.</summary>
    public string? ClientId { get; init; }

    /// <summary>The type of the refused frame, if any.</summary>
    public string? FrameType { get; init; }

    /// <summary>Extra structured details of the error, if any.</summary>
    public JsonObject? Details { get; init; }

    /// <summary>The conversation the error is about; null for connection-level errors.</summary>
    public string? ConversationId { get; init; }

    /// <inheritdoc />
    public override string ToString() =>
        ConversationId is null
            ? $"converger: {Code}: {Message}"
            : $"converger: {Code} (conversation {ConversationId}): {Message}";

    internal static ConvergerException FromFrame(string? conversationId, JsonObject frame)
    {
        var data = frame["data"] as JsonObject;
        var retryAfter = Json.AsInt(data?["retryAfterMs"]);
        return new ConvergerException(Json.Str(data?["code"]) ?? "", Json.Str(data?["message"]) ?? "")
        {
            Number = (int)(Json.AsInt(data?["number"]) ?? 0),
            Retryable = Json.Bool(data?["retryable"]),
            RetryAfter = retryAfter is long ms ? TimeSpan.FromMilliseconds(ms) : null,
            ClientId = Json.Str(data?["clientId"]),
            FrameType = Json.Str(data?["frameType"]),
            Details = data?["details"] is JsonObject details ? (JsonObject)details.DeepClone() : null,
            ConversationId = conversationId,
        };
    }
}

/// <summary>
/// Ends <see cref="ConvergerAgent.RunAsync"/>: the server closed the connection with a code that reconnecting
/// cannot help (1008, 4400, 4401 twice in a row, 4403).
/// </summary>
public sealed class ConvergerCloseException : Exception
{
    /// <summary>Creates a close error.</summary>
    public ConvergerCloseException(int code, string reason, ConvergerException? last)
        : base(last is not null
            ? $"converger: connection closed ({code}): {last.Message}"
            : $"converger: connection closed ({code}) {reason}".TrimEnd())
    {
        Code = code;
        Reason = reason;
        Last = last;
    }

    /// <summary>The WebSocket close code.</summary>
    public int Code { get; }

    /// <summary>The WebSocket close reason.</summary>
    public string Reason { get; }

    /// <summary>The last connection-level error frame before the close, if any.</summary>
    public ConvergerException? Last { get; }
}

/// <summary>A message send whose ack did not arrive within <see cref="AgentOptions.AckTimeout"/>.</summary>
public sealed class ConvergerAckTimeoutException : TimeoutException
{
    /// <summary>Creates an ack timeout error for the send with <paramref name="clientId"/>.</summary>
    public ConvergerAckTimeoutException(string clientId)
        : base($"converger: no ack for {clientId} within the ack timeout")
    {
        ClientId = clientId;
    }

    /// <summary>The clientId of the send.</summary>
    public string ClientId { get; }
}

/// <summary>A send or an ask failed because the agent stopped (<see cref="ConvergerAgent.RunAsync"/> returned).</summary>
public sealed class ConvergerStoppedException : OperationCanceledException
{
    /// <summary>Creates a stopped error.</summary>
    public ConvergerStoppedException()
        : base("converger: agent stopped")
    {
    }
}
