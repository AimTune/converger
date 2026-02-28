defmodule Converger.HealthCheckFixtures do
  @moduledoc """
  Test helpers for creating channel health check records.
  """

  alias Converger.Repo
  alias Converger.Channels.HealthCheck

  def health_check_fixture(channel, attrs \\ %{}) do
    {:ok, health_check} =
      %HealthCheck{}
      |> HealthCheck.changeset(
        Map.merge(
          %{
            channel_id: channel.id,
            status: "healthy",
            total_deliveries: 10,
            failed_deliveries: 0,
            failure_rate: 0.0,
            checked_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
          },
          attrs
        )
      )
      |> Repo.insert()

    health_check
  end
end
