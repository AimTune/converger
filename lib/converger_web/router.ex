defmodule ConvergerWeb.Router do
  use ConvergerWeb, :router

  import ConvergerWeb.Plugs.Auth
  import Oban.Web.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ConvergerWeb.Layouts, :root}
    plug :protect_from_forgery

    # The admin/portal layouts load phoenix + LiveView from jsDelivr and use an
    # inline bootstrap <script> and <style> (there is no asset pipeline), hence
    # the CDN origin and 'unsafe-inline'. Everything else is locked to 'self'.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
    }
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

  pipeline :require_admin_login do
    plug :require_admin_session
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

    resources "/conversations", ConversationController, only: [:index, :create, :show] do
      resources "/activities", ActivityController, only: [:create, :index]
      post "/close", ConversationController, :close
      post "/reopen", ConversationController, :reopen
    end

    resources "/routing_rules", RoutingRuleController,
      only: [:index, :show, :create, :update, :delete]

    # Inbound webhook endpoints for external channel integrations
    get "/channels/:channel_id/inbound", InboundController, :verify
    post "/channels/:channel_id/inbound", InboundController, :create

    # Delivery status webhook endpoint (receipts / read receipts)
    post "/channels/:channel_id/status", InboundController, :status
  end

  # Converger client API (Direct Line-inspired)
  pipeline :converger_secret_auth do
    plug ConvergerWeb.Plugs.ConvergerAuth, mode: :secret
  end

  pipeline :converger_token_auth do
    plug ConvergerWeb.Plugs.ConvergerAuth, mode: :token
  end

  scope "/api/v1/converger", ConvergerWeb.ConvergerAPI do
    pipe_through [:api, :converger_secret_auth]

    post "/tokens/generate", TokenController, :generate
  end

  scope "/api/v1/converger", ConvergerWeb.ConvergerAPI do
    pipe_through [:api, :converger_token_auth]

    post "/tokens/refresh", TokenController, :refresh
    post "/conversations", ConversationController, :create
    get "/conversations/:id", ConversationController, :show
    post "/conversations/:id/close", ConversationController, :close
    post "/conversations/:id/reopen", ConversationController, :reopen
    post "/conversations/:conversation_id/activities", ActivityController, :create
    get "/conversations/:conversation_id/activities", ActivityController, :index
    post "/conversations/:conversation_id/upload", UploadController, :create
  end

  # Attachment downloads: no `accepts ["json"]`, clients ask for image/*, etc.
  scope "/api/v1/converger", ConvergerWeb.ConvergerAPI do
    pipe_through [:converger_token_auth]

    get "/attachments/:id", AttachmentController, :show
  end

  # Server-Sent Events fallback (Protocol v1 frames). EventSource cannot set
  # headers, so the token may also come from `?token=`; no `accepts ["json"]`
  # because EventSource asks for text/event-stream.
  pipeline :converger_stream_auth do
    plug ConvergerWeb.Plugs.ConvergerAuth, mode: :token, query_token: true
  end

  scope "/api/v1/converger", ConvergerWeb.ConvergerAPI do
    pipe_through [:converger_stream_auth]

    get "/conversations/:conversation_id/events", EventStreamController, :stream
  end

  # Native Converger Protocol v1 WebSocket (raw frames, no Phoenix framing).
  # The Phoenix sockets at /socket/converger/{websocket,longpoll} are
  # dispatched by the endpoint before the router.
  scope "/socket/converger", ConvergerWeb do
    get "/v1", ProtocolSocketController, :upgrade
  end

  # Admin login (IP whitelist protected)
  scope "/admin", ConvergerWeb do
    pipe_through [:browser, :admin_auth, :admin_session]

    get "/login", AdminSessionController, :new
    post "/login", AdminSessionController, :create
    delete "/logout", AdminSessionController, :delete
  end

  # Own password change (also the forced change for `must_change_password`)
  scope "/admin", ConvergerWeb do
    pipe_through [:browser, :admin_auth, :admin_session, :require_admin_login]

    get "/password", AdminPasswordController, :edit
    put "/password", AdminPasswordController, :update
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

  # Oban Web dashboard (IP whitelist + admin session; role checks in
  # ConvergerWeb.ObanResolver). Kept outside the aliased admin scope because
  # oban_dashboard mounts Oban.Web modules.
  scope "/admin" do
    pipe_through [:browser, :admin_auth, :admin_session, :require_admin]

    oban_dashboard("/oban",
      resolver: ConvergerWeb.ObanResolver,
      on_mount: [{ConvergerWeb.Live.AuthHooks, :ensure_admin_user}]
    )
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
