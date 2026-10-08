defmodule Converger.Pipeline.ChannelRetryPolicyTest do
  # Mutates global pipeline/adapter config, so it cannot run async.
  use Converger.DataCase, async: false
  use Oban.Testing, repo: Converger.Repo

  alias Converger.{Activities, Channels, Deliveries}
  alias Converger.Channels.DeliveryError
  alias Converger.Pipeline.RetryPolicy
  alias Converger.Workers.ActivityDeliveryWorker

  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures
  import Converger.ConversationsFixtures

  setup do
    for key <- [:pipeline, :webhook_req_options] do
      previous = Application.get_env(:converger, key)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:converger, key, previous),
          else: Application.delete_env(:converger, key)
      end)
    end

    Application.put_env(:converger, :pipeline, backend: Converger.Pipeline.Oban)

    Application.put_env(:converger, :webhook_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    %{tenant: tenant_fixture()}
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, fun)

  defp create_activity(tenant, channel) do
    conversation = conversation_fixture(tenant, channel)

    {:ok, activity} =
      Activities.create_activity(%{
        sender: "user-1",
        text: "hello",
        tenant_id: tenant.id,
        conversation_id: conversation.id
      })

    activity
  end

  defp delivery(activity, channel),
    do: Deliveries.get_delivery_for_activity_and_channel(activity.id, channel.id)

  defp job_for(activity) do
    Repo.one!(
      from(j in Oban.Job,
        where: j.worker == ^inspect(ActivityDeliveryWorker),
        where: fragment("?->>'activity_id' = ?", j.args, ^activity.id)
      )
    )
  end

  describe "provider-directed retries" do
    test "429 with Retry-After: 30 schedules the next attempt in ~30s", %{tenant: tenant} do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.send_resp(429, "slow down")
      end)

      channel = webhook_channel_fixture(tenant)

      Oban.Testing.with_testing_mode(:manual, fn ->
        activity = create_activity(tenant, channel)
        before = DateTime.utc_now()

        assert %{failure: 1} = Oban.drain_queue(queue: :deliveries)

        job = job_for(activity)
        assert job.state == "retryable"
        delay = DateTime.diff(job.scheduled_at, before, :second)
        assert delay in 29..32

        assert %{status: "pending", attempts: 1} = delivery(activity, channel)
      end)
    end

    test "400 invalid recipient ends in failed after one attempt", %{tenant: tenant} do
      stub(fn conn ->
        Plug.Conn.send_resp(conn, 400, ~s({"error":"invalid recipient"}))
      end)

      channel = webhook_channel_fixture(tenant)

      Oban.Testing.with_testing_mode(:manual, fn ->
        activity = create_activity(tenant, channel)

        assert %{cancelled: 1} = Oban.drain_queue(queue: :deliveries, with_scheduled: true)

        assert %{status: "failed", attempts: 1, last_error: error} = delivery(activity, channel)
        assert error =~ "400"
        assert [_] = Deliveries.list_dead_letters(%{channel_id: channel.id})
      end)
    end

    test "WhatsApp delivery without a recipient is permanent", %{tenant: tenant} do
      channel =
        channel_fixture(tenant, %{
          type: "whatsapp_meta",
          mode: "outbound",
          require_signature: false,
          config: %{"phone_number_id" => "1", "access_token" => "t", "verify_token" => "v"}
        })

      Oban.Testing.with_testing_mode(:manual, fn ->
        activity = create_activity(tenant, channel)
        assert %{cancelled: 1} = Oban.drain_queue(queue: :deliveries, with_scheduled: true)
        assert %{status: "failed", attempts: 1} = delivery(activity, channel)
      end)
    end
  end

  describe "per-channel policy" do
    test "max_attempts and backoff come from the channel", %{tenant: tenant} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)

      channel =
        webhook_channel_fixture(tenant, %{
          retry_policy: %{"max_attempts" => 2, "backoff" => "fixed", "base_ms" => 7_000}
        })

      Oban.Testing.with_testing_mode(:manual, fn ->
        activity = create_activity(tenant, channel)
        before = DateTime.utc_now()

        assert %{failure: 1} = Oban.drain_queue(queue: :deliveries)
        assert DateTime.diff(job_for(activity).scheduled_at, before, :second) in 6..9

        assert %{cancelled: 1} = Oban.drain_queue(queue: :deliveries, with_scheduled: true)
        assert %{status: "failed", attempts: 2} = delivery(activity, channel)
      end)
    end

    test "policy resolution: global < adapter < channel" do
      policy = RetryPolicy.for_channel(%{type: "webhook", retry_policy: %{"max_attempts" => 9}})

      assert policy.max_attempts == 9
      # Adapter default for webhooks.
      assert policy.timeout_ms == 10_000
      assert policy.backoff == :exponential

      assert RetryPolicy.for_channel(%{type: "whatsapp_meta", retry_policy: %{}}).timeout_ms ==
               15_000
    end

    test "backoff strategies are capped by max_ms" do
      base = %RetryPolicy{base_ms: 1_000, max_ms: 20_000}

      assert RetryPolicy.backoff_ms(%{base | backoff: :exponential}, 2) == 9_000
      assert RetryPolicy.backoff_ms(%{base | backoff: :exponential}, 5) == 20_000
      assert RetryPolicy.backoff_ms(%{base | backoff: :linear}, 3) == 3_000
      assert RetryPolicy.backoff_ms(%{base | backoff: :fixed}, 4) == 1_000
    end

    test "invalid channel policies are rejected", %{tenant: tenant} do
      for policy <- [
            %{"backoff" => "random"},
            %{"max_attempts" => 0},
            %{"base_ms" => "fast"},
            %{"nope" => 1}
          ] do
        assert {:error, changeset} =
                 Channels.create_channel(%{
                   name: "bad #{System.unique_integer()}",
                   tenant_id: tenant.id,
                   type: "webhook",
                   mode: "outbound",
                   config: %{"url" => "https://example.com/hook"},
                   retry_policy: policy
                 })

        assert %{retry_policy: [_]} = errors_on(changeset)
      end
    end
  end

  describe "DeliveryError" do
    test "classifies HTTP statuses" do
      refute DeliveryError.from_http(400, %{}, "").retryable?
      refute DeliveryError.from_http(401, %{}, "").retryable?
      refute DeliveryError.from_http(404, %{}, "").retryable?
      assert DeliveryError.from_http(408, %{}, "").retryable?
      assert DeliveryError.from_http(429, %{}, "").retryable?
      assert DeliveryError.from_http(502, %{}, "").retryable?
      assert DeliveryError.from_transport(:timeout).retryable?
    end

    test "parses Retry-After seconds and HTTP dates" do
      assert DeliveryError.retry_after_ms(%{"retry-after" => ["30"]}) == 30_000
      assert DeliveryError.retry_after_ms([{"Retry-After", "5"}]) == 5_000
      assert DeliveryError.retry_after_ms(%{}) == nil
      assert DeliveryError.retry_after_ms(%{"retry-after" => ["soon"]}) == nil

      future =
        DateTime.utc_now()
        |> DateTime.add(60, :second)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      assert DeliveryError.retry_after_ms(%{"retry-after" => [future]}) in 55_000..61_000
    end
  end

  describe "Lifeline" do
    test "is configured" do
      plugins = Application.fetch_env!(:converger, Oban)[:plugins]
      assert Enum.any?(plugins, &match?({Oban.Plugins.Lifeline, _}, &1))
    end

    test "orphaned executing jobs are rescued after a simulated crash" do
      # A node died mid-delivery: the job is stuck `executing` forever.
      {:ok, job} =
        %{activity_id: Ecto.UUID.generate(), channel_id: Ecto.UUID.generate()}
        |> ActivityDeliveryWorker.new()
        |> Ecto.Changeset.change(
          state: "executing",
          attempt: 1,
          attempted_at: DateTime.add(DateTime.utc_now(), -2, :hour)
        )
        |> Repo.insert()

      # Run the same rescue Lifeline runs, against a real (non-inline) engine.
      conf = Oban.Config.new(repo: Repo, engine: Oban.Engines.Basic, testing: :disabled)
      {:ok, _} = Oban.Engine.rescue_jobs(conf, Oban.Job, rescue_after: :timer.minutes(30))

      assert Repo.reload!(job).state == "available"
    end
  end
end
