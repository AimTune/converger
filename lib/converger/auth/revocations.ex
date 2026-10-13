defmodule Converger.Auth.Revocations do
  @moduledoc """
  Revocation of Converger client tokens (issue #52, ADR-0059).

  Every Converger token carries a `jti` and a family id (`fam`): the `jti` of
  the token generated from the channel secret, inherited by every token
  derived from it (conversation tokens) or refreshed from it. Revocations are
  rows of `revoked_tokens` (`Converger.Auth.RevokedToken`), cached on every
  node (`Converger.Auth.RevocationCache`), so `check/1` never queries.

    * `revoke_family/1`: the token and every token of its family
      (`POST /api/v1/converger/tokens/revoke`, refresh-token reuse);
    * `revoke_user/3`: every token of an end user of a channel issued until
      now (a banned user);
    * `rotate/1`: a refreshed token. It stays valid for
      `:token_rotation_grace_seconds` (default 30), so requests already in
      flight with it still succeed; refreshing it again after that is reuse
      and revokes the family.

  A token without a `jti` (none are issued) cannot be revoked by family; it
  still expires.
  """

  import Ecto.Query

  alias Converger.Auth.{RevocationCache, RevokedToken}
  alias Converger.Repo

  # Longer than any token lifetime: a family or user row must outlive every
  # token it can match.
  @lifetime_leeway_seconds 60

  @doc """
  `:ok`, `{:error, :token_revoked}` when the token's family or its end user
  was revoked, or `{:error, :token_rotated}` when it was refreshed longer
  ago than the grace period.
  """
  def check(claims) when is_map(claims) do
    cond do
      revoked_family?(claims) -> {:error, :token_revoked}
      rotated?(claims) -> {:error, :token_rotated}
      revoked_user?(claims) -> {:error, :token_revoked}
      true -> :ok
    end
  end

  @doc "Revokes the token's family (the token itself and every relative)."
  def revoke_family(claims) do
    case family(claims) do
      nil ->
        {:error, :not_revocable}

      family ->
        now = DateTime.utc_now()

        upsert(%RevokedToken{
          key: "fam:" <> family,
          kind: "revoked",
          tenant_id: claims["tenant_id"],
          revoked_at: now,
          expires_at: DateTime.add(now, max_lifetime(), :second)
        })
    end
  end

  @doc """
  Revokes every token of `user_id` on `channel_id` issued up to now. Tokens
  generated afterwards for the same user are valid again.
  """
  def revoke_user(tenant_id, channel_id, user_id)
      when is_binary(channel_id) and is_binary(user_id) do
    now = DateTime.utc_now()

    upsert(%RevokedToken{
      key: user_key(channel_id, user_id),
      kind: "revoked",
      tenant_id: tenant_id,
      revoked_at: now,
      expires_at: DateTime.add(now, max_lifetime(), :second)
    })
  end

  @doc """
  Marks a token as rotated by a refresh. Returns `:ok` the first time, also
  `:ok` for a second refresh within the grace period (two tabs refreshing the
  same token at once), and `{:error, :token_reused}` after it: the family is
  revoked, because someone else holds a copy of the token.

  The row's primary key makes this atomic across nodes: of two concurrent
  refreshes exactly one inserts it.
  """
  def rotate(%{"jti" => jti} = claims) when is_binary(jti) do
    now = DateTime.utc_now()

    row = %{
      key: "jti:" <> jti,
      kind: "rotated",
      tenant_id: claims["tenant_id"],
      revoked_at: now,
      expires_at: token_expiry(claims, now)
    }

    case Repo.insert_all(RevokedToken, [row],
           on_conflict: :nothing,
           conflict_target: :key,
           returning: true
         ) do
      {1, inserted} ->
        RevocationCache.publish(inserted)

      {0, _} ->
        case Repo.get(RevokedToken, row.key) do
          %RevokedToken{kind: "rotated", revoked_at: rotated_at}
          when is_struct(rotated_at, DateTime) ->
            if DateTime.diff(now, rotated_at, :millisecond) <= grace_ms(),
              do: :ok,
              else: reused(claims)

          _ ->
            reused(claims)
        end
    end
  end

  # A token without a jti (never issued) cannot be rotated, only expire.
  def rotate(_claims), do: :ok

  @doc "Deletes rows whose tokens have all expired (`Converger.Retention.prune/1`)."
  def prune(now \\ DateTime.utc_now()) do
    {count, _} = Repo.delete_all(from(r in RevokedToken, where: r.expires_at <= ^now))
    count
  end

  @doc "The family id of a token: `fam`, or its own `jti` for the first token."
  def family(%{"fam" => family}) when is_binary(family), do: family
  def family(%{"jti" => jti}) when is_binary(jti), do: jti
  def family(_claims), do: nil

  defp reused(claims) do
    revoke_family(claims)
    {:error, :token_reused}
  end

  defp upsert(row) do
    {:ok, row} =
      Repo.insert(row,
        on_conflict: {:replace, [:kind, :revoked_at, :expires_at]},
        conflict_target: :key,
        returning: true
      )

    RevocationCache.publish([row])
  end

  defp rotated?(%{"jti" => jti}) when is_binary(jti) do
    case RevocationCache.lookup("jti:" <> jti) do
      {_kind, rotated_at} -> System.system_time(:millisecond) - rotated_at > grace_ms()
      nil -> false
    end
  end

  defp rotated?(_claims), do: false

  defp revoked_family?(claims) do
    case family(claims) do
      nil -> false
      family -> RevocationCache.lookup("fam:" <> family) != nil
    end
  end

  # Tokens issued in the same second as the revocation count as revoked:
  # `iat` has a resolution of one second.
  defp revoked_user?(%{"channel_id" => channel_id, "user_id" => user_id} = claims)
       when is_binary(channel_id) and is_binary(user_id) do
    case RevocationCache.lookup(user_key(channel_id, user_id)) do
      {_kind, revoked_at} -> not is_integer(claims["iat"]) or claims["iat"] * 1000 <= revoked_at
      nil -> false
    end
  end

  defp revoked_user?(_claims), do: false

  defp user_key(channel_id, user_id), do: "user:#{channel_id}:#{user_id}"

  defp token_expiry(%{"exp" => exp}, _now) when is_integer(exp),
    do: DateTime.from_unix!((exp + @lifetime_leeway_seconds) * 1_000_000, :microsecond)

  defp token_expiry(_claims, now), do: DateTime.add(now, max_lifetime(), :second)

  defp max_lifetime,
    do: Converger.Auth.ConvergerToken.default_expiry() + @lifetime_leeway_seconds

  defp grace_ms,
    do: Application.get_env(:converger, :token_rotation_grace_seconds, 30) * 1000
end
