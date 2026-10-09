defmodule Converger.TestCluster.Peer do
  @moduledoc """
  Boots Converger on extra BEAM nodes with OTP's `:peer` for the multi-node
  suite (`test/cluster`, `@moduletag :cluster`).

  The test node itself does not have to be distributed: peers are started
  with `connection: :standard_io` and controlled over their stdio, while the
  peers form a real Erlang cluster among themselves (`-name ...@127.0.0.1`,
  connected by libcluster's `Epmd` strategy, exactly like a deployment).

  Each peer gets the test node's code path and application environment,
  with these overrides:

    * `Converger.Repo` uses a real connection pool (no SQL sandbox) on a
      separate database, `<test database>_cluster`, created and migrated by
      `prepare_database/1`; the suite truncates it instead of relying on
      sandbox transactions, which cannot span nodes;
    * Oban runs real queues (`testing: :disabled`) and deliveries go through
      the Oban pipeline backend, as in production;
    * the endpoint listens on the given port;
    * rate limits use the `:cluster` backend;
    * libcluster uses `Cluster.Strategy.Epmd` with the given hosts.
  """

  # Applications whose environment is not copied to the peers.
  @skip_apps [:kernel, :stdlib, :compiler, :elixir, :mix, :ex_unit, :iex, :hex]

  @call_timeout 60_000

  @doc "A unique long node name on 127.0.0.1 for a peer."
  def node_name(prefix) do
    base = ~c"#{prefix}_#{System.get_env("MIX_TEST_PARTITION")}"
    name = :peer.random_name(base)
    {name, :"#{name}@127.0.0.1"}
  end

  @doc "The database used by the peers (separate from the sandboxed test database)."
  def database do
    Keyword.fetch!(Application.fetch_env!(:converger, Converger.Repo), :database) <> "_cluster"
  end

  @doc """
  Starts a peer named `name` and loads the code and the configuration. The
  application is not started yet (see `start_app/1`).

  Options: `:port` (HTTP port, required), `:hosts` (node names for
  libcluster, required).
  """
  def start(name, opts) do
    cookie = Atom.to_charlist(:erlang.get_cookie())

    args =
      if cookie == ~c"nocookie",
        do: [~c"-setcookie", ~c"converger_cluster_test"],
        else: [~c"-setcookie", cookie]

    {:ok, pid, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: args,
        wait_boot: 30_000
      })

    true = call(pid, :code, :set_path, [peer_code_path(pid)])

    # Load first: loading an application resets its environment to the .app
    # defaults.
    for {app, env} <- environment(opts) do
      call(pid, Application, :load, [app])
      :ok = call(pid, Application, :put_all_env, [[{app, env}]])
    end

    {pid, node}
  end

  @doc "Creates and migrates the cluster database through the peer."
  def prepare_database(pid) do
    call(pid, Converger.Release, :create_db, [])
    call(pid, Converger.Release, :migrate, [], 180_000)
    :ok
  end

  @doc "Starts the `:converger` application on the peer."
  def start_app(pid) do
    {:ok, _apps} = call(pid, Application, :ensure_all_started, [:converger])
    :ok
  end

  @doc "Empties every application table of the cluster database."
  def truncate_all(pid) do
    %{rows: rows} =
      call(pid, Converger.Repo, :query!, [
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'schema_migrations'"
      ])

    tables = Enum.map_join(rows, ", ", fn [table] -> ~s("#{table}") end)
    call(pid, Converger.Repo, :query!, ["TRUNCATE #{tables} CASCADE"])
    :ok
  end

  @doc "Runs `apply(module, fun, args)` on the peer."
  def call(pid, module, fun, args, timeout \\ @call_timeout),
    do: :peer.call(pid, module, fun, args, timeout)

  @doc "Polls `fun` until it returns a truthy value or `timeout` ms pass."
  def eventually(fun, timeout \\ 10_000, interval \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline, interval)
  end

  defp do_eventually(fun, deadline, interval) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          raise ExUnit.AssertionError, message: "condition not met in time"
        end

        Process.sleep(interval)
        do_eventually(fun, deadline, interval)
    end
  end

  # The peer's own OTP paths plus everything the test node has loaded
  # (consolidated protocols first, as on the test node).
  defp peer_code_path(pid) do
    own = call(pid, :code, :get_path, [])
    Enum.uniq(:code.get_path() ++ own)
  end

  defp environment(opts) do
    port = Keyword.fetch!(opts, :port)
    hosts = Keyword.fetch!(opts, :hosts)

    overrides = %{
      converger: [
        {Converger.Repo,
         :converger
         |> Application.fetch_env!(Converger.Repo)
         |> Keyword.merge(
           database: database(),
           pool: DBConnection.ConnectionPool,
           pool_size: 5
         )},
        {ConvergerWeb.Endpoint,
         :converger
         |> Application.fetch_env!(ConvergerWeb.Endpoint)
         |> Keyword.merge(server: true, http: [ip: {127, 0, 0, 1}, port: port])},
        {Oban,
         :converger
         |> Application.fetch_env!(Oban)
         |> Keyword.delete(:testing)
         |> Keyword.merge(testing: :disabled, plugins: [], queues: [default: 2, deliveries: 5])},
        {:pipeline, [backend: Converger.Pipeline.Oban]},
        {Converger.RateLimit,
         :converger
         |> Application.get_env(Converger.RateLimit, [])
         |> Keyword.merge(backend: :cluster, sync_interval_ms: 50)},
        {Converger.Cluster, [strategy: :epmd, options: [hosts: hosts]]},
        # The webhook sink listens on 127.0.0.1.
        {:webhook,
         :converger
         |> Application.get_env(:webhook, [])
         |> Keyword.merge(allow_private_targets: true, receive_timeout: 5_000)}
      ]
    }

    for {app, _description, _vsn} <- Application.loaded_applications(),
        app not in @skip_apps do
      env = Application.get_all_env(app)
      {app, Keyword.merge(env, Map.get(overrides, app, []))}
    end
  end
end
