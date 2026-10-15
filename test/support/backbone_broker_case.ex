defmodule Converger.BackboneBrokerCase do
  @moduledoc """
  Setup shared by the broker backbone conformance suites (Kafka, NATS
  JetStream, RabbitMQ): a topic prefix of their own, the backbone's
  processes, and the database out of the SQL sandbox, so a consumer can be
  killed in the middle of a transaction (the zero-loss test) without taking
  the test's sandbox connection with it. Rows the suite writes are deleted
  afterwards (`Converger.BackboneConformance.cleanup_effects/1`).
  """

  import ExUnit.Callbacks

  alias Converger.Backbone.Subscription
  alias Converger.BackboneConformance
  alias Ecto.Adapters.SQL.Sandbox

  @doc """
  Configure `backbone` with `config` and a fresh topic prefix, and start its
  processes. Call from `setup_all`.
  """
  def start_backbone(backbone, config) do
    if Converger.Backbone.impl() == backbone do
      raise "run the #{inspect(backbone)} conformance suite with the default (Native) " <>
              "backbone selected: unset BACKBONE"
    end

    prefix = "it#{System.unique_integer([:positive])}"
    previous_common = Application.get_env(:converger, Converger.Backbone, [])
    previous = Application.get_env(:converger, backbone)

    Application.put_env(
      :converger,
      Converger.Backbone,
      Keyword.merge(previous_common, topic_prefix: prefix, inline_backoff_ms: 50)
    )

    Application.put_env(:converger, backbone, config)
    Sandbox.mode(Converger.Repo, :auto)

    on_exit(fn ->
      BackboneConformance.cleanup_effects("t")
      Sandbox.mode(Converger.Repo, :manual)
      Application.put_env(:converger, Converger.Backbone, previous_common)

      if previous,
        do: Application.put_env(:converger, backbone, previous),
        else: Application.delete_env(:converger, backbone)
    end)

    for spec <- backbone.child_specs(), do: start_supervised!(spec)
    %{prefix: prefix}
  end

  @doc """
  Kill a broker subscription's consumers in the middle of their work; their
  supervisor starts them again (the restart of a crashed node's consumer).
  Waits until they are back.
  """
  def kill_consumers(%Subscription{ref: names}) do
    for name <- names do
      pid = Process.whereis(name)
      Process.exit(pid, :kill)
      wait_restarted(name, pid, 100)
    end

    :ok
  end

  defp wait_restarted(name, old, 0), do: raise("#{name} was not restarted after #{inspect(old)}")

  defp wait_restarted(name, old, tries) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        :ok

      _ ->
        Process.sleep(100)
        wait_restarted(name, old, tries - 1)
    end
  end
end
