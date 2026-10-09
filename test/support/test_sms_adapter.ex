defmodule Converger.TestSmsAdapter do
  @moduledoc """
  A channel adapter that exists only in tests, registered with
  `config :converger, :adapters` to check that one module and one config
  line are enough for a new channel type.

  Delivery succeeds with a provider message id, except for an activity whose
  text is `"reject"` (a permanent failure through `normalize_error/1`) or
  `"flaky"` (a retryable one). The health probe fails when `api_key` is
  `"bad"`.
  """

  use Converger.Channels.Adapter, type: "test_sms"

  @impl true
  def capabilities, do: [:inbound, :outbound, :external_delivery, :provider_ack]

  @impl true
  def config_schema do
    [
      %{name: "sender", type: :string, required: true, label: "Sender number", summary: true},
      %{name: "api_key", type: :string, required: true, secret: true, label: "SMS API key"},
      %{name: "signing_key", type: :string, required: :with_signature, secret: true},
      %{name: "max_parts", type: :integer, label: "Max SMS parts"}
    ]
  end

  @impl true
  def deliver_activity(_channel, %{text: "reject"}), do: {:error, :invalid_number}
  def deliver_activity(_channel, %{text: "flaky"}), do: {:error, :gateway_timeout}

  def deliver_activity(_channel, activity),
    do: {:ok, %{provider_message_id: "sms-#{activity.id}"}}

  @impl true
  def normalize_error(:invalid_number),
    do: %{reason: "invalid number", retryable?: false, retry_after_ms: nil}

  def normalize_error(reason), do: %{reason: reason, retryable?: true, retry_after_ms: 1_500}

  @impl true
  def parse_inbound(_channel, %{"from" => from, "text" => text}),
    do: {:ok, [%{"sender" => from, "text" => text, "type" => "message"}]}

  def parse_inbound(_channel, _params), do: {:error, "unable to parse test_sms payload"}

  @impl true
  def health_probe(%{config: %{"api_key" => "bad"}}), do: {:error, :unauthorized}
  def health_probe(_channel), do: :ok
end
