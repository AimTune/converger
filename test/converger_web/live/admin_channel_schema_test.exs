defmodule ConvergerWeb.Admin.ChannelSchemaTest do
  # Mutates the :adapters app env.
  use ConvergerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Converger.Accounts
  alias Converger.Channels

  setup %{conn: conn} do
    {:ok, admin} =
      Accounts.create_admin_user(%{
        email: "schema-admin-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "Schema Admin",
        role: "super_admin"
      })

    conn =
      conn
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> init_test_session(%{admin_user_id: admin.id})

    %{conn: conn}
  end

  test "renders the config form from the adapter's config schema", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/channels")

    html = render_change(view, "form_changed", %{"channel" => %{"type" => "whatsapp_meta"}})

    assert html =~ ~s(name="channel[config][phone_number_id]")
    assert html =~ "Phone Number ID"
    assert html =~ ~r/type="password"[^>]*name="channel\[config\]\[access_token\]"/

    # Map fields (webhook headers) are API only.
    html = render_change(view, "form_changed", %{"channel" => %{"type" => "webhook"}})
    assert html =~ ~s(name="channel[config][url]")
    refute html =~ ~s(name="channel[config][headers]")
  end

  test "the #44 adapters get their config forms and create channels", %{conn: conn} do
    tenant = Converger.TenantsFixtures.tenant_fixture()
    {:ok, view, html} = live(conn, ~p"/admin/channels")

    for type <- ~w(messenger instagram viber discord teams http_pull),
        do: assert(html =~ ~s(<option value="#{type}"))

    for {type, field, secret} <- [
          {"messenger", "page_id", "page_access_token"},
          {"instagram", "account_id", "access_token"},
          {"viber", "sender_name", "auth_token"},
          {"discord", "public_key", "bot_token"},
          {"teams", "app_id", "app_password"}
        ] do
      html = render_change(view, "form_changed", %{"channel" => %{"type" => type}})
      assert html =~ ~s(name="channel[config][#{field}]")
      assert html =~ ~r/type="password"[^>]*name="channel\[config\]\[#{secret}\]"/
    end

    render_change(view, "form_changed", %{"channel" => %{"type" => "teams"}})

    assert view
           |> form("form",
             channel: %{
               name: "Teams bot",
               tenant_id: tenant.id,
               type: "teams",
               mode: "duplex",
               config: %{
                 app_id: "6d3c8a2e-1f4b-4c7a-9e2d-0b5a7c9e1f3d",
                 app_password: "pw-secret"
               }
             }
           )
           |> render_submit() =~ "Channel created"

    channel = Enum.find(Channels.list_channels(), &(&1.name == "Teams bot"))
    assert channel.config["app_password"] == "pw-secret"
    refute render(view) =~ "pw-secret"
  end

  test "a configured adapter appears in the type list and gets its form", %{conn: conn} do
    previous = Application.get_env(:converger, :adapters)
    Application.put_env(:converger, :adapters, [Converger.TestSmsAdapter])
    on_exit(fn -> Application.put_env(:converger, :adapters, previous) end)

    tenant = Converger.TenantsFixtures.tenant_fixture()
    {:ok, view, html} = live(conn, ~p"/admin/channels")

    assert html =~ ~s(<option value="test_sms")

    html = render_change(view, "form_changed", %{"channel" => %{"type" => "test_sms"}})
    assert html =~ "SMS API key"
    assert html =~ ~r/type="password"[^>]*name="channel\[config\]\[api_key\]"/
    assert html =~ ~r/type="number"[^>]*name="channel\[config\]\[max_parts\]"/

    assert view
           |> form("form",
             channel: %{
               name: "SMS",
               tenant_id: tenant.id,
               type: "test_sms",
               mode: "duplex",
               require_signature: "false",
               config: %{sender: "+15550100", api_key: "secret-key"}
             }
           )
           |> render_submit() =~ "Channel created"

    channel = Enum.find(Channels.list_channels(), &(&1.name == "SMS"))
    assert channel.type == "test_sms"

    html = render(view)
    assert html =~ "Sender number: +15550100"
    refute html =~ "secret-key"
  end
end
