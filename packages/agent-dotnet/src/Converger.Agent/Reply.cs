using System.Text.Json;
using System.Text.Json.Nodes;

namespace Converger.Agent;

/// <summary>
/// Sends the agent's frames into the turn's conversation. Its methods are safe for concurrent use.
/// </summary>
public sealed class Reply
{
    private readonly ConvergerAgent _agent;
    private int _ended;
    private int _asks;

    internal Reply(ConvergerAgent agent, string conversationId)
    {
        _agent = agent;
        ConversationId = conversationId;
    }

    /// <summary>The conversation this reply writes to.</summary>
    public string ConversationId { get; }

    /// <summary>
    /// Sends a text message, with optional quick-reply chips, and waits for its ack. A refused send throws a
    /// <see cref="ConvergerException"/>; a missing ack a <see cref="ConvergerAckTimeoutException"/>.
    /// </summary>
    public Task<Ack> TextAsync(string text, IEnumerable<AgentAction>? actions = null, CancellationToken cancellationToken = default)
    {
        var frame = new JsonObject { ["type"] = "text", ["data"] = new JsonObject { ["text"] = text } };
        if (AgentAction.ToJsonArray(actions) is JsonArray array)
        {
            frame["actions"] = array;
        }
        return SendMessageAsync(frame, cancellationToken);
    }

    /// <summary>
    /// Sends a message of any type (buttons, quick-reply, card, carousel, image, file, ... see
    /// docs/protocol/messages.md) and waits for its ack. <paramref name="data"/> is a JsonNode, a JsonElement or an
    /// object serialized with System.Text.Json web defaults (camelCase).
    /// </summary>
    public Task<Ack> MessageAsync(string type, object data, CancellationToken cancellationToken = default)
    {
        var frame = new JsonObject { ["type"] = type, ["data"] = Json.ToNode(data) };
        return SendMessageAsync(frame, cancellationToken);
    }

    private async Task<Ack> SendMessageAsync(JsonObject frame, CancellationToken cancellationToken)
    {
        var clientId = "agent-" + ConvergerAgent.RandomId();
        frame["clientId"] = clientId;
        var outgoing = await _agent.SendFrameAsync(ConversationId, frame, clientId).ConfigureAwait(false);
        return await _agent.AwaitAckAsync(outgoing, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Sends an interrupt and waits for the user's answer (a tapped button, a chip or a resume frame), then marks the
    /// interrupt resolved. The answer is the action's value (any JSON value), else its label or the user's text.
    /// </summary>
    /// <param name="payload">The question (any JSON value; null sends <c>{}</c>).</param>
    /// <param name="actions">Buttons offered as answers.</param>
    /// <param name="ui">A GenUI component rendering the question: <c>{"component": ..., "props": ...}</c>.</param>
    /// <param name="cancellationToken">Stops waiting for the answer.</param>
    public async Task<JsonElement> AskAsync(object? payload, IEnumerable<AgentAction>? actions = null, object? ui = null, CancellationToken cancellationToken = default)
    {
        // Not of the clientId syntax ('/' and '#'), so the server keys neither the interrupt nor its
        // interrupt_resolved by it and expects no ack (v1 section 7).
        var id = $"ask/{ConvergerAgent.RandomId()}#{Interlocked.Increment(ref _asks) - 1}";
        var data = new JsonObject { ["payload"] = Json.ToNode(payload) ?? new JsonObject() };
        if (AgentAction.ToJsonArray(actions) is JsonArray array)
        {
            data["actions"] = array;
        }
        if (Json.ToNode(ui) is JsonNode uiNode)
        {
            data["ui"] = uiNode;
        }
        var answerTask = _agent.RegisterAsk(id);
        try
        {
            await _agent.SendFrameAsync(ConversationId, new JsonObject { ["type"] = "interrupt", ["id"] = id, ["data"] = data }, null).ConfigureAwait(false);
        }
        catch
        {
            _agent.DropAsk(id);
            throw;
        }
        JsonNode? answer;
        try
        {
            answer = await answerTask.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            _agent.DropAsk(id);
            throw;
        }
        var resolved = new JsonObject
        {
            ["type"] = "interrupt_resolved",
            ["id"] = id,
            ["data"] = new JsonObject { ["answer"] = answer?.DeepClone() },
        };
        await _agent.SendFrameAsync(ConversationId, resolved, null).ConfigureAwait(false);
        return Json.ToElement(answer);
    }

    /// <summary>Sends a tool_call frame (stored, upserted by id on the client).</summary>
    public async Task ToolCallAsync(ToolCall call, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(call);
        await _agent.SendFrameAsync(ConversationId, new JsonObject { ["type"] = "tool_call", ["data"] = call.ToJson() }, null).ConfigureAwait(false);
    }

    /// <summary>Starts or stops the typing indicator (dropped while disconnected).</summary>
    public async Task TypingAsync(bool on, CancellationToken cancellationToken = default)
    {
        await _agent.SendFrameAsync(ConversationId, new JsonObject { ["type"] = "typing", ["isTyping"] = on }, null).ConfigureAwait(false);
    }

    /// <summary>
    /// Writes a raw agent frame (frames/channel/agent-frame.schema.json) without waiting for an ack. The frame is
    /// copied.
    /// </summary>
    public async Task SendAsync(JsonObject frame, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(frame);
        await _agent.SendFrameAsync(ConversationId, (JsonObject)frame.DeepClone(), null).ConfigureAwait(false);
    }

    /// <summary>
    /// Finishes the run now (run "finished"); later calls are no-ops. It is called for you when the handler returns.
    /// Prefer <see cref="EndAsync"/> when frames follow, so the run frame is written first.
    /// </summary>
    public void End() => _ = EndAsync();

    /// <summary>Like <see cref="End"/>, completing once the run frame is written (or kept for the next connection).</summary>
    public async Task EndAsync()
    {
        if (Interlocked.Exchange(ref _ended, 1) == 0)
        {
            await RunStatusAsync("finished").ConfigureAwait(false);
        }
    }

    internal bool TryMarkEnded() => Interlocked.Exchange(ref _ended, 1) == 0;

    internal async Task RunStatusAsync(string status)
    {
        try
        {
            await _agent.SendFrameAsync(ConversationId, new JsonObject { ["type"] = "run", ["data"] = new JsonObject { ["status"] = status } }, null).ConfigureAwait(false);
        }
        catch (ConvergerStoppedException)
        {
        }
    }
}
