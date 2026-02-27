defmodule ConvergerWeb.Router do
  use ConvergerWeb, :router

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
  end

  scope "/admin", ConvergerWeb.Admin do
    pipe_through [:browser, :admin_auth]

    live "/", DashboardLive
    live "/tenants", TenantLive
    live "/channels", ChannelLive
    live "/conversations", ConversationLive, :index
    live "/conversations/:id", ConversationLive, :show
    live "/routing_rules", RoutingRuleLive
  end

  # Enable Swoosh mailbox preview in development
  if Application.compile_env(:converger, :dev_routes) do
    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
