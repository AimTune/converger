using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Converger.Agent;

/// <summary>
/// The Converger agent: a bot backend that answers the conversations of a Converger channel over one
/// channel-scoped Protocol v1 WebSocket (docs/protocol/v1.md, sections 9 and 10).
/// </summary>
/// <example>
/// <code>
/// var agent = new ConvergerAgent(new AgentOptions
/// {
///     Url = ConvergerAgent.SocketUrl("https://chat.example.com"),
///     Token = token,
/// });
/// agent.OnTurn(async (turn, reply, ct) =&gt; await reply.TextAsync($"You said: {turn.Text}", cancellationToken: ct));
/// await agent.RunAsync(ct);
/// </code>
/// </example>
public sealed class ConvergerAgent
{
    /// <summary>Version of this SDK, sent in the User-Agent header.</summary>
    public const string Version = "0.1.1";

    /// <summary>The protocol version sent in hello.</summary>
    public const string Protocol = "converger/1";

    /// <summary>The WebSocket subprotocol of Protocol v1 (JSON).</summary>
    public const string Subprotocol = "converger.v1";

    /// <summary>The native Protocol v1 endpoint path.</summary>
    public const string SocketPath = "/socket/converger/v1";

    private const int MaxMessageBytes = 4 << 20;
    private static readonly TimeSpan WriteTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan DialTimeout = TimeSpan.FromSeconds(10);
    private static readonly byte[] PingFrame = "{\"type\":\"ping\"}"u8.ToArray();

    // Frame types from the user's side that are not turns.
    private static readonly HashSet<string> NotTurns = new(StringComparer.Ordinal)
    {
        "typing", "presence", "deliveryStatus", "event", "conversationUpdate",
        "run", "genui_components", "skills", "heartbeat", "replayTruncated",
    };

    private readonly AgentOptions _options;
    private readonly Uri _uri;
    private readonly Func<CancellationToken, ValueTask<string>> _token;
    private Func<Turn, Reply, CancellationToken, Task>? _handler;

    private readonly SemaphoreSlim _writeLock = new(1, 1); // serialises writes and the flush after welcome
    private readonly object _mu = new();
    private WebSocket? _conn; // set once welcomed
    private readonly Dictionary<string, Outgoing> _pending = new(StringComparer.Ordinal);
    private readonly List<Outgoing> _backlog = new();
    private readonly Dictionary<string, TaskCompletionSource<JsonNode?>> _asks = new(StringComparer.Ordinal);
    private readonly Dictionary<string, TurnQueue> _queues = new(StringComparer.Ordinal);
    private readonly Dictionary<string, long> _marks = new(StringComparer.Ordinal);
    private ConvergerException? _lastError;
    private bool _stopped;
    private TimeSpan _idle = TimeSpan.FromSeconds(60);
    private int _activeDrains;
    private readonly TaskCompletionSource _drained = new(TaskCreationOptions.RunContinuationsAsynchronously);

    private long _seq;
    private int _running;
    private CancellationToken _runToken;

    /// <summary>
    /// Creates an agent. <see cref="AgentOptions.Url"/> and a token (<see cref="AgentOptions.Token"/> or
    /// <see cref="AgentOptions.TokenProvider"/>) are required. Register a handler with <see cref="OnTurn"/>, then
    /// call <see cref="RunAsync"/>.
    /// </summary>
    public ConvergerAgent(AgentOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (string.IsNullOrEmpty(options.Url))
        {
            throw new ArgumentException("AgentOptions.Url is required", nameof(options));
        }
        _uri = new Uri(options.Url);
        if (options.TokenProvider is { } provider)
        {
            _token = provider;
        }
        else if (options.Token is { } token)
        {
            _token = _ => ValueTask.FromResult(token);
        }
        else
        {
            throw new ArgumentException("AgentOptions.Token or AgentOptions.TokenProvider is required", nameof(options));
        }
        _options = options;
        if (options.Watermarks is not null)
        {
            foreach (var (conversationId, seq) in options.Watermarks)
            {
                _marks[conversationId] = seq;
            }
        }
    }

