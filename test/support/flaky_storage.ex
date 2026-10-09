defmodule Converger.FlakyStorage do
  @moduledoc """
  Test storage backend: `Converger.Uploads.LocalStorage` with injectable
  failures, selected by the `:fail` option in the storage config:

    * `:put` - every upload fails
    * `:corrupt_get` - downloads return different bytes (checksum mismatch)
    * `nil` - behaves like local storage
  """
  @behaviour Converger.Uploads.Storage

  alias Converger.Uploads.LocalStorage

  @impl true
  def put(config, key, binary, opts \\ []) do
    case config[:fail] do
      :put -> {:error, :simulated_outage}
      _ -> LocalStorage.put(config, key, binary, opts)
    end
  end

  @impl true
  def get(config, key) do
    case {config[:fail], LocalStorage.get(config, key)} do
      {:corrupt_get, {:ok, body}} -> {:ok, :binary.copy(<<0>>, byte_size(body))}
      {_, result} -> result
    end
  end

  @impl true
  def delete(config, key), do: LocalStorage.delete(config, key)

  @impl true
  def signed_get_url(_config, _key, _opts), do: {:error, :unsupported}

  @impl true
  def presigned_put_url(_config, _key, _opts), do: {:error, :unsupported}
end
