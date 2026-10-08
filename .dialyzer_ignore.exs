# Dialyzer warnings that are known false positives. Every entry needs a
# justification; prefer fixing the code or its specs over adding entries.
[
  # Ecto.Multi.insert/update/... pipelines: on OTP 28 Dialyzer reports
  # "call_without_opaque" because Ecto.Multi's struct carries an opaque
  # :queue/MapSet internally. This is an upstream Ecto + OTP 28 issue, not a
  # bug in our code. OTP 27, which CI uses, does not emit it, so these filters
  # are unused there (mix.exs sets `list_unused_filters: false` so that does
  # not fail the run).
  {"lib/converger/accounts.ex", :call_without_opaque},
  {"lib/converger/channels.ex", :call_without_opaque},
  {"lib/converger/routing_rules.ex", :call_without_opaque},
  {"lib/converger/tenants.ex", :call_without_opaque}
]
