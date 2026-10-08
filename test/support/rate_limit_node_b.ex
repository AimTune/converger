defmodule Converger.RateLimit.NodeB do
  @moduledoc """
  A second Hammer ETS table used by the cluster sync tests to stand in for the
  counters of another node.
  """

  use Hammer, backend: :ets, algorithm: :fix_window
end
