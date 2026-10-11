defmodule Converger.Channels.Email.Address do
  @moduledoc """
  Email address and `Message-ID` normalization for the `email` channel
  adapter.

  A participant's external id on an email channel is the normalized address
  (`normalize/1`), so `Jane <Jane@Example.com>` and `jane@example.com` are the
  same participant. Message ids are stored without angle brackets
  (`normalize_id/1`).
  """

  @address ~r/<\s*([^<>\s]+@[^<>\s]+)\s*>/
  @bare ~r/\A[^\s<>@]+@[^\s<>@]+\z/
  @ids ~r/<([^<>\s]+)>/

  @doc """
  Split an address (`"Jane <jane@example.com>"`, `{"Jane", "jane@example.com"}`
  or a bare address) into `{display_name | nil, normalized_address}`.
  Returns `nil` when no address can be found.
  """
  @spec parse(term()) :: {String.t() | nil, String.t()} | nil
  def parse({name, address}) when is_binary(address) do
    case parse(address) do
      {_, normalized} -> {blank_to_nil(name), normalized}
      nil -> nil
    end
  end

  def parse(value) when is_binary(value) do
    value = String.trim(value)

    case Regex.run(@address, value, return: :index) do
      [{start, _}, {addr_start, addr_len}] ->
        name =
          value
          |> binary_part(0, start)
          |> String.trim()
          |> String.trim("\"")
          |> String.trim()

        {blank_to_nil(name), normalize(binary_part(value, addr_start, addr_len))}

      nil ->
        if Regex.match?(@bare, value), do: {nil, normalize(value)}, else: nil
    end
  end

  def parse(_), do: nil

  @doc "The normalized address of `value`, or `nil` (see `parse/1`)."
  def address(value) do
    case parse(value) do
      {_, address} -> address
      nil -> nil
    end
  end

  @doc """
  Every address of a header value: a list, or a comma-separated string.
  """
  def addresses(nil), do: []

  def addresses(list) when is_list(list),
    do: list |> Enum.map(&address/1) |> Enum.reject(&is_nil/1)

  def addresses(value) when is_binary(value) do
    value
    |> String.split(",")
    |> addresses()
  end

  def addresses(value), do: addresses([value])

  @doc "Lowercase and trim an address."
  def normalize(address) when is_binary(address),
    do: address |> String.trim() |> String.downcase()

  @doc "The domain of an address (`nil` without one)."
  def domain(address) when is_binary(address) do
    case String.split(address, "@") do
      [_, domain] when domain != "" -> domain
      _ -> nil
    end
  end

  def domain(_), do: nil

  @doc "A message id without angle brackets or whitespace, or `nil`."
  def normalize_id(nil), do: nil

  def normalize_id(id) when is_binary(id) do
    case id |> String.trim() |> String.trim_leading("<") |> String.trim_trailing(">") do
      "" -> nil
      id -> id
    end
  end

  def normalize_id(_), do: nil

  @doc """
  The message ids of an `In-Reply-To` / `References` header, in header
  order, normalized. Accepts a string or a list of strings.
  """
  def ids(nil), do: []
  def ids(list) when is_list(list), do: Enum.flat_map(list, &ids/1)

  def ids(value) when is_binary(value) do
    case Regex.scan(@ids, value, capture: :all_but_first) do
      [] -> value |> String.split() |> Enum.map(&normalize_id/1) |> Enum.reject(&is_nil/1)
      matches -> Enum.map(matches, fn [id] -> id end)
    end
  end

  def ids(_), do: []

  @doc "`<id>`, the header form of a normalized message id."
  def bracket(id), do: "<" <> id <> ">"

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end
end
