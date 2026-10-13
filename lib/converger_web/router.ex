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

  # API documentation (ADR-0050): Swagger UI and the OpenAPI 3.1 document.
  # On in dev/test, off in prod unless API_DOCS_ENABLED=true (404 otherwise).
  pipeline :api_docs do
    plug ConvergerWeb.Plugs.ApiDocs
  end

  scope "/api" do
    pipe_through :api_docs

    get "/docs", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/openapi.json",
      title: "Converger API",
      persist_authorization: true,
      display_operation_id: true,
      csp_nonce_assign_key: %{script: :csp_nonce}

    get "/openapi.json", ConvergerWeb.ApiDocsController, :spec
  end

  scope "/api/v1", ConvergerWeb do
    pipe_through :api

    # Deprecated (#23), like every `x-channel-token` use: legacy conversation
    # tokens. Converger tokens come from /api/v1/converger/tokens/generate.
    post "/tokens", TokenController, :create

    resources "/conversations", ConversationController, only: [:index, :create, :show] do
      resources "/activities", ActivityController, only: [:create, :index]
      post "/close", ConversationController, :close
      post "/reopen", ConversationController, :reopen
    end

    post "/routing_rules/dry_run", RoutingRuleController, :dry_run

    resources "/routing_rules", RoutingRuleController,
      only: [:index, :show, :create, :update, :delete]

    # Channel delivery state: circuit breaker, manual pause/resume
    get "/channels/:channel_id/delivery", ChannelDeliveryController, :show
    post "/channels/:channel_id/pause", ChannelDeliveryController, :pause
    post "/channels/:channel_id/resume", ChannelDeliveryController, :resume

    # Provider message templates (WhatsApp HSM), cached
    get "/channels/:channel_id/templates", ChannelTemplateController, :index

    # Outbox of http_pull channels: poll with a watermark, acknowledge
    get "/channels/:channel_id/outbox", ChannelOutboxController, :index
    post "/channels/:channel_id/outbox/ack", ChannelOutboxController, :ack

    # Dead-letter inspection and replay
    get "/deliveries", DeliveryController, :index
    post "/deliveries/:id/retry", DeliveryController, :retry
    post "/channels/:channel_id/deliveries/retry", DeliveryController, :bulk_retry

    # Platform event webhooks (ADR-0053): subscriptions, event log, redelivery
    get "/webhook_event_types", WebhookSubscriptionController, :event_types

    resources "/webhook_subscriptions", WebhookSubscriptionController,
      only: [:index, :show, :create, :update, :delete] do
      post "/rotate_secret", WebhookSubscriptionController, :rotate_secret
    end

    resources "/webhook_events", WebhookEventController, only: [:index, :show] do
      post "/redeliver", WebhookEventController, :redeliver
    end

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

    # Second login step for admins with 2FA, and password reset by email
    # (ADR-0058). Still behind the IP whitelist.
    get "/login/totp", TwoFactorLoginController, :new, assigns: %{user_type: "admin"}
    post "/login/totp", TwoFactorLoginController, :create, assigns: %{user_type: "admin"}
    get "/password/reset", PasswordResetController, :new, assigns: %{user_type: "admin"}
    post "/password/reset", PasswordResetController, :create, assigns: %{user_type: "admin"}
    get "/password/reset/:token", PasswordResetController, :edit, assigns: %{user_type: "admin"}
    put "/password/reset/:token", PasswordResetController, :update, assigns: %{user_type: "admin"}
  end

  # Own password change (also the forced change for `must_change_password`)
  scope "/admin", ConvergerWeb do
    pipe_through [:browser, :admin_auth, :admin_session, :require_admin_login]

    get "/password", AdminPasswordController, :edit
    put "/password", AdminPasswordController, :update

    # Security settings (2FA, sessions). Reachable before required 2FA is
    # set up: admins whose role requires it are sent here.
    get "/security", SecurityController, :show, assigns: %{user_type: "admin"}
    post "/security/totp/setup", SecurityController, :setup_totp, assigns: %{user_type: "admin"}
    post "/security/totp", SecurityController, :confirm_totp, assigns: %{user_type: "admin"}
    delete "/security/totp", SecurityController, :disable_totp, assigns: %{user_type: "admin"}

    delete "/security/sessions", SecurityController, :log_out_everywhere,
      assigns: %{user_type: "admin"}

    delete "/security/sessions/:id", SecurityController, :delete_session,
      assigns: %{user_type: "admin"}
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
      live "/routing_rules/dry_run", RoutingRuleDryRunLive
      live "/deliveries", DeliveryLive
      live "/webhooks", WebhookLive
      live "/audit_logs", AuditLogLive
      live "/users", AdminUserLive
      live "/tenant_users", TenantUserLive
    end
  end

  # Admin CSV export of deliveries (IP whitelist + session auth)
  scope "/admin", ConvergerWeb do
    pipe_through [:browser, :admin_auth, :admin_session, :require_admin]

    get "/deliveries/export", DeliveryExportController, :admin
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

    # Second login step for users with 2FA, and password reset by email
    # (ADR-0058).
    get "/login/totp", TwoFactorLoginController, :new, assigns: %{user_type: "tenant"}
    post "/login/totp", TwoFactorLoginController, :create, assigns: %{user_type: "tenant"}
    get "/password/reset", PasswordResetController, :new, assigns: %{user_type: "tenant"}
    post "/password/reset", PasswordResetController, :create, assigns: %{user_type: "tenant"}
    get "/password/reset/:token", PasswordResetController, :edit, assigns: %{user_type: "tenant"}

    put "/password/reset/:token", PasswordResetController, :update,
      assigns: %{user_type: "tenant"}
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
      live "/deliveries", DeliveryLive
      live "/routing_rules", RoutingRuleLive
      live "/webhooks", WebhookLive
      live "/users", UserLive
    end
  end

  # Tenant portal CSV export of deliveries (session auth)
  scope "/portal", ConvergerWeb do
    pipe_through [:browser, :tenant_session, :require_tenant]

    get "/deliveries/export", DeliveryExportController, :portal

    # Security settings: 2FA, sessions, own password (ADR-0058)
    get "/security", SecurityController, :show, assigns: %{user_type: "tenant"}
    post "/security/totp/setup", SecurityController, :setup_totp, assigns: %{user_type: "tenant"}
    post "/security/totp", SecurityController, :confirm_totp, assigns: %{user_type: "tenant"}
    delete "/security/totp", SecurityController, :disable_totp, assigns: %{user_type: "tenant"}

    put "/security/password", SecurityController, :update_password,
      assigns: %{user_type: "tenant"}

    delete "/security/sessions", SecurityController, :log_out_everywhere,
      assigns: %{user_type: "tenant"}

    delete "/security/sessions/:id", SecurityController, :delete_session,
      assigns: %{user_type: "tenant"}
  end

  # Enable Swoosh mailbox preview in development
  if Application.compile_env(:converger, :dev_routes) do
    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
