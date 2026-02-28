defmodule ConvergerWeb.Router do
  use ConvergerWeb, :router

  import ConvergerWeb.Plugs.Auth

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ConvergerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :admin_auth do
    plug ConvergerWeb.Plugs.AdminAuth
  end

  pipeline :admin_session do
    plug :fetch_admin_user
  end

  pipeline :require_admin do
    plug :require_admin_user
  end

  pipeline :tenant_session do
    plug :fetch_tenant_user
  end

  pipeline :require_tenant do
    plug :require_tenant_user
  end

  scope "/api/v1", ConvergerWeb do
    pipe_through :api

    post "/tokens", TokenController, :create

    resources "/conversations", ConversationController, only: [:create, :show] do
      resources "/activities", ActivityController, only: [:create, :index]
    end

    resources "/routing_rules", RoutingRuleController,
      only: [:index, :show, :create, :update, :delete]

    # Inbound webhook endpoints for external channel integrations
    get "/channels/:channel_id/inbound", InboundController, :verify
    post "/channels/:channel_id/inbound", InboundController, :create

    # Delivery status webhook endpoint (receipts / read receipts)
    post "/channels/:channel_id/status", InboundController, :status
  end

  # Admin login (IP whitelist protected)
  scope "/admin", ConvergerWeb do
    pipe_through [:browser, :admin_auth, :admin_session]

    get "/login", AdminSessionController, :new
    post "/login", AdminSessionController, :create
    delete "/logout", AdminSessionController, :delete
  end

  # Admin panel (IP whitelist + session auth)
  scope "/admin", ConvergerWeb.Admin do
    pipe_through [:browser, :admin_auth, :admin_session, :require_admin]

    live_session :admin,
      on_mount: [{ConvergerWeb.Live.AuthHooks, :ensure_admin_user}],
      root_layout: {ConvergerWeb.Layouts, :admin_root} do
      live "/", DashboardLive
      live "/tenants", TenantLive
      live "/channels", ChannelLive
      live "/conversations", ConversationLive, :index
      live "/conversations/:id", ConversationLive, :show
      live "/routing_rules", RoutingRuleLive
      live "/audit_logs", AuditLogLive
      live "/users", AdminUserLive
      live "/tenant_users", TenantUserLive
    end
  end

  # Tenant portal login (no IP whitelist)
  scope "/portal", ConvergerWeb do
    pipe_through [:browser, :tenant_session]

    get "/login", TenantSessionController, :new
    post "/login", TenantSessionController, :create
    delete "/logout", TenantSessionController, :delete
  end

  # Tenant portal (session auth)
  scope "/portal", ConvergerWeb.Portal do
    pipe_through [:browser, :tenant_session, :require_tenant]

    live_session :portal,
      on_mount: [{ConvergerWeb.Live.AuthHooks, :ensure_tenant_user}],
      root_layout: {ConvergerWeb.Layouts, :portal_root} do
      live "/", DashboardLive
      live "/channels", ChannelLive
      live "/conversations", ConversationLive, :index
      live "/conversations/:id", ConversationLive, :show
      live "/routing_rules", RoutingRuleLive
      live "/users", UserLive
    end
  end

  # Enable Swoosh mailbox preview in development
  if Application.compile_env(:converger, :dev_routes) do
    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
