namespace Converger.Agent;

/// <summary>Configures a <see cref="ConvergerAgent"/>.</summary>
public sealed class AgentOptions
{
    /// <summary>
    /// The native Protocol v1 endpoint, e.g. <c>wss://chat.example.com/socket/converger/v1</c>
    /// (see <see cref="ConvergerAgent.SocketUrl"/>). Required.
    /// </summary>
    public string Url { get; set; } = "";

    /// <summary>
    /// A static channel-scoped token (POST /api/v1/converger/tokens/generate with <c>{"scope": "channel"}</c>).
    /// Use <see cref="TokenProvider"/> instead when tokens expire.
    /// </summary>
    public string? Token { get; set; }

    /// <summary>
    /// Returns the channel-scoped token for a connection attempt. It is called on every connect, so an expired
    /// token (close 4401) can be replaced. Takes precedence over <see cref="Token"/>.
    /// </summary>
    public Func<CancellationToken, ValueTask<string>>? TokenProvider { get; set; }

    /// <summary>
    /// Joins an agent group: the connections of a group share the channel's conversations, each served by one
    /// member (hello.group).
    /// </summary>
    public string? Group { get; set; }

    /// <summary>Names the agent as the sender of its replies when the token has no user_id (hello.userId).</summary>
    public string? UserId { get; set; }

    /// <summary>
    /// Resumes conversations from stored watermarks: the last seq seen per conversation, as returned by
    /// <see cref="ConvergerAgent.Watermarks"/>.
    /// </summary>
    public IReadOnlyDictionary<string, long>? Watermarks { get; set; }

    /// <summary>The first reconnect delay of the jittered exponential backoff (default 500 ms).</summary>
    public TimeSpan BackoffInitial { get; set; } = TimeSpan.FromMilliseconds(500);

    /// <summary>The largest reconnect delay (default 30 s).</summary>
    public TimeSpan BackoffMax { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>How long a message send waits for its ack (default 30 s).</summary>
    public TimeSpan AckTimeout { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>Extra HTTP headers of the WebSocket upgrade request.</summary>
    public IReadOnlyDictionary<string, string>? Headers { get; set; }

    /// <summary>
    /// Receives errors that no call returns: connection-level error frames, errors about a conversation, handler
    /// errors, unknown interrupt answers, token provider failures. It must not block.
    /// </summary>
    public Action<Exception>? OnError { get; set; }
}
