defmodule ConvergerWeb.Manage.ApiKeyController do
  @moduledoc """
  The tenant's scoped API keys (ADR-0061): `/api/v1/manage/api_keys`.

  Requires an API key with the `manage` scope. A key can only issue keys
  with scopes it has itself, so a scoped key never mints a broader one.
  `DELETE` revokes: the key stops working at once and stays listed.
  """
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.ApiKeys
  alias Converger.ApiKeys.ApiKey
  alias ConvergerWeb.{APIError, Plugs.TenantAuth}

  plug TenantAuth, scope: "manage", api_key_only: true

  plug :put_view, json: ConvergerWeb.ApiKeyJSON

  action_fallback ConvergerWeb.FallbackController

  tags(["Management"])
  security([%{"apiKey" => []}])

  operation(:index,
    summary: "List API keys",
    description: "The tenant's scoped keys, revoked ones included, newest first. Not paginated.",
    operation_id: "manageListApiKeys",
    responses: with_errors(%{200 => json_schema("API keys", ref("ApiKeyList"))}, [401, 403])
  )

  def index(conn, _params) do
    render(conn, :index, api_keys: ApiKeys.list_api_keys(conn.assigns.tenant.id))
  end

  operation(:show,
    summary: "Get an API key",
    operation_id: "manageGetApiKey",
    parameters: [id: path_id("API key id")],
    responses:
      with_errors(%{200 => json_schema("The key", ref("ApiKeyResponse"))}, [401, 403, 404])
  )

  def show(conn, %{"id" => id}) do
    with {:ok, api_key} <- fetch(conn, id) do
      render(conn, :show, api_key: api_key)
    end
  end

  operation(:create,
    summary: "Issue an API key",
    description:
      "The response is the only one with the `key`. The scopes must be a subset of the calling key's scopes.",
    operation_id: "manageCreateApiKey",
    request_body: json_schema("The key", ref("CreateApiKeyRequest")),
    responses:
      with_errors(
        %{201 => json_schema("Created", ref("ApiKeyWithKeyResponse"))},
        [400, 401, 403, 422]
      )
  )

  def create(conn, %{"api_key" => params}) when is_map(params) do
    with :ok <- check_no_escalation(conn, params["scopes"]),
         {:ok, api_key} <-
           ApiKeys.create_api_key(conn.assigns.tenant.id, params, TenantAuth.actor(conn)) do
      conn
      |> put_status(:created)
      |> render(:show, api_key: api_key, include_key: true)
    end
  end

  def create(_conn, _params), do: {:error, "api_key object is required"}

  operation(:delete,
    summary: "Revoke an API key",
    description: "The key stops working at once; it stays listed with `revoked_at`.",
    operation_id: "manageRevokeApiKey",
    parameters: [id: path_id("API key id")],
    responses: with_errors(%{204 => "Revoked"}, [401, 403, 404])
  )

  def delete(conn, %{"id" => id}) do
    with {:ok, api_key} <- fetch(conn, id),
         {:ok, _} <- ApiKeys.revoke_api_key(api_key, TenantAuth.actor(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

  defp check_no_escalation(conn, scopes) when is_list(scopes) do
    # Unknown scopes are left to the changeset (422).
    case Enum.filter(scopes, &(&1 in ApiKeys.scopes())) -- conn.assigns.api_credential.scopes do
      [] ->
        :ok

      extra ->
        {:error,
         APIError.new(
           :insufficient_scope,
           "A key can only issue keys with scopes it has",
           %{"required" => Enum.join(extra, ",")}
         )}
    end
  end

  # Not a list: left to the changeset (422).
  defp check_no_escalation(_conn, _scopes), do: :ok

  defp fetch(conn, id) do
    case ApiKeys.get_api_key(conn.assigns.tenant.id, id) do
      %ApiKey{} = api_key -> {:ok, api_key}
      nil -> {:error, :not_found}
    end
  end
end
