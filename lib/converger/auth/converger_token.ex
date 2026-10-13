defmodule Converger.Auth.ConvergerToken do
  @moduledoc """
  Converger client tokens (JWT, HS256), held by end users and agent consoles.

  Claims (ADR-0059 for `jti`, `fam`, `perms` and the `kid` header):

    * `type: "converger"`, `channel_id`, `tenant_id`, `sub`, `exp`, `iat`;
    * `jti`: unique per token; `fam`: the family id, the `jti` of the token
      generated from the channel secret, inherited by every token derived or
      refreshed from it (`Converger.Auth.Revocations`);
    * `conversation_id` (optional): restricts the token to one conversation;
    * `user_id` (optional): the end user;
    * `scope: "channel"` (optional): follow every conversation of the
      channel (agent console);
    * `perms` (optional): what the token may do, a subset of `permissions/0`.
      Without the claim the token may do everything.

  Tokens are signed with the dedicated keys of `Converger.Auth.Signer`
  (`kid` header) and checked against the revocation cache on every
  verification.
  """

  use Joken.Config

  alias Converger.Auth.{Revocations, Signer}

  @default_expiry 1800
  @permissions ~w(read write typing)

  @impl true
  def token_config do
    default_claims(default_exp: @default_expiry)
    |> add_claim("type", fn -> "converger" end, &(&1 == "converger"))
    |> add_claim("channel_id", nil, &is_binary/1)
    |> add_claim("tenant_id", nil, &is_binary/1)
    |> add_claim("sub", nil, &is_binary/1)
  end

  @doc """
  Issues a token for `channel`.

  Options: `:conversation_id`, `:user_id`, `:scope` (`"channel"`),
  `:permissions` (a list, see `permissions/0`; nil for all), `:expires_in`
  (seconds), `:family` (the family id; a new family when nil) and
  `:not_after` (a unix time the token must not outlive: a token derived from
  another never expires after it).
  """
  def generate_token(channel, opts \\ []) do
    jti = Joken.generate_jti()

    claims =
      %{
        "type" => "converger",
        "channel_id" => channel.id,
        "tenant_id" => channel.tenant_id,
        "sub" => "converger_#{channel.id}",
        "exp" => expiry(opts),
        "jti" => jti,
        "fam" => Keyword.get(opts, :family) || jti
      }
      |> put_optional(opts)

    generate_and_sign(claims, Signer.converger_signer())
  end

  defp expiry(opts) do
    exp = Joken.current_time() + Keyword.get(opts, :expires_in, @default_expiry)

    case Keyword.get(opts, :not_after) do
      not_after when is_integer(not_after) -> min(exp, not_after)
      _ -> exp
    end
  end

  defp put_optional(claims, opts) do
    conversation_id = Keyword.get(opts, :conversation_id)

    claims
    |> put_if("conversation_id", conversation_id, &is_binary/1)
    # Optional end-user id (Direct Line style `user.id`), used for the
    # per-user socket id so one user can be disconnected individually.
    |> put_if("user_id", Keyword.get(opts, :user_id), &(is_binary(&1) and &1 != ""))
    # `scope: "channel"` lets the socket follow every conversation of the
    # channel (agent console, ConvergerWeb.ConvergerChannel). Never combined
    # with a conversation restriction.
    |> put_if("scope", Keyword.get(opts, :scope), &(&1 == "channel" and is_nil(conversation_id)))
    |> put_if("perms", Keyword.get(opts, :permissions), &is_list/1)
  end

  defp put_if(claims, key, value, keep?) do
    if keep?.(value), do: Map.put(claims, key, value), else: claims
  end

  @doc "Token scopes accepted by `generate_token/2` (`:scope` option)."
  def scopes, do: ["channel"]

  @doc "Permissions a token can be restricted to (`perms` claim)."
  def permissions, do: @permissions

  @doc """
  Validates a requested permission list: `{:ok, nil}` for none (all
  permissions), `{:ok, perms}` for a non-empty list of known permissions,
  `{:error, message}` otherwise.
  """
  def cast_permissions(nil), do: {:ok, nil}

  def cast_permissions([_ | _] = perms) do
    if Enum.all?(perms, &(&1 in @permissions)),
      do: {:ok, perms |> Enum.uniq() |> Enum.sort()},
      else: {:error, "permissions must be a list of: #{Enum.join(@permissions, ", ")}"}
  end

  def cast_permissions(_perms),
    do: {:error, "permissions must be a non-empty list of: #{Enum.join(@permissions, ", ")}"}

  @doc "Whether verified `claims` grant `permission` (no `perms` claim: all)."
  def permitted?(%{"perms" => perms}, permission) when is_list(perms),
    do: permission in perms

  def permitted?(_claims, _permission), do: true

  @doc """
  Options to issue a token derived from verified `claims` (a conversation
  token from a channel-level one): same end user, permissions and family, and
  never outliving `claims`.
  """
  def derived_opts(claims) do
    [
      user_id: claims["user_id"],
      permissions: claims["perms"],
      family: Revocations.family(claims),
      not_after: claims["exp"]
    ]
  end

  def generate_conversation_token(channel, conversation_id, opts \\ []) do
    generate_token(channel, Keyword.put(opts, :conversation_id, conversation_id))
  end

  @doc """
  Verifies a token: signature (by `kid`), claims, and revocation.

  Errors: Joken's, `{:error, :invalid_token_type}`, `{:error, :unknown_kid}`,
  `{:error, :token_revoked}` and `{:error, :token_rotated}` (refreshed longer
  ago than the grace period). With `allow_rotated: true` a rotated token
  verifies (the refresh endpoint, which then detects the reuse).
  """
  def verify_token(token, opts \\ []) do
    with {:ok, signer} <- Signer.converger_verifier(token),
         {:ok, %{"type" => "converger"} = claims} <- verify_and_validate(token, signer),
         :ok <- check_revocation(claims, opts) do
      {:ok, claims}
    else
      {:ok, _claims} -> {:error, :invalid_token_type}
      error -> error
    end
  end

  defp check_revocation(claims, opts) do
    case Revocations.check(claims) do
      {:error, :token_rotated} ->
        if Keyword.get(opts, :allow_rotated, false), do: :ok, else: {:error, :token_rotated}

      result ->
        result
    end
  end

  @doc """
  Refreshes `token` with rotation: a new token of the same family, claims and
  permissions with a new expiry, and the old one marked rotated
  (`Converger.Auth.Revocations.rotate/1`). Refreshing a token that was
  already rotated, after the grace period, revokes the family and returns
  `{:error, :token_reused}`.
  """
  def refresh_token(token) when is_binary(token) do
    with {:ok, claims} <- verify_token(token, allow_rotated: true) do
      refresh_claims(claims)
    end
  end

  @doc "`refresh_token/1` for already verified `claims`."
  def refresh_claims(claims) do
    with :ok <- Revocations.rotate(claims) do
      channel = Converger.Channels.get_channel!(claims["channel_id"])

      generate_token(channel,
        conversation_id: claims["conversation_id"],
        user_id: claims["user_id"],
        scope: claims["scope"],
        permissions: claims["perms"],
        family: Revocations.family(claims),
        expires_in: @default_expiry
      )
    end
  end

  def default_expiry, do: @default_expiry
end
