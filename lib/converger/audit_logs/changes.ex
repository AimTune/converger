defmodule Converger.AuditLogs.Changes do
  @moduledoc """
  Helpers for computing before/after change maps for audit logging.
  """

  @sensitive_fields ~w(api_key secret)

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

  def serialize(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Enum.reject(fn {_k, v} -> match?(%Ecto.Association.NotLoaded{}, v) end)
    |> Enum.map(fn {k, v} -> {to_string(k), sanitize_value(v)} end)
    |> Map.new()
    |> Map.drop(@sensitive_fields)
  end

  defp sanitize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp sanitize_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp sanitize_value(value), do: value
end
