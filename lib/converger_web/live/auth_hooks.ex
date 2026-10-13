defmodule ConvergerWeb.Live.AuthHooks do
  @moduledoc """
  LiveView on_mount hooks for authentication.

  Like `ConvergerWeb.Plugs.Auth`, they validate the server-side session
  (`Converger.Accounts.Sessions`) on every mount. A LiveView connects with
  the session's `live_socket_id`, so revoking the session disconnects it.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  alias Converger.Accounts.{Sessions, TOTP}

  # `nav` feeds the page frame (ConvergerWeb.Layouts.app/1); `path` follows live
  # navigation so the sidebar can highlight the current page.
  defp assign_nav(socket, section, user, tenant) do
    socket
    |> assign(:nav, %{section: section, user: user, tenant: tenant, path: nil})
    |> attach_hook(:nav_path, :handle_params, fn _params, url, socket ->
      {:cont, update(socket, :nav, &%{&1 | path: URI.parse(url).path})}
    end)
  end

  def on_mount(:ensure_admin_user, _params, session, socket) do
    case Sessions.validate("admin", session["admin_session_token"]) do
      {:ok, user_session, user} ->
        cond do
          user.must_change_password ->
            {:halt, redirect(socket, to: "/admin/password")}

          TOTP.enrollment_required?(user) ->
            {:halt, redirect(socket, to: "/admin/security")}

          true ->
            {:cont,
             socket
             |> assign(:current_admin_user, user)
             |> assign(:current_user_session, user_session)
             |> assign(:admin_role, user.role)
             |> assign_nav(:admin, user, nil)}
        end

      {:error, _} ->
        {:halt, redirect(socket, to: "/admin/login")}
    end
  end

  def on_mount(:ensure_tenant_user, _params, session, socket) do
    case Sessions.validate("tenant", session["tenant_session_token"]) do
      {:ok, user_session, user} ->
        {:cont,
         socket
         |> assign(:current_tenant_user, user)
         |> assign(:current_tenant, user.tenant)
         |> assign(:current_user_session, user_session)
         |> assign(:tenant_role, user.role)
         |> assign_nav(:portal, user, user.tenant)}

      {:error, _} ->
        {:halt, redirect(socket, to: "/portal/login")}
    end
  end
end
