# Backlog of the dead_channel scenario: `count` activities on the dead
# tenant's conversations, created through the normal code path
# (Converger.Activities.create_activity/2), so each one enqueues its delivery
# job in the same transaction, exactly as an API or inbound message would.
# Evaluated through `bin/converger rpc` by load/run.sh with the bindings
# `fixtures` (the decoded isolation.json of load/isolation_setup.exs), `count`
# and `concurrency`.
#
# Creating the backlog competes with the healthy tenant's API traffic for the
# database pool; an insert that cannot get a connection (#35) rolls back and
# is retried, so the backlog always ends up complete.
#
# Prints one JSON line: {"created": n, "retries": n, "ms": elapsed}.

%{"tenant_id" => tenant_id, "conversation_ids" => conversation_ids} = fixtures["dead"]
started = System.monotonic_time(:millisecond)

create = fn create, n, retries ->
  try do
    Converger.Activities.create_activity(%{
      tenant_id: tenant_id,
      conversation_id: Enum.at(conversation_ids, rem(n, length(conversation_ids))),
      sender: "load",
      text: "backlog #{n}"
    })
  rescue
    error in DBConnection.ConnectionError ->
      if retries >= 50, do: reraise(error, __STACKTRACE__)
      {:retry, error}
  end
  |> case do
    {:ok, _} ->
      retries

    {:retry, _} ->
      Process.sleep(200)
      create.(create, n, retries + 1)

    {:error, reason} ->
      raise "backlog activity #{n} failed: #{inspect(reason)}"
  end
end

retries =
  1..count//1
  |> Task.async_stream(fn n -> create.(create, n, 0) end,
    max_concurrency: concurrency,
    timeout: :infinity
  )
  |> Enum.reduce(0, fn {:ok, r}, acc -> acc + r end)

IO.puts(
  Jason.encode!(%{
    created: count,
    retries: retries,
    ms: System.monotonic_time(:millisecond) - started
  })
)
