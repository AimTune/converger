defmodule ConvergerWeb.Plugs.Auth do
  @moduledoc """
  Authentication plugs for admin and tenant user sessions.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Converger.Accounts

  def fetch_admin_user(conn, _opts) do
    admin_user_id = get_session(conn, :admin_user_id)

    if admin_user_id do
      try do
        user = Accounts.get_admin_user!(admin_user_id)

        if user.status == "active" do
          assign(conn, :current_admin_user, user)
        else
          conn
          |> delete_session(:admin_user_id)
          |> assign(:current_admin_user, nil)
        end
      rescue
        Ecto.NoResultsError ->
          conn
          |> delete_session(:admin_user_id)
          |> assign(:current_admin_user, nil)
      end
    else
      assign(conn, :current_admin_user, nil)
    end
  end

  def require_admin_user(conn, _opts) do
    if conn.assigns[:current_admin_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> redirect(to: "/admin/login")
      |> halt()
    end
  end

  def fetch_tenant_user(conn, _opts) do
    tenant_user_id = get_session(conn, :tenant_user_id)

    if tenant_user_id do
      try do
        user = Accounts.get_tenant_user!(tenant_user_id)

        if user.status == "active" do
          conn
          |> assign(:current_tenant_user, user)
          |> assign(:current_tenant, user.tenant)
        else
          conn
          |> delete_session(:tenant_user_id)
          |> assign(:current_tenant_user, nil)
          |> assign(:current_tenant, nil)
        end
      rescue
        Ecto.NoResultsError ->
          conn
          |> delete_session(:tenant_user_id)
          |> assign(:current_tenant_user, nil)
          |> assign(:current_tenant, nil)
      end
    else
      conn
      |> assign(:current_tenant_user, nil)
      |> assign(:current_tenant, nil)
    end
  end

  def require_tenant_user(conn, _opts) do
    if conn.assigns[:current_tenant_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> redirect(to: "/portal/login")
      |> halt()
    end
  end

  def redirect_if_admin_authenticated(conn, _opts) do
    if conn.assigns[:current_admin_user] do
      conn
      |> redirect(to: "/admin")
      |> halt()
    else
      conn
    end
  end

  def redirect_if_tenant_authenticated(conn, _opts) do
    if conn.assigns[:current_tenant_user] do
      conn
      |> redirect(to: "/portal")
      |> halt()
    else
      conn
    end
  end
end
