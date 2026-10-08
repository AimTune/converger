defmodule Converger.AuditLogs.Changes do
  @moduledoc """
  Helpers for computing before/after change maps for audit logging.

  Sensitive values (secrets, tokens, API keys, hashes, ...) are replaced
  with `"[REDACTED]"` recursively, including inside nested maps such as
  `channels.config`. See `Converger.Secrets.sensitive_key?/1`.
  """

  alias Converger.Secrets

  def for_create(resource) do
    %{"before" => nil, "after" => serialize(resource)}
  end

  def for_update(before, after_resource) do
    %{"before" => serialize(before), "after" => serialize(after_resource)}
  end

  def for_delete(resource) do
    %{"before" => serialize(resource), "after" => nil}
  end

  def serialize(nil), do: nil

  def serialize(%{__struct__: module} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__ | associations(module)])
    |> Enum.reject(fn {_k, v} -> match?(%Ecto.Association.NotLoaded{}, v) end)
    |> Map.new(fn {k, v} -> {to_string(k), sanitize_value(v)} end)
    |> Secrets.redact()
  end

  # Associations are audited as their own resources; serializing preloaded
  # structs here could leak their secrets and is not JSON-encodable.
  defp associations(module) do
    if function_exported?(module, :__schema__, 1), do: module.__schema__(:associations), else: []
  end

  defp sanitize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp sanitize_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp sanitize_value(%Date{} = d), do: Date.to_iso8601(d)
  defp sanitize_value(value), do: value
end
