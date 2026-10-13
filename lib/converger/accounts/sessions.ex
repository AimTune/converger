defmodule Converger.Accounts.Sessions do
  @moduledoc """
  Server-side sessions for the admin panel and the tenant portal (issue #52,
  ADR-0058).

  A login creates a `user_sessions` row and returns a random 32-byte token.
  The token goes into the signed session cookie; only its SHA-256 is stored.
  Every request (`ConvergerWeb.Plugs.Auth`) and LiveView mount
  (`ConvergerWeb.Live.AuthHooks`) validates the token with `validate/3`:

    * the row must exist (logout, "log out everywhere", password changes and
      account deactivation delete rows);
    * it must be younger than the absolute lifetime (`max_age_seconds/0`,
      env `SESSION_MAX_AGE_SECONDS`, default 12 hours);
    * it must have been used within the idle timeout
      (`idle_timeout_seconds/0`, env `SESSION_IDLE_TIMEOUT_SECONDS`, default
      30 minutes). `last_seen_at` is bumped at most once a minute.

  The session's LiveViews connect with the socket id `live_socket_id/1`;
  deleting a session broadcasts `"disconnect"` to it, which closes them.
  Expired rows are deleted by `prune/1` (`Converger.Workers.SessionPruneWorker`).

      config :converger, :sessions,
        max_age_seconds: 43_200,
        idle_timeout_seconds: 1_800
  """

  import Ecto.Query, warn: false

  alias Converger.Accounts.{AdminUser, TenantUser, UserSession}
  alias Converger.Repo

  @user_types ~w(admin tenant)
  @touch_interval_seconds 60

  @type user_type :: String.t()

  @doc "Absolute session lifetime in seconds."
  @spec max_age_seconds() :: pos_integer()
  def max_age_seconds, do: config(:max_age_seconds, 43_200)

  @doc "Idle timeout in seconds."
  @spec idle_timeout_seconds() :: pos_integer()
  def idle_timeout_seconds, do: config(:idle_timeout_seconds, 1_800)

  defp config(key, default) do
    case Application.get_env(:converger, :sessions, [])[key] do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  @doc "The LiveView socket id of a session (`\"user_sessions:<id>\"`)."
  @spec live_socket_id(UserSession.t() | String.t()) :: String.t()
  def live_socket_id(%UserSession{id: id}), do: live_socket_id(id)
  def live_socket_id(id) when is_binary(id), do: "user_sessions:" <> id

  @doc """
  Creates a session for `user`. `info` may carry `:ip` and `:user_agent`.
  Returns `{:ok, token, session}`; the token is shown only here.
  """
  @spec create(user_type(), AdminUser.t() | TenantUser.t(), map()) ::
          {:ok, String.t(), UserSession.t()}
  def create(user_type, %{id: user_id}, info \\ %{}) when user_type in @user_types do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    now = DateTime.utc_now()

    session =
      Repo.insert!(%UserSession{
        user_type: user_type,
        user_id: user_id,
        token_hash: hash(token),
        ip: info[:ip],
        user_agent: truncate(info[:user_agent], 512),
        inserted_at: now,
        last_seen_at: now
      })

    {:ok, token, session}
  end

  @doc """
  Validates a session token of `user_type`. Returns `{:ok, session, user}`
  (an active user; tenant users with their tenant preloaded) or
  `{:error, :invalid | :expired}`. Expired rows are deleted. Bumps
  `last_seen_at` when it is older than a minute.

  Options: `:now` (default `DateTime.utc_now/0`).
  """
  @spec validate(user_type(), String.t() | nil, keyword()) ::
          {:ok, UserSession.t(), AdminUser.t() | TenantUser.t()} | {:error, :invalid | :expired}
  def validate(user_type, token, opts \\ [])

  def validate(user_type, token, opts) when user_type in @user_types and is_binary(token) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with %UserSession{} = session <-
           Repo.get_by(UserSession, token_hash: hash(token), user_type: user_type),
         :ok <- check_expiry(session, now),
         {:ok, user} <- load_user(user_type, session.user_id) do
      {:ok, touch(session, now), user}
    else
      nil -> {:error, :invalid}
      {:error, _} = error -> error
    end
  end

  def validate(_user_type, _token, _opts), do: {:error, :invalid}

  defp check_expiry(session, now) do
    if expired?(session, now) do
      delete_sessions(from(s in UserSession, where: s.id == ^session.id))
      {:error, :expired}
    else
      :ok
    end
  end

  @doc "True when the session is past its absolute lifetime or idle timeout."
  @spec expired?(UserSession.t(), DateTime.t()) :: boolean()
  def expired?(%UserSession{} = session, now \\ DateTime.utc_now()) do
    DateTime.diff(now, session.inserted_at) >= max_age_seconds() or
      DateTime.diff(now, session.last_seen_at) >= idle_timeout_seconds()
  end

  defp load_user(user_type, user_id) do
    case get_user(user_type, user_id) do
      %{status: "active"} = user -> {:ok, user}
      _ -> {:error, :invalid}
    end
  end

  defp get_user("admin", id), do: Repo.get(AdminUser, id)

  defp get_user("tenant", id) do
    case Repo.get(TenantUser, id) do
      nil -> nil
      user -> Repo.preload(user, :tenant)
    end
  end

  defp touch(session, now) do
    if DateTime.diff(now, session.last_seen_at) >= @touch_interval_seconds do
      from(s in UserSession, where: s.id == ^session.id)
      |> Repo.update_all(set: [last_seen_at: now])

      %{session | last_seen_at: now}
    else
      session
    end
  end

  @doc "The sessions of a user, newest first."
  @spec list(user_type(), binary()) :: [UserSession.t()]
  def list(user_type, user_id) do
    from(s in UserSession,
      where: s.user_type == ^user_type and s.user_id == ^user_id,
      order_by: [desc: s.inserted_at, desc: s.id]
    )
    |> Repo.all()
  end

  @doc "Deletes the session of `token` (logout)."
  @spec delete_by_token(user_type(), String.t() | nil) :: non_neg_integer()
  def delete_by_token(user_type, token) when is_binary(token) do
    delete_sessions(
      from(s in UserSession, where: s.user_type == ^user_type and s.token_hash == ^hash(token))
    )
  end

  def delete_by_token(_user_type, _token), do: 0

  @doc "Deletes one session of a user (revoke a single device)."
  @spec delete(user_type(), binary(), binary()) :: non_neg_integer()
  def delete(user_type, user_id, session_id) do
    case Ecto.UUID.cast(session_id) do
      {:ok, session_id} ->
        delete_sessions(
          from(s in UserSession,
            where: s.user_type == ^user_type and s.user_id == ^user_id and s.id == ^session_id
          )
        )

      :error ->
        0
    end
  end

  @doc """
  Deletes all sessions of a user ("log out everywhere", password change,
  deactivation, deletion) and disconnects their LiveViews. Option
  `:except` keeps one session id (the caller's own). Returns the count.
  """
  @spec delete_all(user_type(), binary(), keyword()) :: non_neg_integer()
  def delete_all(user_type, user_id, opts \\ []) do
    query = from(s in UserSession, where: s.user_type == ^user_type and s.user_id == ^user_id)

    query =
      case Keyword.get(opts, :except) do
        nil -> query
        except_id -> from(s in query, where: s.id != ^except_id)
      end

    delete_sessions(query)
  end

  @doc """
  Deletes sessions past their absolute lifetime or idle timeout and
  disconnects their LiveViews. Returns the count.
  """
  @spec prune(keyword()) :: non_neg_integer()
  def prune(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    created_before = DateTime.add(now, -max_age_seconds(), :second)
    seen_before = DateTime.add(now, -idle_timeout_seconds(), :second)

    delete_sessions(
      from(s in UserSession,
        where: s.inserted_at <= ^created_before or s.last_seen_at <= ^seen_before
      )
    )
  end

  defp delete_sessions(query) do
    {count, ids} = Repo.delete_all(from(s in query, select: s.id))
    Enum.each(ids, &disconnect/1)
    count
  end

  # Same message as ConvergerWeb.Endpoint.broadcast/3: closes every LiveView
  # connected with this session's live_socket_id.
  # Skipped when PubSub is not running (release tasks run without the app).
  defp disconnect(session_id) do
    topic = live_socket_id(session_id)

    if Process.whereis(Converger.PubSub) do
      Phoenix.PubSub.broadcast(Converger.PubSub, topic, %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "disconnect",
        payload: %{}
      })
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp truncate(nil, _), do: nil
  defp truncate(value, max) when is_binary(value), do: String.slice(value, 0, max)
end
