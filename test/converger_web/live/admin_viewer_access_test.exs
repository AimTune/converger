defmodule ConvergerWeb.AdminViewerAccessTest do
  # Admin `viewer`s have read-only access (docs/security/overview.md): the
  # channel and routing rule pages hide their forms and actions and refuse
  # mutating events sent anyway.
  use ConvergerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Converger.AccountsFixtures
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.{Channels, RoutingRules}

  setup do
    tenant = tenant_fixture()
    source = channel_fixture(tenant)
    target = channel_fixture(tenant)

    {:ok, rule} =
      RoutingRules.create_routing_rule(%{
        name: "Viewer rule",
        tenant_id: tenant.id,
        source_channel_id: source.id,
        target_channel_ids: [target.id]
      })

    %{channel: source, rule: rule}
  end

  defp admin_conn(conn, role) do
    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> log_in_admin(admin_user_fixture(%{role: role}))
  end

  test "a viewer browses channels but cannot change them", %{conn: conn, channel: channel} do
    {:ok, view, html} = live(admin_conn(conn, "viewer"), ~p"/admin/channels")

    assert html =~ channel.name
    refute has_element?(view, "#channel-form")
    refute has_element?(view, "button[phx-click='rotate_secret']")
    refute has_element?(view, "button[phx-click='delete']")

    for event <- ~w(rotate_secret delete toggle_status pause_deliveries open_test) do
      assert render_hook(view, event, %{"id" => channel.id}) =~
               "Viewers have read-only access to channels."
    end

    reloaded = Channels.get_channel!(channel.id)
    assert reloaded.secret_hash == channel.secret_hash
    assert reloaded.status == channel.status
  end

  test "a viewer browses routing rules but cannot change them", %{conn: conn, rule: rule} do
    {:ok, view, html} = live(admin_conn(conn, "viewer"), ~p"/admin/routing_rules")

    assert html =~ rule.name
    refute has_element?(view, "#routing-rule-form")
    refute has_element?(view, "#rule-#{rule.id} button")

    for event <- ~w(toggle_enabled delete edit) do
      assert render_hook(view, event, %{"id" => rule.id}) =~
               "Viewers have read-only access to routing rules."
    end

    assert RoutingRules.get_routing_rule!(rule.id).enabled == rule.enabled
  end

  test "an admin still sees the channel and routing rule actions", %{conn: conn, rule: rule} do
    conn = admin_conn(conn, "admin")

    {:ok, view, _html} = live(conn, ~p"/admin/channels")
    assert has_element?(view, "#channel-form")
    assert has_element?(view, "button[phx-click='rotate_secret']")

    {:ok, view, _html} = live(conn, ~p"/admin/routing_rules")
    assert has_element?(view, "#routing-rule-form")
    assert has_element?(view, "#rule-#{rule.id} button")
  end
end
