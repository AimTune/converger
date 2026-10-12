defmodule ConvergerClient.SocketTest do
  use ExUnit.Case, async: true

  alias ConvergerClient.{Ack, FakeServer, Socket}

  defp labels(sock, n) do
    for _ <- 1..n do
      assert_receive {:converger, ^sock, frame}, 5_000
      if is_integer(frame["seq"]), do: "#{frame["type"]}:#{frame["seq"]}", else: frame["type"]
    end
  end

  defp start(url, opts \\ []) do
    {:ok, sock} = Socket.start_link([url: url, token: "good", backoff: {10, 50}] ++ opts)
    sock
  end

  test "handshake, replay, send with ack, live frames" do
    {url, agent} = FakeServer.start(2)
    sock = start(url)
    assert labels(sock, 3) == ["welcome", "text:1", "text:2"]
    assert {:ok, %Ack{seq: 3, client_id: "ex-" <> _}} = Socket.send_text(sock, "hello")
    FakeServer.push(agent, "bot", "live")
    assert labels(sock, 1) == ["text:4"]
    assert Socket.watermark(sock) == 4
    assert FakeServer.get(agent, :subprotocols) == ["converger.v1"]

    assert FakeServer.get(agent, :hellos) == [
             %{"type" => "hello", "protocol" => "converger/1", "watermark" => 0}
           ]
  end

  test "reconnects and resumes from the watermark" do
    {url, agent} = FakeServer.start(2, close_after_replay: [1012])
    sock = start(url)
    assert labels(sock, 4) == ["welcome", "text:1", "text:2", "welcome"]
    FakeServer.push(agent, "bot", "after reconnect")
    assert labels(sock, 1) == ["text:3"]

    assert Enum.at(FakeServer.get(agent, :hellos), 1) ==
             %{
               "type" => "hello",
               "protocol" => "converger/1",
               "watermark" => 2,
               "conversationId" => "c-1"
             }
  end

  test "re-sends an unacked send with the same clientId" do
    {url, agent} = FakeServer.start(0, drop_first_text: true)
    sock = start(url)
    assert labels(sock, 1) == ["welcome"]
    assert {:ok, %Ack{seq: 1}} = Socket.send_text(sock, "exactly once", client_id: "cid-1")

    ids = for %{"type" => "text", "clientId" => id} <- FakeServer.get(agent, :received), do: id
    assert ids == ["cid-1", "cid-1"]
    assert length(FakeServer.get(agent, :frames)) == 1
  end

  test "4401 with a static token ends the socket" do
    {url, _agent} = FakeServer.start(0)
    {:ok, sock} = Socket.start_link(url: url, token: "bad", backoff: {10, 50})
    ref = Process.monitor(sock)
    assert_receive {:converger_closed, ^sock, %{code: 4401}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^sock, :normal}
  end

  test "a token function is called again after 4401" do
    {url, _agent} = FakeServer.start(0)
    {:ok, tokens} = Agent.start_link(fn -> ["bad", "good"] end)
    fun = fn -> Agent.get_and_update(tokens, fn [t | rest] -> {t, rest} end) end
    {:ok, sock} = Socket.start_link(url: url, token: fun, backoff: {10, 50})
    assert labels(sock, 2) == ["error", "welcome"]
  end

  test "url/1 derives the native endpoint" do
    assert Socket.url("https://chat.example.com/") == "wss://chat.example.com/socket/converger/v1"
    assert Socket.url("http://localhost:4000") == "ws://localhost:4000/socket/converger/v1"
  end
end
