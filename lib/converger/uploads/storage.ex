defmodule Converger.Uploads.Storage do
  @moduledoc """
  Behaviour for file storage backends.
  """

  @type upload_result :: {:ok, %{path: String.t(), url: String.t(), size: integer()}} | {:error, term()}

  @callback store(filename :: String.t(), binary :: binary(), opts :: keyword()) :: upload_result()
  @callback url(path :: String.t()) :: String.t()
  @callback delete(path :: String.t()) :: :ok | {:error, term()}
end
