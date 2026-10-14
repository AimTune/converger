defmodule ConvergerAgent.Wire do
  @moduledoc false
  # Test-side helpers driving ConvergerAgent.FakeServer connections, and the
  # conformance pattern matcher (packages/conformance/README.md).

  import ExUnit.Assertions

  alias ConvergerAgent.Schemas

  @timeout 5_000

  def fixture_dir do
    System.get_env("CONVERGER_CONFORMANCE_DIR") ||
      Path.expand("../../../conformance", __DIR__)
  end

  def load_fixture(name \\ "agent.json"),
    do: fixture_dir() |> Path.join(name) |> File.read!() |> Jason.decode!()

  @doc "Waits for the agent's next connection and checks its authorization header."
  def accept(token) do
    receive do
      {:fake_conn, conn, auth} ->
        assert auth == "Bearer " <> token, "authorization header = #{inspect(auth)}"
        conn
    after
      @timeout -> flunk("the agent did not connect")
    end
  end

  @doc "The next frame the agent sent on `conn` (skipping pings), validated against the v1 schemas."
  def next(conn) do
    receive do
      {:fake_frame, ^conn, text} ->
        frame = Jason.decode!(text)

        case Schemas.validate(frame) do
          :ok -> :ok
          {:error, error} -> flunk("agent frame does not match the v1 schema: #{text}\n#{error}")
        end

        if frame["type"] == "ping", do: next(conn), else: frame
    after
      @timeout -> flunk("the agent sent no frame")
    end
  end

  def write(conn, frame), do: send(conn, {:write, Jason.encode!(frame)})
  def close(conn, code), do: send(conn, {:close, code})

  @doc "Replaces `{{name}}` with captured values, in keys and string values."
  def subst(value, caps) when is_binary(value) do
    Enum.reduce(caps, value, fn {k, v}, acc -> String.replace(acc, "{{" <> k <> "}}", v) end)
  end

  def subst(value, caps) when is_map(value),
    do: Map.new(value, fn {k, v} -> {subst(k, caps), subst(v, caps)} end)

  def subst(value, caps) when is_list(value), do: Enum.map(value, &subst(&1, caps))
  def subst(value, _caps), do: value

  @doc """
  Matches `actual` against a fixture pattern (`"$any"`, `"$capture:name"`,
  `"{{name}}"`; maps need exactly the same keys, lists the same length).
  Returns `{:ok, caps}` or `{:error, message}`.
  """
  def match(pattern, actual, caps, path \\ "frame")

  def match("$any", _actual, caps, _path), do: {:ok, caps}

  def match("$capture:" <> name, actual, caps, path) do
    if is_binary(actual) and actual != "",
      do: {:ok, Map.put(caps, name, actual)},
      else: {:error, "#{path}: expected a string to capture, got #{inspect(actual)}"}
  end

  def match(pattern, actual, caps, path) when is_binary(pattern) do
    want = subst(pattern, caps)

    if actual == want,
      do: {:ok, caps},
      else: {:error, "#{path}: expected #{inspect(want)}, got #{inspect(actual)}"}
  end

  def match(pattern, actual, caps, path) when is_map(pattern) do
    pattern = Map.new(pattern, fn {k, v} -> {subst(k, caps), v} end)

    cond do
      not is_map(actual) ->
        {:error, "#{path}: expected an object, got #{inspect(actual)}"}

      Enum.sort(Map.keys(pattern)) != Enum.sort(Map.keys(actual)) ->
        {:error,
         "#{path}: expected keys #{inspect(Enum.sort(Map.keys(pattern)))}, got #{inspect(Enum.sort(Map.keys(actual)))}"}

      true ->
        pattern
        |> Enum.sort()
        |> Enum.reduce_while({:ok, caps}, fn {k, v}, {:ok, caps} ->
          case match(v, actual[k], caps, path <> "." <> k) do
            {:ok, caps} -> {:cont, {:ok, caps}}
            error -> {:halt, error}
          end
        end)
    end
  end

  def match(pattern, actual, caps, path) when is_list(pattern) do
    if is_list(actual) and length(actual) == length(pattern) do
      pattern
      |> Enum.zip(actual)
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, caps}, fn {{p, a}, i}, {:ok, caps} ->
        case match(p, a, caps, "#{path}[#{i}]") do
          {:ok, caps} -> {:cont, {:ok, caps}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, "#{path}: expected #{inspect(pattern)}, got #{inspect(actual)}"}
    end
  end

  def match(pattern, actual, caps, path) do
    if pattern == actual,
      do: {:ok, caps},
      else: {:error, "#{path}: expected #{inspect(pattern)}, got #{inspect(actual)}"}
  end

  @doc "Reads the agent's next frame and matches it, returning the captures."
  def expect(conn, pattern, caps \\ %{}) do
    got = next(conn)

    case match(pattern, got, caps) do
      {:ok, caps} -> caps
      {:error, message} -> flunk("#{message}\nagent sent: #{inspect(got)}")
    end
  end
end