    /// <summary>
    /// The native endpoint URL for a server base URL (https://h becomes wss://h/socket/converger/v1).
    /// </summary>
    public static string SocketUrl(string baseUrl)
    {
        ArgumentNullException.ThrowIfNull(baseUrl);
        var url = baseUrl.TrimEnd('/');
        if (url.StartsWith("https://", StringComparison.Ordinal))
        {
            url = "wss://" + url["https://".Length..];
        }
        else if (url.StartsWith("http://", StringComparison.Ordinal))
        {
            url = "ws://" + url["http://".Length..];
        }
        return url + SocketPath;
    }

    /// <summary>
    /// Sets the handler of user turns. Turns of one conversation run one at a time, in order; turns of different
    /// conversations run concurrently. A thrown exception ends the run with status "error" and is passed to
    /// <see cref="AgentOptions.OnError"/>. The token is cancelled when the agent stops. Call it before
    /// <see cref="RunAsync"/>.
    /// </summary>
    public void OnTurn(Func<Turn, Reply, CancellationToken, Task> handler)
    {
        ArgumentNullException.ThrowIfNull(handler);
        _handler = handler;
    }

    /// <summary>
    /// The last seq seen per conversation; persist it and pass it to <see cref="AgentOptions.Watermarks"/> to resume
    /// after a restart.
    /// </summary>
    public IReadOnlyDictionary<string, long> Watermarks
    {
        get
        {
            lock (_mu)
            {
                return new Dictionary<string, long>(_marks, StringComparer.Ordinal);
            }
        }
    }

    /// <summary>
    /// Connects, reconnects with jittered backoff and dispatches turns until <paramref name="cancellationToken"/> is
    /// cancelled (it then returns) or the server closes the connection for good (it throws a
    /// <see cref="ConvergerCloseException"/>). Running handlers are cancelled and awaited; pending sends and asks
    /// fail. An agent runs once.
    /// </summary>
    public async Task RunAsync(CancellationToken cancellationToken = default)
    {
        if (_handler is null)
        {
            throw new InvalidOperationException("converger: OnTurn was not called");
        }
        if (Interlocked.Exchange(ref _running, 1) == 1)
        {
            throw new InvalidOperationException("converger: RunAsync was already called");
        }
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _runToken = cts.Token;
        ConvergerCloseException? error = null;
        try
        {
            await LoopAsync(cts.Token).ConfigureAwait(false);
        }
        catch (ConvergerCloseException e)
        {
            error = e;
        }
        cts.Cancel();
        Stop(error);
        await _drained.Task.ConfigureAwait(false);
        if (error is not null)
        {
            throw error;
        }
    }

