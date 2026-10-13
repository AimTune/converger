defmodule ConvergerWeb.Manage.TenantUserController do
  @moduledoc """
  Tenant portal users (ADR-0061): `/api/v1/manage/users`.

  Requires an API key with the `manage` scope. Any role can be given,
  `owner` included. Passwords are set on create only; afterwards users
  change theirs in the portal or by password reset. Deactivating or
  deleting a user ends their portal sessions.
  """
  use ConvergerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import ConvergerWeb.ApiSchemas

  alias Converger.Accounts
  alias Converger.Accounts.TenantUser
  alias ConvergerWeb.{ETag, Plugs.TenantAuth}

  plug TenantAuth, scope: "manage", api_key_only: true

  action_fallback ConvergerWeb.FallbackController

  tags(["Management"])
  security([%{"apiKey" => []}])

  operation(:index,
    summary: "List portal users",
    description: "Not paginated: the tenant's users, newest first, capped at `lookup_limit`.",
    operation_id: "manageListUsers",
    responses: with_errors(%{200 => json_schema("Users", ref("TenantUserList"))}, [401, 403])
  )

  def index(conn, _params) do
    render(conn, :index, users: Accounts.list_tenant_users(conn.assigns.tenant.id))
  end

  operation(:show,
    summary: "Get a portal user",
    operation_id: "manageGetUser",
    parameters: [id: path_id("User id")],
    responses:
      with_errors(%{200 => json_schema("The user", ref("TenantUserResponse"))}, [401, 403, 404])
  )

  def show(conn, %{"id" => id}) do
    with {:ok, user} <- fetch(conn, id) do
      conn |> ETag.put_etag(user) |> render(:show, user: user)
    end
  end

  operation(:create,
    summary: "Create a portal user",
    operation_id: "manageCreateUser",
    request_body: json_schema("The user", ref("TenantUserRequest")),
    responses:
      with_errors(
        %{201 => json_schema("Created", ref("TenantUserResponse"))},
        [400, 401, 403, 422]
      )
  )

  def create(conn, %{"user" => params}) when is_map(params) do
    attrs =
      params
      |> Map.take(~w(email name password role status))
      |> Map.put("tenant_id", conn.assigns.tenant.id)

    with {:ok, user} <- Accounts.create_tenant_user(attrs, TenantAuth.actor(conn)) do
      conn
      |> put_status(:created)
      |> ETag.put_etag(user)
      |> render(:show, user: user)
    end
  end

  def create(_conn, _params), do: {:error, "user object is required"}

  operation(:update,
    summary: "Update a portal user",
    description:
      "`password` is ignored. Deactivating a user ends their sessions. Honours `If-Match`.",
    operation_id: "manageUpdateUser",
    parameters: [id: path_id("User id")],
    request_body: json_schema("Fields to change", ref("TenantUserRequest")),
    responses:
      with_errors(
        %{200 => json_schema("Updated", ref("TenantUserResponse"))},
        [400, 401, 403, 404, 412, 422]
      )
  )

  def update(conn, %{"id" => id, "user" => params}) when is_map(params) do
    attrs = Map.take(params, ~w(email name role status))

    with {:ok, user} <- fetch(conn, id),
         :ok <- ETag.check_if_match(conn, user),
         {:ok, user} <- Accounts.update_tenant_user(user, attrs, TenantAuth.actor(conn)) do
      conn |> ETag.put_etag(user) |> render(:show, user: user)
    end
  end

  def update(_conn, _params), do: {:error, "user object is required"}

  operation(:delete,
    summary: "Delete a portal user",
    description: "Ends the user's sessions. Honours `If-Match`.",
    operation_id: "manageDeleteUser",
    parameters: [id: path_id("User id")],
    responses: with_errors(%{204 => "Deleted"}, [401, 403, 404, 412])
  )

  def delete(conn, %{"id" => id}) do
    with {:ok, user} <- fetch(conn, id),
         :ok <- ETag.check_if_match(conn, user),
         {:ok, _} <- Accounts.delete_tenant_user(user, TenantAuth.actor(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch(conn, id) do
    case Accounts.get_tenant_user(conn.assigns.tenant.id, id) do
      %TenantUser{} = user -> {:ok, user}
      nil -> {:error, :not_found}
    end
  end
end
