# Dialyzer warnings that are known false positives. Every entry needs a
# justification; prefer fixing the code or its specs over adding entries.
[
  # Ecto.Multi.insert/update/... pipelines: on OTP 28 Dialyzer reports
  # "call_without_opaque" because Ecto.Multi's struct carries an opaque
  # :queue/MapSet internally. This is an upstream Ecto + OTP 28 issue, not a
  # bug in our code. CI runs OTP 28, where every file with such a pipeline
  # needs an entry here; OTP 27 does not emit it (mix.exs sets
  # `list_unused_filters: false` so unused filters do not fail the run).
  {"lib/converger/accounts.ex", :call_without_opaque},
  {"lib/converger/api_keys.ex", :call_without_opaque},
  {"lib/converger/accounts/password_reset.ex", :call_without_opaque},
  {"lib/converger/accounts/totp.ex", :call_without_opaque},
  {"lib/converger/channels.ex", :call_without_opaque},
  {"lib/converger/conversations.ex", :call_without_opaque},
  {"lib/converger/routing_rules.ex", :call_without_opaque},
  {"lib/converger/tenants.ex", :call_without_opaque},
  # Mint.WebSocket.new/5: Dialyzer infers that it can only return an error
  # (its success typing goes through the untyped private map of the Mint
  # connection), so it flags the {:ok, conn, websocket} branch. The branch is
  # taken on every connection (test/converger/channels/discord/gateway_test.exs).
  {"lib/converger/channels/discord/gateway.ex", :pattern_match},
  # The same false positive in the mekik adapter (#64); with the success branch
  # unreachable to Dialyzer, the hello frame helpers look unused. Both are
  # exercised on every connection (test/converger/channels/mekik_integration_test.exs).
  {"lib/converger/channels/mekik/connection.ex", :pattern_match},
  {"lib/converger/channels/mekik/connection.ex", :unused_fun}
]