    private async Task LoopAsync(CancellationToken ct)
    {
        int attempt = 0;
        bool authRetried = false;
        while (true)
        {
            var (code, reason, welcomed) = await ConnectOnceAsync(ct).ConfigureAwait(false);
            if (ct.IsCancellationRequested)
            {
                return;
            }
            if (welcomed)
            {
                attempt = 0;
            }
            ConvergerException? last;
            lock (_mu)
            {
                last = _lastError;
                _lastError = null;
            }
            if (code == 4401 && !authRetried)
            {
                // One immediate retry lets the token provider hand out a fresh token.
                authRetried = true;
                continue;
            }
            if (code is 1008 or 4400 or 4401 or 4403)
            {
                throw new ConvergerCloseException(code, reason, last);
            }
            if (welcomed)
            {
                authRetried = false;
            }
            attempt++;
            var delay = Backoff(attempt);
            if (RetryAfterMs(reason) is long ms)
            {
                delay = TimeSpan.FromMilliseconds(ms);
            }
            try
            {
                await Task.Delay(delay, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private TimeSpan Backoff(int attempt)
    {
        var initial = _options.BackoffInitial.Ticks;
        var max = _options.BackoffMax.Ticks;
        var shift = Math.Min(attempt - 1, 20);
        long d = initial << shift;
        if (d > max || d <= 0 || (initial > 0 && d >> shift != initial))
        {
            d = max;
        }
        return TimeSpan.FromTicks(d / 2 + Random.Shared.NextInt64(d / 2 + 1));
    }

    private static long? RetryAfterMs(string reason)
    {
        if (string.IsNullOrEmpty(reason))
        {
            return null;
        }
        try
        {
            return JsonNode.Parse(reason) is JsonObject obj ? Json.AsInt(obj["retryAfterMs"]) : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private async Task<(int Code, string Reason, bool Welcomed)> ConnectOnceAsync(CancellationToken ct)
    {
        string token;
        try
        {
            token = await _token(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            return (0, "", false);
        }
        catch (Exception e)
        {
            Report(new ConvergerException("token_source", "converger: token source: " + e.Message, e));
            return (0, e.Message, false);
        }

        using var ws = new ClientWebSocket();
        ws.Options.AddSubProtocol(Subprotocol);
        if (_options.Headers is not null)
        {
            foreach (var (name, value) in _options.Headers)
            {
                ws.Options.SetRequestHeader(name, value);
            }
        }
        ws.Options.SetRequestHeader("Authorization", "Bearer " + token);
        ws.Options.SetRequestHeader("User-Agent", "converger-agent-dotnet/" + Version);

        try
        {
            using var dialCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            dialCts.CancelAfter(DialTimeout);
            await ws.ConnectAsync(_uri, dialCts.Token).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            return (0, e.Message, false);
        }

        using var connCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        bool welcomed = false;
        Task? pinger = null;
        try
        {
            try
            {
                await WriteAsync(ws, Json.Serialize(Hello()), connCts.Token).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                return (0, e.Message, false);
            }
            pinger = PingLoopAsync(ws, connCts.Token);

            while (true)
            {
                byte[]? data;
                try
                {
                    data = await ReceiveAsync(ws, connCts.Token).ConfigureAwait(false);
                }
                catch (Exception e)
                {
                    ClearConn(ws);
                    return (0, e.Message, welcomed);
                }
                if (data is null)
                {
                    ClearConn(ws);
                    var status = ws.CloseStatus ?? WebSocketCloseStatus.Empty;
                    var reason = ws.CloseStatusDescription ?? "";
                    await AnswerCloseAsync(ws, status).ConfigureAwait(false);
                    return ((int)status, reason, welcomed);
                }

                JsonObject? msg;
                try
                {
                    msg = JsonNode.Parse(data) as JsonObject;
                }
                catch (JsonException)
                {
                    continue;
                }
                if (msg is null)
                {
                    continue;
                }
                if (!msg.ContainsKey("type"))
                {
                    if (welcomed && Json.Str(msg["conversationId"]) is { Length: > 0 } id && msg["frame"] is JsonObject frame)
                    {
                        Dispatch(id, frame);
                    }
                    continue;
                }
                switch (Json.Str(msg["type"]))
                {
                    case "welcome":
                        if (!welcomed)
                        {
                            welcomed = true;
                            await WelcomedAsync(ws, msg).ConfigureAwait(false);
                        }
                        break;
                    case "error":
                        var error = ConvergerException.FromFrame(null, msg);
                        lock (_mu)
                        {
                            _lastError = error;
                        }
                        Report(error);
                        break;
                }
            }
        }
        finally
        {
            ClearConn(ws);
            connCts.Cancel();
            if (pinger is not null)
            {
                await pinger.ConfigureAwait(false);
            }
        }
    }

    private static async Task AnswerCloseAsync(WebSocket ws, WebSocketCloseStatus status)
    {
        if (ws.State != WebSocketState.CloseReceived)
        {
            return;
        }
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            var answer = status == WebSocketCloseStatus.Empty ? WebSocketCloseStatus.NormalClosure : status;
            await ws.CloseOutputAsync(answer, null, cts.Token).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // The connection is gone either way.
        }
    }

    private static async Task<byte[]?> ReceiveAsync(WebSocket ws, CancellationToken ct)
    {
        var buffer = new byte[16 * 1024];
        using var message = new MemoryStream();
        while (true)
        {
            var result = await ws.ReceiveAsync(buffer.AsMemory(), ct).ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                return null;
            }
            message.Write(buffer, 0, result.Count);
            if (message.Length > MaxMessageBytes)
            {
                throw new WebSocketException(WebSocketError.Faulted, "converger: message larger than the read limit");
            }
            if (result.EndOfMessage)
            {
                return message.ToArray();
            }
        }
    }

    private static async Task WriteAsync(WebSocket ws, byte[] payload, CancellationToken ct)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(WriteTimeout);
        await ws.SendAsync(payload, WebSocketMessageType.Text, true, cts.Token).ConfigureAwait(false);
    }

    private JsonObject Hello()
    {
        var hello = new JsonObject { ["type"] = "hello", ["protocol"] = Protocol };
        if (!string.IsNullOrEmpty(_options.Group))
        {
            hello["group"] = _options.Group;
        }
        if (!string.IsNullOrEmpty(_options.UserId))
        {
            hello["userId"] = _options.UserId;
        }
        lock (_mu)
        {
            if (_marks.Count > 0)
            {
                var marks = new JsonObject();
                foreach (var (conversationId, seq) in _marks)
                {
                    marks[conversationId] = seq;
                }
                hello["watermarks"] = marks;
            }
        }
        return hello;
    }

    private async Task PingLoopAsync(WebSocket ws, CancellationToken ct)
    {
        try
        {
            while (true)
            {
                TimeSpan interval;
                lock (_mu)
                {
                    interval = _idle / 2;
                }
                await Task.Delay(interval, ct).ConfigureAwait(false);
                await _writeLock.WaitAsync(ct).ConfigureAwait(false);
                try
                {
                    await WriteAsync(ws, PingFrame, ct).ConfigureAwait(false);
                }
                finally
                {
                    _writeLock.Release();
                }
            }
        }
        catch (Exception)
        {
            // The connection ended.
        }
    }

    private void ClearConn(WebSocket ws)
    {
        lock (_mu)
        {
            if (ReferenceEquals(_conn, ws))
            {
                _conn = null;
            }
        }
    }

    // Flushes, in their original order, the sends not yet acked and the frames written while disconnected, then
    // makes ws the live connection.
    private async Task WelcomedAsync(WebSocket ws, JsonObject welcome)
    {
        await _writeLock.WaitAsync().ConfigureAwait(false);
        try
        {
            List<Outgoing> outgoing;
            lock (_mu)
            {
                if (welcome["data"] is JsonObject data && data["limits"] is JsonObject limits
                    && Json.AsInt(limits["idleTimeoutMs"]) is long ms && ms > 0)
                {
                    _idle = TimeSpan.FromMilliseconds(ms);
                }
                outgoing = new List<Outgoing>(_backlog);
                outgoing.AddRange(_pending.Values);
                _backlog.Clear();
                _conn = ws;
            }
            outgoing.Sort((a, b) => a.N.CompareTo(b.N));
            foreach (var o in outgoing)
            {
                try
                {
                    await WriteAsync(ws, o.Payload, _runToken).ConfigureAwait(false);
                }
                catch (Exception)
                {
                    // Pending sends are re-sent after the next welcome.
                }
            }
        }
        finally
        {
            _writeLock.Release();
        }
    }

    // Handles one enveloped frame of a conversation.
    private void Dispatch(string id, JsonObject frame)
    {
        var type = Json.Str(frame["type"]);
        var seq = Json.AsInt(frame["seq"]);
        List<Exception>? reports = null;
        lock (_mu)
        {
            if (seq is long s && type != "ack")
            {
                if (s <= _marks.GetValueOrDefault(id))
                {
                    return; // a duplicate (replay overlap)
                }
                _marks[id] = s;
            }
            switch (type)
            {
                case "ack":
                {
                    var clientId = Json.Str(frame["clientId"]) ?? "";
                    if (_pending.Remove(clientId, out var pending))
                    {
                        pending.Result!.TrySetResult(Ack.FromFrame(frame));
                    }
                    break;
                }
                case "error":
                {
                    var error = ConvergerException.FromFrame(id, frame);
                    if (!string.IsNullOrEmpty(error.ClientId) && _pending.Remove(error.ClientId, out var pending))
                    {
                        pending.Result!.TrySetException(error);
                    }
                    else
                    {
                        (reports ??= new()).Add(error);
                    }
                    break;
                }
                case "resume":
                {
                    if (frame["answers"] is JsonObject answers)
                    {
                        foreach (var (interruptId, answer) in answers)
                        {
                            if (_asks.Remove(interruptId, out var ask))
                            {
                                ask.TrySetResult(answer?.DeepClone());
                            }
                            else
                            {
                                (reports ??= new()).Add(new ConvergerException(
                                    "unknown_interrupt",
                                    "an answer to an interrupt this agent is not waiting for: " + interruptId)
                                {
                                    ConversationId = id,
                                });
                            }
                        }
                    }
                    break;
                }
                default:
                    if (Json.Str(frame["from"]) == "user" && type is { Length: > 0 } && !NotTurns.Contains(type) && seq is not null)
                    {
                        EnqueueLocked(Turn.FromFrame(id, frame));
                    }
                    break;
            }
        }
        if (reports is not null)
        {
            foreach (var report in reports)
            {
                Report(report);
            }
        }
    }

    private void EnqueueLocked(Turn turn)
    {
        if (_stopped)
        {
            return;
        }
        if (!_queues.TryGetValue(turn.ConversationId, out var queue))
        {
            queue = new TurnQueue();
            _queues[turn.ConversationId] = queue;
        }
        queue.Turns.Enqueue(turn);
        if (!queue.Running)
        {
            queue.Running = true;
            _activeDrains++;
            _ = Task.Run(() => DrainAsync(turn.ConversationId, queue));
        }
    }

    private async Task DrainAsync(string id, TurnQueue queue)
    {
        try
        {
            while (true)
            {
                Turn turn;
                lock (_mu)
                {
                    if (queue.Turns.Count == 0 || _stopped)
                    {
                        queue.Running = false;
                        _queues.Remove(id);
                        return;
                    }
                    turn = queue.Turns.Dequeue();
                }
                await RunTurnAsync(turn).ConfigureAwait(false);
            }
        }
        finally
        {
            lock (_mu)
            {
                _activeDrains--;
                if (_activeDrains == 0 && _stopped)
                {
                    _drained.TrySetResult();
                }
            }
        }
    }

    private async Task RunTurnAsync(Turn turn)
    {
        var ct = _runToken;
        var reply = new Reply(this, turn.ConversationId);
        await reply.RunStatusAsync("started").ConfigureAwait(false);
        Exception? error = null;
        try
        {
            await _handler!(turn, reply, ct).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            error = e;
        }
        if (ct.IsCancellationRequested)
        {
            return;
        }
        if (error is not null)
        {
            if (reply.TryMarkEnded())
            {
                await reply.RunStatusAsync("error").ConfigureAwait(false);
            }
            Report(error);
            return;
        }
        await reply.EndAsync().ConfigureAwait(false);
    }

    // Writes a frame of conversation id, or keeps it for the next connection. With a clientId the frame stays
    // pending until its ack (or error) arrives. Typing is dropped while disconnected.
    internal async Task<Outgoing> SendFrameAsync(string conversationId, JsonObject frame, string? clientId)
    {
        var envelope = new JsonObject { ["conversationId"] = conversationId, ["frame"] = frame };
        var type = Json.Str(frame["type"]);
        var outgoing = new Outgoing(Interlocked.Increment(ref _seq), Json.Serialize(envelope), clientId);
        bool keep = clientId is null && type != "typing";
        await _writeLock.WaitAsync().ConfigureAwait(false);
        try
        {
            WebSocket? conn;
            lock (_mu)
            {
                if (_stopped)
                {
                    throw new ConvergerStoppedException();
                }
                conn = _conn;
                if (clientId is not null)
                {
                    _pending[clientId] = outgoing;
                }
                else if (conn is null && keep)
                {
                    _backlog.Add(outgoing);
                }
            }
            if (conn is not null)
            {
                try
                {
                    await WriteAsync(conn, outgoing.Payload, _runToken).ConfigureAwait(false);
                }
                catch (Exception) when (keep)
                {
                    lock (_mu)
                    {
                        _backlog.Add(outgoing);
                    }
                }
                catch (Exception)
                {
                    // A pending send is re-sent after the next welcome; typing is dropped.
                }
            }
        }
        finally
        {
            _writeLock.Release();
        }
        return outgoing;
    }

    internal async Task<Ack> AwaitAckAsync(Outgoing outgoing, CancellationToken cancellationToken)
    {
        try
        {
            return await outgoing.Result!.Task.WaitAsync(_options.AckTimeout, cancellationToken).ConfigureAwait(false);
        }
        catch (TimeoutException e) when (e is not ConvergerAckTimeoutException && !outgoing.Result!.Task.IsCompleted)
        {
            Forget(outgoing.ClientId!);
            throw new ConvergerAckTimeoutException(outgoing.ClientId!);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested && !outgoing.Result!.Task.IsCompleted)
        {
            Forget(outgoing.ClientId!);
            throw;
        }
    }

    private void Forget(string clientId)
    {
        lock (_mu)
        {
            _pending.Remove(clientId);
        }
    }

    internal Task<JsonNode?> RegisterAsk(string id)
    {
        var tcs = new TaskCompletionSource<JsonNode?>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_mu)
        {
            if (_stopped)
            {
                throw new ConvergerStoppedException();
            }
            _asks[id] = tcs;
        }
        return tcs.Task;
    }

    internal void DropAsk(string id)
    {
        lock (_mu)
        {
            _asks.Remove(id);
        }
    }

    private void Stop(Exception? error)
    {
        lock (_mu)
        {
            if (_stopped)
            {
                return;
            }
            _stopped = true;
            foreach (var pending in _pending.Values)
            {
                pending.Result!.TrySetException(error ?? new ConvergerStoppedException());
            }
            _pending.Clear();
            foreach (var ask in _asks.Values)
            {
                ask.TrySetException(new ConvergerStoppedException());
            }
            _asks.Clear();
            if (_activeDrains == 0)
            {
                _drained.TrySetResult();
            }
        }
    }

    private void Report(Exception error)
    {
        try
        {
            _options.OnError?.Invoke(error);
        }
        catch (Exception)
        {
            // An error callback must not take the agent down.
        }
    }

    internal static string RandomId() => Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();

    internal sealed class Outgoing
    {
        public Outgoing(long n, byte[] payload, string? clientId)
        {
            N = n;
            Payload = payload;
            ClientId = clientId;
            if (clientId is not null)
            {
                Result = new TaskCompletionSource<Ack>(TaskCreationOptions.RunContinuationsAsynchronously);
            }
        }

        public long N { get; }

        public byte[] Payload { get; }

        public string? ClientId { get; }

        public TaskCompletionSource<Ack>? Result { get; }
    }

    private sealed class TurnQueue
    {
        public Queue<Turn> Turns { get; } = new();

        public bool Running { get; set; }
    }
}
