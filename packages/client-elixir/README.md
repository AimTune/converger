# ConvergerClient

Elixir client for [Converger](https://converger.aimtune.dev), for Elixir apps that integrate with or embed
Converger: a REST client for the client API and the tenant API (`Req`), a
[Protocol v1](https://converger.aimtune.dev/protocol/v1) WebSocket client with resume (`Mint.WebSocket`), and
outbound webhook signature verification.

```elixir
def deps do
  [{:converger_client, "~> 0.1"}]
end
```

Full documentation: [converger.aimtune.dev/sdk/elixir](https://converger.aimtune.dev/sdk/elixir).

## REST

```elixir
client = ConvergerClient.new("https://chat.example.com", api_key: "cvg_live_...", channel_secret: "...")

{:ok, token} = ConvergerClient.ClientAPI.generate_token(client, user_id: "user-42")
{:ok, conv} = ConvergerClient.ClientAPI.create_conversation(client, token.token)
{:ok, _} = ConvergerClient.ClientAPI.post_activity(client, conv.token, conv.conversation_id, %{text: "Hi!"},
  idempotency_key: "msg-1")

{:ok, reply} = ConvergerClient.TenantAPI.post_activity(client, conv.conversation_id, %{sender: "bot", text: "Hello!"})
```

Errors are `{:error, %ConvergerClient.Error{status, code, message, details, request_id, retry_after}}`, the same
whatever error shape the server used.

## WebSocket (Protocol v1)

```elixir
{:ok, sock} =
  ConvergerClient.Socket.start_link(client: client, token: conv.token, conversation_id: conv.conversation_id)

{:ok, %ConvergerClient.Ack{seq: seq}} = ConvergerClient.Socket.send_text(sock, "Where is my order?")

receive do
  {:converger, ^sock, %{"type" => "text", "data" => %{"text" => text}}} -> IO.puts(text)
  {:converger_closed, ^sock, %{code: code}} -> IO.puts("closed #{code}")
end
```

Frames arrive in the owner's mailbox: persistent frames in `seq` order, exactly once. The socket reconnects with
jittered backoff, resumes from its watermark (`:watermark` to resume a stored position), re-sends unacknowledged
sends with their original `clientId` and answers gaps with `sync`. Pass a 0-arity function as `:token` to fetch
a fresh token on every connect.

## Webhook signature verification

```elixir
# In a Plug or Phoenix controller, with the raw body kept by a body reader:
case ConvergerClient.Webhook.verify_signature(conn.req_headers, raw_body, secret) do
  :ok -> handle(Jason.decode!(raw_body))
  {:error, reason} -> send_resp(conn, 401, Atom.to_string(reason))
end
```

`secret` may be a list while you rotate secrets; `tolerance:` changes the 300 s window.

## Development

```bash
mix test                                                                 # unit + conformance
CONVERGER_FIXTURES=../conformance/integration/fixtures.json mix test --only integration
```

Releases are tagged `client-elixir/vX.Y.Z` and published to Hex by `.github/workflows/sdk-elixir-release.yml`.
