defmodule Converger.Channels.Teams.Auth do
  @moduledoc """
  Bot Framework authentication for the `teams` adapter (ADR-0048).

  ## Inbound: Bot Connector JWTs

  The Bot Connector service sends every activity with
  `Authorization: Bearer <JWT>`. `verify_request/3` accepts it only when:

    * the token is RS256-signed by a key of the Bot Framework OpenID metadata
      (`openid_metadata_url`, its `jwks_uri`), and that key is endorsed for
      the activity's `channelId` (e.g. `msteams`) when it lists endorsements;
    * `iss` is an allowed issuer (`https://api.botframework.com`), `aud` is
      the bot's app id, and `nbf` / `exp` hold within a five-minute skew;
    * the `serviceurl` claim equals the activity's `serviceUrl`.

  The metadata and keys are cached for 24 hours in
  `Converger.Channels.TokenCache`; an unknown `kid` refetches them, at most
  once per `key_refresh_cooldown_ms` (5 minutes).

  ## Outbound: OAuth client credentials

  `access_token/1` gets a token for `https://api.botframework.com/.default`
  from `https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token`
  (`botframework.com` for multi-tenant bots, the bot's tenant for
  single-tenant ones), cached until five minutes before it expires.

  ## Service URLs

  Replies go to the activity's `serviceUrl`, which an attacker who could
  forge one would point at an internal host. `check_service_url/1` allows
  only `https` URLs on the Bot Framework hosts (`service_url_hosts`) that
  `Converger.Channels.UrlGuard` also accepts.

  ## Configuration

      config :converger, Converger.Channels.Adapters.Teams,
        openid_metadata_url: "https://login.botframework.com/v1/.well-known/openidconfiguration",
        issuers: ["https://api.botframework.com"],
        login_base_url: "https://login.microsoftonline.com",
        service_url_hosts: ["smba.trafficmanager.net", "*.botframework.com", ...]
  """

  alias Converger.Channels.{DeliveryError, InboundSignature, TokenCache, UrlGuard}

  @adapter Converger.Channels.Adapters.Teams

  @default_openid_metadata_url "https://login.botframework.com/v1/.well-known/openidconfiguration"
  @default_issuers ["https://api.botframework.com"]
  @default_login_base_url "https://login.microsoftonline.com"
  @scope "https://api.botframework.com/.default"

  # Public cloud, GCC (botframework.us) and the Teams regional service URLs
  # (https://smba.trafficmanager.net/<region>/).
  @default_service_url_hosts [
    "smba.trafficmanager.net",
    "*.trafficmanager.net",
    "*.botframework.com",
    "*.botframework.us",
    "*.botframework.azure.us",
    "*.teams.microsoft.com",
    "*.teams.microsoft.us"
  ]

  @clock_skew_seconds 300
  @keys_ttl_ms 24 * 60 * 60 * 1000
  @default_key_refresh_cooldown_ms 5 * 60 * 1000
  # Tokens are refreshed five minutes before they expire.
  @token_margin_seconds 300

  ## Inbound

  @doc """
  Verifies the `Authorization: Bearer <JWT>` of a Bot Connector request for
  the bot `app_id`. Returns `:ok` or `{:error, reason}`.
  """
  def verify_request(app_id, headers, raw_body) do
    with {:ok, token} <- bearer(headers),
         {:ok, activity} <- decode_activity(raw_body),
         {:ok, header} <- peek_header(token),
         {:ok, key} <- signing_key(header["kid"]),
         :ok <- check_endorsement(key, activity["channelId"]),
         {:ok, claims} <- verify_signature(token, key) do
      check_claims(claims, app_id, activity["serviceUrl"])
    end
  end

  defp bearer(headers) do
    case InboundSignature.get_header(headers, "authorization") do
      "Bearer " <> token when token != "" -> {:ok, String.trim(token)}
      nil -> {:error, :missing_token}
      _ -> {:error, :malformed_token}
    end
  end

  defp decode_activity(raw_body) do
    case Jason.decode(raw_body || "") do
      {:ok, %{} = activity} -> {:ok, activity}
      _ -> {:error, :invalid_body}
    end
  end

  defp peek_header(token) do
    case Joken.peek_header(token) do
      {:ok, %{"alg" => "RS256", "kid" => kid} = header} when is_binary(kid) -> {:ok, header}
      {:ok, _header} -> {:error, :unsupported_algorithm}
      _ -> {:error, :malformed_token}
    end
  rescue
    _ -> {:error, :malformed_token}
  end

  defp signing_key(kid) do
    with {:ok, keys} <- keys(false) do
      case find_key(keys, kid) do
        nil -> refresh_and_find(kid)
        key -> {:ok, key}
      end
    end
  end

  # An unknown kid may be a rotated key: refetch, but not more often than
  # the cooldown, so a flood of forged tokens cannot hammer the endpoint.
  defp refresh_and_find(kid) do
    case TokenCache.get({__MODULE__, :refreshed}) do
      {:ok, _} ->
        {:error, :unknown_key}

      :miss ->
        TokenCache.put({__MODULE__, :refreshed}, true, key_refresh_cooldown_ms())

        with {:ok, keys} <- keys(true) do
          case find_key(keys, kid) do
            nil -> {:error, :unknown_key}
            key -> {:ok, key}
          end
        end
    end
  end

  defp find_key(keys, kid), do: Enum.find(keys, &(is_map(&1) and &1["kid"] == kid))

  defp keys(refresh?) do
    cache_key = {__MODULE__, :keys, openid_metadata_url()}
    if refresh?, do: TokenCache.delete(cache_key)

    TokenCache.fetch(cache_key, fn ->
      with {:ok, %{"jwks_uri" => jwks_uri}} when is_binary(jwks_uri) <-
             get_json(openid_metadata_url()),
           {:ok, %{"keys" => keys}} when is_list(keys) <- get_json(jwks_uri) do
        {:ok, keys, @keys_ttl_ms}
      else
        {:ok, _} -> {:error, :invalid_openid_metadata}
        {:error, _} = error -> error
      end
    end)
  end

  defp get_json(url) do
    options =
      [receive_timeout: 5_000, retry: false]
      |> Keyword.merge(req_options())

    case Req.get(url, options) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:openid_metadata, status}}
      {:error, reason} -> {:error, {:openid_metadata, reason}}
    end
  end

  defp check_endorsement(%{"endorsements" => endorsements}, channel_id)
       when is_list(endorsements) do
    if is_binary(channel_id) and channel_id in endorsements,
      do: :ok,
      else: {:error, :key_not_endorsed}
  end

  defp check_endorsement(_key, _channel_id), do: :ok

  defp verify_signature(token, key) do
    signer = Joken.Signer.create("RS256", Map.take(key, ["kty", "n", "e"]))

    case Joken.verify(token, signer) do
      {:ok, claims} -> {:ok, claims}
      {:error, _} -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signing_key}
  end

  defp check_claims(claims, app_id, service_url) do
    now = System.system_time(:second)

    cond do
      claims["iss"] not in issuers() ->
        {:error, :invalid_issuer}

      not audience?(claims["aud"], app_id) ->
        {:error, :invalid_audience}

      not (is_integer(claims["exp"]) and claims["exp"] + @clock_skew_seconds > now) ->
        {:error, :token_expired}

      is_integer(claims["nbf"]) and claims["nbf"] - @clock_skew_seconds > now ->
        {:error, :token_not_yet_valid}

      not service_url_claim?(claims, service_url) ->
        {:error, :service_url_mismatch}

      true ->
        :ok
    end
  end

  defp audience?(aud, app_id) when is_binary(app_id) and app_id != "",
    do: aud == app_id or (is_list(aud) and app_id in aud)

  defp audience?(_aud, _app_id), do: false

  defp service_url_claim?(claims, service_url) do
    claim = claims["serviceurl"] || claims["serviceUrl"]

    is_binary(claim) and is_binary(service_url) and
      String.trim_trailing(claim, "/") == String.trim_trailing(service_url, "/")
  end

  ## Outbound

  @doc """
  A Bot Framework access token for the channel config (`app_id`,
  `app_password`, optional `app_tenant_id`), cached until shortly before it
  expires. `{:error, %DeliveryError{}}` when the token endpoint refuses the
  credentials (permanent) or fails (retryable).
  """
  def access_token(config) do
    TokenCache.fetch(token_cache_key(config), fn -> request_token(config) end)
  end

  @doc "Drops the cached access token of the config (e.g. after a 401)."
  def invalidate_token(config), do: TokenCache.delete(token_cache_key(config))

  # The password is part of the key, so a changed secret gets a new token.
  defp token_cache_key(config) do
    secret_hash = :crypto.hash(:sha256, to_string(config["app_password"]))
    {__MODULE__, :token, config["app_id"], tenant(config), secret_hash}
  end

  defp tenant(config) do
    case config["app_tenant_id"] do
      tenant when is_binary(tenant) and tenant != "" -> tenant
      _ -> "botframework.com"
    end
  end

  defp request_token(config) do
    url =
      "#{login_base_url()}/#{URI.encode(tenant(config), &URI.char_unreserved?/1)}/oauth2/v2.0/token"

    form = [
      grant_type: "client_credentials",
      client_id: config["app_id"],
      client_secret: config["app_password"],
      scope: @scope
    ]

    options = Keyword.merge([form: form, receive_timeout: 10_000, retry: false], req_options())

    case Req.post(url, options) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token} = body}} ->
        expires_in = if is_integer(body["expires_in"]), do: body["expires_in"], else: 3600
        {:ok, token, max(expires_in - @token_margin_seconds, 60) * 1000}

      # Wrong app id, secret or tenant: no retry fixes that.
      {:ok, %Req.Response{status: status, body: body}} when status in [400, 401, 403] ->
        {:error,
         DeliveryError.permanent(
           "Bot Framework token request returned #{status}: #{error_text(body)}"
         )}

      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:error,
         DeliveryError.from_http(status, headers, error_text(body), "Bot Framework token")}

      {:error, reason} ->
        {:error, DeliveryError.from_transport(reason, "Bot Framework token")}
    end
  end

  # The token endpoint's error, without echoing anything else of the body.
  defp error_text(%{"error" => error} = body),
    do: "#{error}#{if body["error_codes"], do: " #{inspect(body["error_codes"])}"}"

  defp error_text(_body), do: "unexpected response"

  ## Service URLs

  @doc """
  `:ok` when `url` is an `https` URL on an allowed Bot Framework host
  (`service_url_hosts`) that `Converger.Channels.UrlGuard` accepts, else
  `{:error, message}`.
  """
  def check_service_url(url) when is_binary(url) do
    uri = URI.parse(url)
    host = uri.host && String.downcase(uri.host)

    cond do
      uri.scheme != "https" or is_nil(host) ->
        {:error, "service URL #{inspect(url)} must be an https URL"}

      not host_allowed?(host) ->
        {:error, "service URL host #{host} is not an allowed Bot Framework host"}

      true ->
        case UrlGuard.resolve(url) do
          {:ok, _target} -> :ok
          {:error, reason} -> {:error, "service URL #{UrlGuard.format_error(reason)}"}
        end
    end
  end

  def check_service_url(_url), do: {:error, "no Bot Framework service URL"}

  defp host_allowed?(host) do
    Enum.any?(service_url_hosts(), fn
      "*." <> suffix -> String.ends_with?(host, "." <> suffix)
      allowed -> host == allowed
    end)
  end

  ## Settings

  @doc false
  def req_options, do: Application.get_env(:converger, :teams_req_options, [])

  defp setting(key, default) do
    :converger |> Application.get_env(@adapter, []) |> Keyword.get(key, default)
  end

  defp openid_metadata_url, do: setting(:openid_metadata_url, @default_openid_metadata_url)
  defp issuers, do: setting(:issuers, @default_issuers)
  defp login_base_url, do: setting(:login_base_url, @default_login_base_url)

  defp key_refresh_cooldown_ms,
    do: setting(:key_refresh_cooldown_ms, @default_key_refresh_cooldown_ms)

  @doc "The allowed service URL host patterns (`*.` matches any subdomain)."
  def service_url_hosts,
    do: setting(:service_url_hosts, @default_service_url_hosts) |> Enum.map(&String.downcase/1)

  @doc false
  # Tests: forget the cached OpenID keys and the refresh cooldown.
  def clear_key_cache do
    TokenCache.delete({__MODULE__, :keys, openid_metadata_url()})
    TokenCache.delete({__MODULE__, :refreshed})
  end
end
