defmodule ConvergerWeb.Live.AuthHooks do
  @moduledoc """
  LiveView on_mount hooks for authentication.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  alias Converger.Accounts

  def on_mount(:ensure_admin_user, _params, session, socket) do
    case session["admin_user_id"] do
      nil ->
        {:halt, redirect(socket, to: "/admin/login")}

      admin_user_id ->
        try do
          user = Accounts.get_admin_user!(admin_user_id)

          if user.status == "active" do
            {:cont,
             socket
             |> assign(:current_admin_user, user)
             |> assign(:admin_role, user.role)}
          else
            {:halt, redirect(socket, to: "/admin/login")}
          end
        rescue
          Ecto.NoResultsError ->
            {:halt, redirect(socket, to: "/admin/login")}
        end
    end
  end

  def on_mount(:ensure_tenant_user, _params, session, socket) do
    case session["tenant_user_id"] do
      nil ->
        {:halt, redirect(socket, to: "/portal/login")}

      tenant_user_id ->
        try do
          user = Accounts.get_tenant_user!(tenant_user_id)

          if user.status == "active" do
            {:cont,
             socket
             |> assign(:current_tenant_user, user)
             |> assign(:current_tenant, user.tenant)
             |> assign(:tenant_role, user.role)}
          else
            {:halt, redirect(socket, to: "/portal/login")}
          end
        rescue
          Ecto.NoResultsError ->
            {:halt, redirect(socket, to: "/portal/login")}
        end
    end
  end
end
