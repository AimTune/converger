defmodule Converger.Encrypted.Map do
  @moduledoc "Ecto type for maps encrypted at rest with `Converger.Vault`."
  use Cloak.Ecto.Map, vault: Converger.Vault
end
