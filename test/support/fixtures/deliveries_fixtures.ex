defmodule Converger.DeliveriesFixtures do
  @moduledoc """
  Test helpers for creating delivery records.
  """

  alias Converger.Deliveries

  def delivery_fixture(activity, channel, _attrs \\ %{}) do
    Deliveries.get_or_create_delivery(activity.id, channel.id)
  end
end
