defmodule Converger.RateLimit.Local do
  @moduledoc """
  Node-local Hammer 7 rate limiter backed by an ETS table (fixed window).

  Windows are aligned to wall-clock time (`div(now_ms, scale_ms)`), which is
  what allows `Converger.RateLimit.ClusterSync` to replicate increments between
  nodes: every node agrees on which window a hit belongs to.

  Use `Converger.RateLimit` instead of calling this module directly so that
  hits are replicated when the cluster backend is enabled.
  """

  use Hammer, backend: :ets, algorithm: :fix_window
end
