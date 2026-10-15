defmodule ConvergerClient.Webhook do
  @moduledoc """
  Verification of Converger outbound webhook signatures.

  Every webhook request carries

      x-converger-signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>

  In a Phoenix or Plug app, read the raw body before JSON parsing (for
  example with a `body_reader` that keeps it in `conn.assigns`) and call:

      case ConvergerClient.Webhook.verify_signature(conn.req_headers, raw_body, secret) do
        :ok -> handle(Jason.decode!(raw_body))
        {:error, reason} -> send_resp(conn, 401, Atom.to_string(reason))
      end

  The rules and the test vectors are in
  `packages/conformance/webhook-signatures.json`.
  """

  @header "x-converger-signature"
  @default_tolerance 300

  @type reason ::
          :missing_signature
          | :no_secret
          | :malformed_signature
          | :timestamp_out_of_tolerance
          | :invalid_signature

  @doc "The header that carries the signature."
  def header, do: @header

  @doc "Builds an `x-converger-signature` value (useful for tests)."
  @spec sign(String.t(), iodata(), integer()) :: String.t()
  def sign(secret, body, timestamp \\ System.system_time(:second)) do
    "t=#{timestamp},v1=#{hmac(secret, timestamp, body)}"
  end

  @doc """
  Verifies a webhook request.

  `headers` is a list of `{name, value}` (as in `conn.req_headers`) or a map;
  names are matched case-insensitively. `body` is the raw body. `secret` is
  the channel secret, or a list of secrets while rotating.

  Options: `:tolerance` (seconds, default 300), `:now` (unix seconds, for tests).
  """
  @spec verify_signature(Enumerable.t(), iodata(), String.t() | [String.t()], keyword()) ::
          :ok | {:error, reason()}
  def verify_signature(headers, body, secret, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)
    secrets = secret |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))

    with {:ok, value} <- fetch_header(headers),
         :ok <- if(secrets == [], do: {:error, :no_secret}, else: :ok),
         {:ok, t, v1} <- parse(value),
         :ok <- if(abs(now - t) > tolerance, do: {:error, :timestamp_out_of_tolerance}, else: :ok) do
      matches =
        for s <- secrets, candidate <- v1 do
          Plug.Crypto.secure_compare(hmac(s, t, body), candidate)
        end

      if Enum.any?(matches), do: :ok, else: {:error, :invalid_signature}
    end
  end

  @doc "Like `verify_signature/4`, but returns a boolean."
  @spec valid_signature?(Enumerable.t(), iodata(), String.t() | [String.t()], keyword()) ::
          boolean()
  def valid_signature?(headers, body, secret, opts \\ []),
    do: verify_signature(headers, body, secret, opts) == :ok

  defp hmac(secret, t, body) do
    :crypto.mac(:hmac, :sha256, secret, [Integer.to_string(t), ".", body])
    |> Base.encode16(case: :lower)
  end

  defp fetch_header(headers) do
    value =
      Enum.find_value(headers, fn {k, v} ->
        if String.downcase(to_string(k)) == @header, do: v
      end)

    case value do
      nil -> {:error, :missing_signature}
      "" -> {:error, :missing_signature}
      [v | _] -> {:ok, v}
      v -> {:ok, v}
    end
  end

  defp parse(value) do
    pairs =
      value
      |> String.split(",", trim: true)
      |> Enum.flat_map(fn part ->
        case String.split(String.trim(part), "=", parts: 2) do
          [k, v] -> [{k, v}]
          _ -> []
        end
      end)

    t = Enum.find_value(pairs, fn {k, v} -> if k == "t", do: v end)
    v1 = for {"v1", v} <- pairs, do: v

    with ts when is_binary(ts) <- t,
         true <- ts =~ ~r/^[+-]?[0-9]+$/,
         {int, ""} <- Integer.parse(ts),
         [_ | _] <- v1 do
      {:ok, int, v1}
    else
      _ -> {:error, :malformed_signature}
    end
  end
end
