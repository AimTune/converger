defmodule Converger.Channels.Adapters.MekikTest do
  use Converger.DataCase, async: true

  import Converger.TenantsFixtures

  alias Converger.Channels
  alias Converger.Channels.Adapter
  alias Converger.Channels.Adapters.Mekik

  describe "registry and capabilities" do
    test "mekik is a registered duplex bot-relay channel type" do
      assert {:ok, Mekik} = Adapter.adapter_for("mekik")
      assert Adapter.capability?("mekik", :bot_relay)
      assert Adapter.message_types("mekik") == :all
      assert Mekik.supported_modes() == ["duplex"]
    end

    test "only the duplex mode is accepted" do
      tenant = tenant_fixture()

      attrs = %{
        name: "bot",
        type: "mekik",
        tenant_id: tenant.id,
        config: %{"url" => "wss://bot.example.com/ws"}
      }

      assert {:ok, _channel} = Channels.create_channel(attrs)

      assert {:error, changeset} =
               Channels.create_channel(%{attrs | name: "bot 2"} |> Map.put(:mode, "outbound"))

      assert %{mode: [_]} = errors_on(changeset)
    end

    test "inbound webhooks are refused" do
      assert {:error, _} = Mekik.parse_inbound(%{}, %{})
    end
  end

  describe "config validation" do
    test "a ws or wss url is required" do
      assert {:error, message} = Adapter.validate_config("mekik", %{})
      assert message =~ "url"

      assert :ok = Adapter.validate_config("mekik", %{"url" => "wss://bot.example.com/ws"})
      assert :ok = Adapter.validate_config("mekik", %{"url" => "ws://bot.example.com:8800"})

      for url <- ["https://bot.example.com", "bot.example.com", "wss://", 42] do
        assert {:error, _} = Adapter.validate_config("mekik", %{"url" => url}), inspect(url)
      end
    end

    test "credentials belong in token, not the url" do
      assert {:error, message} =
               Adapter.validate_config("mekik", %{"url" => "wss://u:p@bot.example.com/ws"})

      assert message =~ "token"
    end

    test "private targets are refused by the SSRF guard" do
      assert {:error, message} =
               Adapter.validate_config("mekik", %{"url" => "ws://127.0.0.1:8800"})

      assert message =~ "not allowed"
    end

    test "optional fields are checked" do
      base = %{"url" => "wss://bot.example.com/ws"}

      assert :ok =
               Adapter.validate_config(
                 "mekik",
                 Map.merge(base, %{
                   "token" => "t",
                   "meta" => %{"tenant" => "acme"},
                   "bot_id" => "refund-bot",
                   "idle_timeout_seconds" => "600"
                 })
               )

      assert {:error, _} = Adapter.validate_config("mekik", Map.put(base, "meta", "x"))

      assert {:error, _} =
               Adapter.validate_config("mekik", Map.put(base, "idle_timeout_seconds", 0))

      assert {:error, _} = Adapter.validate_config("mekik", Map.put(base, "bot_id", 7))
    end

    test "token is a secret field" do
      assert %{secret: true} = Enum.find(Mekik.config_schema(), &(&1.name == "token"))
    end
  end

  describe "settings" do
    test "sender and idle timeout come from the config" do
      assert Mekik.sender(%{config: %{}}) == "mekik"
      assert Mekik.sender(%{config: %{"bot_id" => "refund-bot"}}) == "refund-bot"
      assert Mekik.idle_timeout_ms(%{config: %{}}) == 300_000
      assert Mekik.idle_timeout_ms(%{config: %{"idle_timeout_seconds" => "5"}}) == 5_000
    end
  end
end
