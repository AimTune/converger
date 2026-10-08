defmodule Converger.TestDnsResolver do
  @moduledoc """
  Deterministic resolver for `Converger.Channels.UrlGuard` in tests.

  A test can override the answer for a host in its own process with
  `Converger.TestDnsResolver.put(host, result)`.
  """

  @public {93, 184, 215, 14}

  def put(host, result), do: Process.put({__MODULE__, host}, result)

  def resolve(host) do
    case Process.get({__MODULE__, host}) do
      nil -> default(host)
      result -> result
    end
  end

  defp default("localhost"), do: {:ok, [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]}
  defp default("metadata.test"), do: {:ok, [{169, 254, 169, 254}]}
  defp default("private.test"), do: {:ok, [{10, 0, 0, 5}]}
  defp default("v6private.test"), do: {:ok, [{0xFD00, 0, 0, 0, 0, 0, 0, 1}]}
  defp default("mixed.test"), do: {:ok, [@public, {192, 168, 1, 10}]}
  defp default("unresolvable.test"), do: {:error, :nxdomain}
  defp default(_host), do: {:ok, [@public]}
end
