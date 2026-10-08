defmodule ConvergerWeb.ObanResolver do
  @moduledoc """
  Access control for the Oban Web dashboard mounted at `/admin/oban`.

  The route already sits behind the admin IP whitelist and admin session
  pipelines; this resolver additionally maps admin roles to dashboard access:
  `super_admin` and `admin` can act on jobs and queues, `viewer` is read-only,
  anyone else is sent to the admin login.
  """

  @behaviour Oban.Web.Resolver

  alias Converger.Accounts.AdminUser

  @impl true
  def resolve_user(conn), do: conn.assigns[:current_admin_user]

  @impl true
  def resolve_access(%AdminUser{status: "active", role: role}) when role in ~w(super_admin admin),
    do: :all

  def resolve_access(%AdminUser{status: "active", role: "viewer"}), do: :read_only
  def resolve_access(_user), do: {:forbidden, "/admin/login"}
end
