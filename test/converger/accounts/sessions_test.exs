defmodule Converger.Accounts.SessionsTest do
  # One test changes the global :sessions config.
  use Converger.DataCase, async: false

  import Converger.AccountsFixtures
  import Converger.TenantsFixtures

  alias Converger.Accounts
  alias Converger.Accounts.{Sessions, UserSession}

  defp backdate(session, fields) do
    from(s in UserSession, where: s.id == ^session.id) |> Repo.update_all(set: fields)
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  setup do
    %{admin: admin_user_fixture()}
  end

  test "a session token validates to its user; only the hash is stored", %{admin: admin} do
    assert {:ok, token, session} = Sessions.create("admin", admin, %{ip: "10.0.0.1"})
    assert {:ok, %UserSession{id: id}, user} = Sessions.validate("admin", token)
    assert id == session.id and user.id == admin.id

    stored = Repo.get!(UserSession, session.id)
    assert stored.token_hash == :crypto.hash(:sha256, token)
    refute stored.token_hash == token
    assert stored.ip == "10.0.0.1"

    assert {:error, :invalid} = Sessions.validate("admin", "not-a-token")
    assert {:error, :invalid} = Sessions.validate("admin", nil)
    # a token is bound to its user type
    assert {:error, :invalid} = Sessions.validate("tenant", token)
  end

  test "tenant sessions preload the tenant" do
    tenant = tenant_fixture()
    user = tenant_user_fixture(tenant)
    {:ok, token, _} = Sessions.create("tenant", user)

    assert {:ok, _, %{tenant: %{id: tenant_id}}} = Sessions.validate("tenant", token)
    assert tenant_id == tenant.id
  end

  test "expires after the absolute lifetime even when active", %{admin: admin} do
    {:ok, token, session} = Sessions.create("admin", admin)
    backdate(session, inserted_at: ago(Sessions.max_age_seconds() + 1), last_seen_at: ago(5))

    assert {:error, :expired} = Sessions.validate("admin", token)
    refute Repo.get(UserSession, session.id)
  end

  test "expires after the idle timeout", %{admin: admin} do
    {:ok, token, session} = Sessions.create("admin", admin)
    backdate(session, last_seen_at: ago(Sessions.idle_timeout_seconds() + 1))

    assert {:error, :expired} = Sessions.validate("admin", token)
    refute Repo.get(UserSession, session.id)
  end

  test "activity bumps last_seen_at at most once a minute", %{admin: admin} do
    {:ok, token, session} = Sessions.create("admin", admin)

    backdate(session, last_seen_at: ago(30))
    {:ok, _, _} = Sessions.validate("admin", token)

    assert DateTime.diff(DateTime.utc_now(), Repo.get!(UserSession, session.id).last_seen_at) >=
             29

    backdate(session, last_seen_at: ago(Sessions.idle_timeout_seconds() - 10))
    {:ok, _, _} = Sessions.validate("admin", token)
    assert DateTime.diff(DateTime.utc_now(), Repo.get!(UserSession, session.id).last_seen_at) < 5
  end

  test "the lifetimes are configurable", %{admin: admin} do
    previous = Application.get_env(:converger, :sessions)
    Application.put_env(:converger, :sessions, max_age_seconds: 60, idle_timeout_seconds: 10)
    on_exit(fn -> Application.put_env(:converger, :sessions, previous) end)

    {:ok, token, session} = Sessions.create("admin", admin)
    backdate(session, last_seen_at: ago(11))
    assert {:error, :expired} = Sessions.validate("admin", token)
  end

  test "inactive users are rejected", %{admin: admin} do
    {:ok, token, _} = Sessions.create("admin", admin)

    Repo.update_all(from(u in Accounts.AdminUser, where: u.id == ^admin.id),
      set: [status: "inactive"]
    )

    assert {:error, :invalid} = Sessions.validate("admin", token)
  end

  test "delete_all ends every session but the kept one and disconnects LiveViews",
       %{admin: admin} do
    {:ok, keep_token, keep} = Sessions.create("admin", admin)
    {:ok, other_token, other} = Sessions.create("admin", admin)
    ConvergerWeb.Endpoint.subscribe(Sessions.live_socket_id(other))

    assert Sessions.delete_all("admin", admin.id, except: keep.id) == 1

    assert {:ok, _, _} = Sessions.validate("admin", keep_token)
    assert {:error, :invalid} = Sessions.validate("admin", other_token)
    topic = Sessions.live_socket_id(other)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  test "deactivating or deleting a user ends their sessions", %{admin: admin} do
    {:ok, token, _} = Sessions.create("admin", admin)
    {:ok, _} = Accounts.update_admin_user(admin, %{status: "inactive"})
    assert Sessions.list("admin", admin.id) == []
    assert {:error, :invalid} = Sessions.validate("admin", token)

    tenant = tenant_fixture()
    user = tenant_user_fixture(tenant)
    {:ok, _, _} = Sessions.create("tenant", user)
    {:ok, _} = Accounts.delete_tenant_user(user, %{type: "admin", id: "test"})
    assert Sessions.list("tenant", user.id) == []
  end

  test "changing the own password keeps only the current session", %{admin: admin} do
    {:ok, _, current} = Sessions.create("admin", admin)
    {:ok, other_token, _} = Sessions.create("admin", admin)

    {:ok, _} =
      Accounts.change_admin_password(
        admin,
        valid_password(),
        %{"password" => "another-strong-pass", "password_confirmation" => "another-strong-pass"},
        keep_session_id: current.id
      )

    assert [%{id: id}] = Sessions.list("admin", admin.id)
    assert id == current.id
    assert {:error, :invalid} = Sessions.validate("admin", other_token)
  end

  test "prune deletes expired sessions and disconnects them", %{admin: admin} do
    {:ok, _, fresh} = Sessions.create("admin", admin)
    {:ok, _, idle} = Sessions.create("admin", admin)
    {:ok, _, old} = Sessions.create("admin", admin)
    backdate(idle, last_seen_at: ago(Sessions.idle_timeout_seconds() + 1))
    backdate(old, inserted_at: ago(Sessions.max_age_seconds() + 1))
    ConvergerWeb.Endpoint.subscribe(Sessions.live_socket_id(idle))

    assert Sessions.prune() == 2
    assert [%{id: id}] = Sessions.list("admin", admin.id)
    assert id == fresh.id
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
  end

  test "the prune worker runs", %{admin: admin} do
    {:ok, _, idle} = Sessions.create("admin", admin)
    backdate(idle, last_seen_at: ago(Sessions.idle_timeout_seconds() + 1))

    assert :ok = perform_job(Converger.Workers.SessionPruneWorker, %{})
    assert Sessions.list("admin", admin.id) == []
  end

  defp perform_job(worker, args), do: worker.perform(%Oban.Job{args: args})
end
