defmodule ConvergerWeb.Plugs.TenantAuth do
  @moduledoc """
  Authenticates tenant API requests and enforces API key scopes (ADR-0061).

  Credentials, in `x-api-key`: the tenant's primary key (every scope) or a
  scoped key (`Converger.ApiKeys`); or a channel token in `x-channel-token`.
  Only channel tokens are accepted there (end-user tokens share the signer);
  channel tokens are deprecated (#23), have every scope for compatibility,
  and each use is logged by `ConvergerWeb.Deprecation`.

  Assigns `:tenant` and `:api_credential` (`Converger.ApiKeys.Credential`).

  Every action needs one scope: `read` for `GET`/`HEAD`, `write` otherwise,
  unless overridden per action. A credential without it gets `403
  insufficient_scope`.

      plug ConvergerWeb.Plugs.TenantAuth,
        scopes: [create: "manage", update: "manage", dry_run: "read"]

  Options:

    * `:scope` - the scope of every action (no method default);
    * `:scopes` - `[action: scope]` overrides of the method default;
    * `:api_key_only` - reject channel tokens (`403 forbidden`).
  """

  import Plug.Conn

  alias Converger.ApiKeys
  alias Converger.ApiKeys.Credential
  alias Converger.Auth.Token
  alias Converger.{Channels, Tenants}
  alias ConvergerWeb.APIError

  require Logger

  def init(opts) do
    scopes = Keyword.get(opts, :scopes, [])
    scope = Keyword.get(opts, :scope)

    for {action, s} <- [{:all, scope} | scopes], s, s not in ApiKeys.scopes() do
      raise ArgumentError, "unknown scope #{inspect(s)} for #{inspect(action)}"
    end

    %{
      scope: scope,
      scopes: Map.new(scopes),
      api_key_only: Keyword.get(opts, :api_key_only, false)
    }
  end

  def call(conn, opts) when is_list(opts), do: call(conn, init(opts))

  def call(conn, opts) do
    conn
    |> authenticate(opts)
    |> require_scope(opts)
  end

  @doc """
  The audit actor of the request: `%{type: "tenant_api", id: credential id}`
  (the scoped key's id, the tenant id for the primary key, the channel id
  for a channel token).
  """
  def actor(%Plug.Conn{assigns: %{api_credential: %Credential{id: id}}}),
    do: %{type: "tenant_api", id: id}

  @doc "The scope `action` requires for `method`, see the moduledoc."
  def required_scope(%{scope: scope, scopes: scopes}, action, method) do
    cond do
      Map.has_key?(scopes, action) -> Map.fetch!(scopes, action)
      scope -> scope
      method in ["GET", "HEAD"] -> "read"
      true -> "write"
    end
  end

  defp authenticate(conn, opts) do
    cond do
      api_key = List.first(get_req_header(conn, "x-api-key")) ->
        authenticate_api_key(conn, api_key)

      token = List.first(get_req_header(conn, "x-channel-token")) ->
        if opts.api_key_only,
          do:
            APIError.send_error(
              conn,
              :forbidden,
              "This endpoint requires a tenant API key (x-api-key)"
            ),
          else: authenticate_token(conn, token)

      true ->
        unauthorized(conn, "Missing authentication headers")
    end
  end

  defp authenticate_api_key(conn, api_key) do
    case ApiKeys.authenticate(api_key) do
      {:ok, tenant, credential} ->
        conn
        |> assign(:tenant, tenant)
        |> assign(:api_credential, credential)

      {:error, _} ->
        unauthorized(conn, "Invalid or inactive API Key")
    end
  end

  # Only channel tokens (Converger.Auth.Token.generate_channel_token/1) are
  # tenant credentials. Every token type shares one signer, so the claims
  # must be checked: conversation tokens and Converger client tokens (held by
  # end-user browsers) also carry a `tenant_id` and must never unlock the
  # tenant API.
  defp authenticate_token(conn, token) do
    with {:ok, claims} <- Token.verify_token(token),
         {:ok, channel_id, tenant_id} <- Token.channel_token_claims(claims),
         {:ok, _channel} <- Channels.get_active_channel(channel_id, tenant_id),
         %Tenants.Tenant{status: "active"} = tenant <- Tenants.get_tenant(tenant_id) do
      conn
      |> assign(:tenant, tenant)
      |> assign(:api_credential, %Credential{
        kind: :channel_token,
        id: channel_id,
        scopes: ApiKeys.scopes()
      })
      |> ConvergerWeb.Deprecation.mark(:channel_token, tenant_id: tenant.id)
    else
      %Tenants.Tenant{} -> unauthorized(conn, "Tenant is not active")
      {:error, :channel_inactive} -> unauthorized(conn, "Channel is not active")
      _ -> unauthorized(conn, "Invalid token")
    end
  end

  defp require_scope(%Plug.Conn{halted: true} = conn, _opts), do: conn

  defp require_scope(conn, opts) do
    # Outside a controller (no action) the method default applies.
    scope = required_scope(opts, conn.private[:phoenix_action], conn.method)

    if scope in conn.assigns.api_credential.scopes do
      conn
    else
      APIError.send_error(
        conn,
        APIError.new(
          :insufficient_scope,
          "The API key lacks the #{scope} scope",
          %{"required" => scope}
        )
      )
    end
  end

  defp unauthorized(conn, message) do
    Logger.warning("Authentication failure: #{message}")
    APIError.send_error(conn, "unauthorized", message)
  end
end
