using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Converger.Agent.Tests.Support;

/// <summary>An in-process Protocol v1 server; the test drives the agent's connections one at a time.</summary>
internal sealed class FakeServer : IAsyncDisposable
{
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);

    private readonly WebApplication _app;
    private readonly Channel<FakeConnection> _connections = Channel.CreateUnbounded<FakeConnection>();

    private FakeServer(WebApplication app, string token)
    {
        _app = app;
        Token = token;
    }

    public string Token { get; }

    public string Url { get; private set; } = "";

    public static async Task<FakeServer> StartAsync(string token)
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        var app = builder.Build();
        var server = new FakeServer(app, token);
        app.UseWebSockets();
        app.Run(server.HandleAsync);
        await app.StartAsync();
        server.Url = ConvergerAgent.SocketUrl(app.Urls.First());
        return server;
    }

    private async Task HandleAsync(HttpContext context)
    {
        if (context.Request.Path != ConvergerAgent.SocketPath || !context.WebSockets.IsWebSocketRequest)
        {
            context.Response.StatusCode = StatusCodes.Status404NotFound;
            return;
        }
        var requested = context.WebSockets.WebSocketRequestedProtocols;
        var subprotocol = requested.Contains(ConvergerAgent.Subprotocol) ? ConvergerAgent.Subprotocol : null;
        var ws = await context.WebSockets.AcceptWebSocketAsync(subprotocol);
        var connection = new FakeConnection(
            ws,
            context.Request.Headers.Authorization.ToString(),
            context.Request.Headers.UserAgent.ToString(),
            string.Join(",", requested));
        _connections.Writer.TryWrite(connection);
        try
        {
            await connection.Finished.Task.WaitAsync(context.RequestAborted);
        }
        catch (OperationCanceledException)
        {
        }
    }

    /// <summary>The agent's next connection; its Authorization header must carry the token.</summary>
    public async Task<FakeConnection> AcceptAsync()
    {
        FakeConnection connection;
        try
        {
            connection = await _connections.Reader.ReadAsync().AsTask().WaitAsync(Timeout);
        }
        catch (TimeoutException)
        {
            throw new Xunit.Sdk.XunitException("the agent did not connect");
        }
        Assert.Equal("Bearer " + Token, connection.Authorization);
        return connection;
    }

    public async ValueTask DisposeAsync()
    {
        while (_connections.Reader.TryRead(out var connection))
        {
            connection.Finished.TrySetResult();
        }
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        try
        {
            await _app.StopAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
        }
        await _app.DisposeAsync();
    }
}

/// <summary>One accepted agent connection.</summary>
internal sealed class FakeConnection
{
    public FakeConnection(WebSocket ws, string authorization, string userAgent, string requestedSubprotocols)
    {
        Ws = ws;
        Authorization = authorization;
        UserAgent = userAgent;
        RequestedSubprotocols = requestedSubprotocols;
    }

    public WebSocket Ws { get; }

    public string Authorization { get; }

    public string UserAgent { get; }

    public string RequestedSubprotocols { get; }

    public TaskCompletionSource Finished { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    /// <summary>Reads the next frame the agent sent, skipping pings; every frame must match the v1 schemas.</summary>
    public async Task<JsonObject> NextAsync()
    {
        while (true)
        {
            using var cts = new CancellationTokenSource(FakeServer.Timeout);
            string text;
            try
            {
                text = await ReceiveTextAsync(cts.Token) ?? throw new Xunit.Sdk.XunitException("the agent closed the connection");
            }
            catch (OperationCanceledException)
            {
                throw new Xunit.Sdk.XunitException("the agent sent no frame in time");
            }
            var frame = JsonNode.Parse(text) as JsonObject ?? throw new Xunit.Sdk.XunitException("agent sent a non-object: " + text);
            if (Schemas.Check(frame) is { } error)
            {
                throw new Xunit.Sdk.XunitException($"agent frame does not match the v1 schema: {text}\n{error}");
            }
            if (frame["type"]?.GetValue<string>() != "ping")
            {
                return frame;
            }
        }
    }

    public async Task WriteAsync(JsonNode? frame)
    {
        var bytes = Encoding.UTF8.GetBytes(frame?.ToJsonString() ?? "null");
        await Ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
    }

    /// <summary>Closes with a code (and reason) and waits for the agent's close answer, dropping its last frames.</summary>
    public async Task CloseAsync(int code, string reason = "")
    {
        try
        {
            await Ws.CloseOutputAsync((WebSocketCloseStatus)code, reason, CancellationToken.None);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            while (await ReceiveTextAsync(cts.Token) is not null)
            {
            }
        }
        catch (Exception e) when (e is WebSocketException or OperationCanceledException)
        {
        }
        finally
        {
            Finished.TrySetResult();
        }
    }

    private async Task<string?> ReceiveTextAsync(CancellationToken ct)
    {
        var buffer = new byte[64 * 1024];
        using var message = new MemoryStream();
        while (true)
        {
            var result = await Ws.ReceiveAsync(buffer.AsMemory(), ct);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                return null;
            }
            message.Write(buffer, 0, result.Count);
            if (result.EndOfMessage)
            {
                return Encoding.UTF8.GetString(message.ToArray());
            }
        }
    }
}
