defmodule Converger.VaultTest do
  # Guards the `ignore_advisories` entries for cloak / cloak_ecto in mix.exs:
  # they are only safe while the affected code paths stay unused.
  use ExUnit.Case, async: true

  test "the vault only uses authenticated AES-GCM ciphers (EEF-CVE-2026-95105)" do
    {:ok, config} =
      :converger
      |> Application.get_env(Converger.Vault, [])
      |> Keyword.put(:retired_keys, [Converger.Vault.generate_key()])
      |> Converger.Vault.init()

    ciphers = Keyword.fetch!(config, :ciphers)
    assert length(ciphers) == 2

    for {_label, {module, _opts}} <- ciphers do
      assert module == Cloak.Ciphers.AES.GCM
    end
  end

  test "affected Cloak modules are not used anywhere (EEF-CVE-2026-95105, -94206)" do
    offenders =
      for path <- Path.wildcard("{lib,config}/**/*.{ex,exs}"),
          source = File.read!(path),
          module <- ["Cloak.Ciphers.AES.CTR", "Cloak.Ecto.PBKDF2"],
          String.contains?(source, module),
          do: {path, module}

    assert offenders == []
  end
end
