defmodule Converger.ApiKeys.Credential do
  @moduledoc """
  An authenticated tenant API credential (`Converger.ApiKeys.authenticate/1`,
  ADR-0061): `kind` is `:primary_key`, `:api_key` or `:channel_token`; `id`
  is the audit actor id (the key id, the tenant id for the primary key, the
  channel id for a channel token).
  """
  defstruct [:kind, :id, :api_key, scopes: []]

  @type t :: %__MODULE__{
          kind: :primary_key | :api_key | :channel_token,
          id: String.t(),
          api_key: Converger.ApiKeys.ApiKey.t() | nil,
          scopes: [String.t()]
        }
end
