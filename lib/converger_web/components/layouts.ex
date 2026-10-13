defmodule ConvergerWeb.Layouts do
  @moduledoc """
  Layouts of the admin panel and the tenant portal (ADR-0060).

  `root.html.heex` is the HTML skeleton of every page. LiveViews wrap their
  content in `app/1` (sidebar, navbar, flash messages); the controller-rendered
  login and password pages use `auth/1`.
  """
  use ConvergerWeb, :html

  embed_templates "layouts/*"

  @admin_nav [
    {"Dashboard", "/admin", "hero-home"},
    {"Tenants", "/admin/tenants", "hero-building-office-2"},
    {"Channels", "/admin/channels", "hero-signal"},
    {"Conversations", "/admin/conversations", "hero-chat-bubble-left-right"},
    {"Routing Rules", "/admin/routing_rules", "hero-arrows-right-left"},
    {"Deliveries", "/admin/deliveries", "hero-paper-airplane"},
    {"Webhooks", "/admin/webhooks", "hero-bolt"},
    {"Audit Logs", "/admin/audit_logs", "hero-clipboard-document-list"},
    {"Admin Users", "/admin/users", "hero-shield-check"},
    {"Tenant Users", "/admin/tenant_users", "hero-users"},
    {"Jobs (Oban)", "/admin/oban", "hero-queue-list"}
  ]

  @portal_nav [
    {"Dashboard", "/portal", "hero-home"},
    {"Channels", "/portal/channels", "hero-signal"},
    {"Conversations", "/portal/conversations", "hero-chat-bubble-left-right"},
    {"Deliveries", "/portal/deliveries", "hero-paper-airplane"},
    {"Routing Rules", "/portal/routing_rules", "hero-arrows-right-left"},
    {"Webhooks", "/portal/webhooks", "hero-bolt"},
    {"Users", "/portal/users", "hero-users"}
  ]

  @doc """
  Renders the admin / portal page frame: a sidebar with the section's
  navigation, a navbar with the signed-in user, and the flash messages.

  `nav` is assigned by `ConvergerWeb.Live.AuthHooks` on mount:
  `%{section: :admin | :portal, user: user, tenant: tenant | nil, path: path}`.

  ## Examples

      <Layouts.app flash={@flash} nav={@nav}>
        <.header>Tenants</.header>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :nav, :map, required: true, doc: "section, user, tenant and path (AuthHooks)"
  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assign(assigns,
        items: if(assigns.nav.section == :portal, do: @portal_nav, else: @admin_nav),
        home: if(assigns.nav.section == :portal, do: "/portal", else: "/admin"),
        logout: if(assigns.nav.section == :portal, do: "/portal/logout", else: "/admin/logout")
      )

    ~H"""
    <div class="drawer lg:drawer-open">
      <input id="nav-drawer" type="checkbox" class="drawer-toggle" aria-label="Toggle navigation" />
      <div class="drawer-content flex min-h-screen flex-col">
        <header class="navbar sticky top-0 z-30 gap-2 border-b border-base-300 bg-base-100/90 px-4 backdrop-blur sm:px-6">
          <label for="nav-drawer" class="btn btn-square btn-ghost lg:hidden" aria-label="Open navigation">
            <.icon name="hero-bars-3" class="size-5" />
          </label>
          <div class="flex-1">
            <span
              :if={@nav.section == :portal && @nav.tenant}
              id="current-tenant"
              class="badge badge-outline"
            >
              {@nav.tenant.name}
            </span>
          </div>
          <.theme_toggle />
          <div :if={@nav.user} id="current-user" class="hidden items-center gap-2 text-sm sm:flex">
            <span class="font-medium">{@nav.user.name}</span>
            <.badge value={@nav.user.role} />
          </div>
          <.link
            href={@logout}
            method="delete"
            class="btn btn-ghost btn-sm"
            aria-label="Log out"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" />
            <span class="hidden sm:inline">Logout</span>
          </.link>
        </header>

        <main class="flex-1 px-4 py-6 sm:px-6 lg:px-8">
          <div class="mx-auto max-w-7xl space-y-6">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <div class="drawer-side z-40">
        <label for="nav-drawer" class="drawer-overlay" aria-label="Close navigation"></label>
        <nav aria-label="Main navigation" class="flex min-h-full w-64 flex-col border-r border-base-300 bg-base-200">
          <.link navigate={@home} class="flex items-center gap-2 px-5 py-4 text-lg font-semibold">
            <.icon name="hero-arrows-pointing-in" class="size-6 text-primary" /> Converger
            <span class="badge badge-sm badge-ghost">
              {if @nav.section == :portal, do: "Portal", else: "Admin"}
            </span>
          </.link>
          <ul class="menu w-full gap-0.5 px-3">
            <li :for={{label, path, icon} <- @items}>
              <.link
                navigate={path}
                class={active?(@nav.path, path, @home) && "menu-active"}
                aria-current={active?(@nav.path, path, @home) && "page"}
              >
                <.icon name={icon} class="size-5" /> {label}
              </.link>
            </li>
          </ul>
        </nav>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc false
  def title_suffix(%{section: :portal}), do: " · Converger Portal"
  def title_suffix(%{section: :admin}), do: " · Converger Admin"
  def title_suffix(_), do: " · Converger"

  # The section home is only active on itself; other items also on sub-paths
  # (/admin/conversations/:id).
  defp active?(nil, _path, _home), do: false
  defp active?(current, home, home), do: current == home

  defp active?(current, path, _home),
    do: current == path or String.starts_with?(current, path <> "/")

  @doc """
  Renders the centered frame of the login and password pages.
  """
  attr :flash, :map, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <main class="flex min-h-screen items-center justify-center bg-base-200 px-4 py-12">
      <div class="w-full max-w-sm space-y-6">
        <div class="flex items-center justify-between">
          <span class="flex items-center gap-2 text-lg font-semibold">
            <.icon name="hero-arrows-pointing-in" class="size-6 text-primary" /> Converger
          </span>
          <.theme_toggle />
        </div>
        <div class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body gap-4">
            <div>
              <h1 class="text-xl font-semibold">{@title}</h1>
              <p :if={@subtitle} class="text-sm text-base-content/70">{@subtitle}</p>
            </div>
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides the system / light / dark theme toggle.

  The `<head>` of `root.html.heex` applies the stored theme before the page
  paints and listens for `phx:set-theme`; plain (controller) pages get click
  handlers there as well.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center rounded-full border-2 border-base-300 bg-base-300">
      <div class="absolute left-0 h-full w-1/3 rounded-full border-1 border-base-200 bg-base-100 brightness-200 transition-[left] [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0" />

      <button
        type="button"
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        type="button"
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        type="button"
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
