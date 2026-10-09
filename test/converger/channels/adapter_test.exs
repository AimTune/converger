defmodule Converger.Channels.AdapterTest do
  # Mutates the :adapters and :channel_health app env.
  use Converger.DataCase, async: false

  alias Converger.Channels
  alias Converger.Channels.{Adapter, DeliveryError, Health}
  alias Converger.Deliveries

  import Converger.TenantsFixtures
  import Converger.ConversationsFixtures
  import Converger.ActivitiesFixtures

  @builtin ~w(echo webhook websocket whatsapp_meta whatsapp_infobip)

  defp put_env(key, value) do
    previous = Application.get_env(:converger, key)
    Application.put_env(:converger, key, value)
    on_exit(fn -> Application.put_env(:converger, key, previous) end)
  end

  defp register_test_adapter(_context) do
    put_env(:adapters, [Converger.TestSmsAdapter])
    :ok
  end

  defp sms_channel(tenant, attrs \\ %{}) do
    Channels.create_channel(
      Enum.into(attrs, %{
        name: "sms-#{System.unique_integer([:positive])}",
        type: "test_sms",
        mode: "duplex",
        status: "active",
        require_signature: false,
        tenant_id: tenant.id,
        config: %{"sender" => "+15550100", "api_key" => "key"}
      })
    )
  end

  describe "built-in registry" do
    test "lists the built-in types in order" do
      assert Adapter.types() == @builtin
      assert Channels.Channel.channel_types() == @builtin
    end

    test "derives the externally delivering types from capabilities" do
      assert Adapter.types_with(:external_delivery) == ~w(webhook whatsapp_meta whatsapp_infobip)
      assert Adapter.types_with(:provider_ack) == ~w(whatsapp_meta whatsapp_infobip)
      assert Adapter.types_with(:lifecycle_events) == ~w(webhook websocket)
    end

    test "derives supported modes from capabilities" do
      assert Adapter.supported_modes("echo") == ~w(outbound)
      assert Adapter.supported_modes("webhook") == ~w(inbound outbound duplex)
    end

    test "rejects unknown and non-string types" do
      assert {:error, "unknown channel type: sms"} = Adapter.adapter_for("sms")
      assert {:error, _} = Adapter.adapter_for(nil)
      assert Adapter.capabilities("sms") == []
      assert Adapter.config_schema("sms") == []
    end

    test "every built-in passes the boot check" do
      assert Adapter.validate_registry!() == :ok
    end
  end

  describe "validate_registry!/0" do
    test "raises for a configured module that is not an adapter" do
      put_env(:adapters, [String])

      assert_raise ArgumentError, ~r/String does not implement type\/0/, fn ->
        Adapter.validate_registry!()
      end
    end

    test "raises for a module that does not exist" do
      put_env(:adapters, [Converger.NoSuchAdapter])

      assert_raise ArgumentError, ~r/is not an available module/, fn ->
        Adapter.validate_registry!()
      end
    end
  end

  describe "a configured adapter" do
    setup :register_test_adapter

    test "is registered after the built-ins" do
      assert Adapter.types() == @builtin ++ ["test_sms"]
      assert Adapter.validate_registry!() == :ok
      assert Adapter.supported_modes("test_sms") == ~w(inbound outbound duplex)
      assert "test_sms" in Adapter.types_with(:external_delivery)
    end

    test "channels of its type are created and validated against its schema" do
      tenant = tenant_fixture()

      assert {:ok, channel} = sms_channel(tenant)
      assert channel.type == "test_sms"

      assert {:error, changeset} = sms_channel(tenant, %{config: %{"sender" => ""}})
      assert {"test_sms config missing: sender, api_key", _} = changeset.errors[:config]

      assert {:error, changeset} =
               sms_channel(tenant, %{
                 config: %{"sender" => "1", "api_key" => "k", "max_parts" => "many"}
               })

      assert {"test_sms config 'max_parts' must be an integer", _} = changeset.errors[:config]
    end

    test "fields required with signatures are required only on signed channels" do
      tenant = tenant_fixture()

      assert {:error, changeset} = sms_channel(tenant, %{require_signature: true})
      assert {msg, _} = changeset.errors[:config]
      assert msg =~ "signing_key (required when require_signature is true)"

      config = %{"sender" => "1", "api_key" => "k", "signing_key" => "s"}
      assert {:ok, _} = sms_channel(tenant, %{require_signature: true, config: config})
    end

    test "its channels get health checks, decided by the probe while idle" do
      put_env(:channel_health, probe_idle_channels: true)
      tenant = tenant_fixture()
      {:ok, good} = sms_channel(tenant)
      {:ok, bad} = sms_channel(tenant, %{config: %{"sender" => "1", "api_key" => "bad"}})

      assert good.id in Enum.map(Health.list_monitored_channels(), & &1.id)

      Health.check_all_channels()

      assert Health.get_latest_health(good.id).status == "healthy"
      assert Health.get_latest_health(bad.id).status == "degraded"
    end

    test "idle channels stay unknown when probes are disabled" do
      put_env(:channel_health, probe_idle_channels: false)
      {:ok, channel} = sms_channel(tenant_fixture())

      Health.check_all_channels()

      assert Health.get_latest_health(channel.id).status == "unknown"
    end

    test "the pipeline delivers to its channels and keeps the provider message id" do
      tenant = tenant_fixture()
      {:ok, channel} = sms_channel(tenant)
      conversation = conversation_fixture(tenant, channel)

      activity = activity_fixture(tenant, conversation, %{text: "hello"})

      delivery = Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)
      assert delivery.status == "sent"
      assert delivery.provider_message_id == "sms-#{activity.id}"
    end

    test "its normalize_error/1 classifies failures for the retry policy" do
      tenant = tenant_fixture()
      {:ok, channel} = sms_channel(tenant)
      conversation = conversation_fixture(tenant, channel)

      activity = activity_fixture(tenant, conversation, %{text: "reject"})

      delivery = Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)
      assert delivery.status == "failed"
      assert delivery.attempts == 1
      assert delivery.last_error == "invalid number"

      assert %DeliveryError{retryable?: true, retry_after_ms: 1_500, reason: :gateway_timeout} =
               Adapter.normalize_error(channel, :gateway_timeout)
    end
  end

  describe "normalize_error/2 defaults" do
    test "keeps a DeliveryError and makes anything else retryable" do
      permanent = DeliveryError.permanent("nope")
      assert Adapter.normalize_error(%{type: "webhook"}, permanent) == permanent

      assert %DeliveryError{reason: :boom, retryable?: true, retry_after_ms: nil} =
               Adapter.normalize_error(%{type: "webhook"}, :boom)

      assert %DeliveryError{reason: :boom} = Adapter.normalize_error(%{type: "nope"}, :boom)
    end

    test "turns a classification map into a DeliveryError" do
      assert %DeliveryError{reason: "x", retryable?: false, retry_after_ms: 10} =
               DeliveryError.normalize(%{reason: "x", retryable?: false, retry_after_ms: 10})
    end
  end

  describe "validate_schema/4" do
    @schema [
      %{name: "url", type: :url, required: true},
      %{name: "enabled", type: :boolean},
      %{name: "headers", type: :map}
    ]

    test "checks presence and value types, and allows unknown keys" do
      assert Adapter.validate_schema("t", @schema, %{"url" => "https://a.example", "x" => 1}) ==
               :ok

      assert {:error, "t config missing: url"} = Adapter.validate_schema("t", @schema, %{})

      assert {:error, "t config 'url' must be a valid HTTP/HTTPS URL"} =
               Adapter.validate_schema("t", @schema, %{"url" => "ftp://a.example"})

      assert {:error, "t config 'enabled' must be true or false"} =
               Adapter.validate_schema("t", @schema, %{
                 "url" => "https://a.example",
                 "enabled" => "yes"
               })

      assert {:error, "t config 'headers' must be a map"} =
               Adapter.validate_schema("t", @schema, %{
                 "url" => "https://a.example",
                 "headers" => "x"
               })
    end
  end

  describe "verify_subscription/2" do
    test "answers 200 ok for adapters without a handshake" do
      assert Adapter.verify_subscription(%{type: "webhook", config: %{}}, %{}) == {:ok, "ok"}
    end

    test "echoes Meta's challenge only for the right verify token" do
      channel = %{type: "whatsapp_meta", config: %{"verify_token" => "vt"}}
      params = %{"hub.verify_token" => "vt", "hub.challenge" => "42"}

      assert Adapter.verify_subscription(channel, params) == {:ok, "42"}

      assert Adapter.verify_subscription(channel, %{params | "hub.verify_token" => "no"}) ==
               :error
    end
  end
end
