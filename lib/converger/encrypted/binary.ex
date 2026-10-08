defmodule Converger.Encrypted.Binary do
  @moduledoc "Ecto type for strings/binaries encrypted at rest with `Converger.Vault`."
  use Cloak.Ecto.Binary, vault: Converger.Vault
end
