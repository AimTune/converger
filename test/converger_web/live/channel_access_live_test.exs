defmodule ConvergerWeb.ChannelAccessLiveTest do
  @moduledoc """
  The channel pages' Client access panel (issues #194 and #195): test
  tokens and publishable keys from the admin panel and the tenant portal.
  """

  use ConvergerWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Converger.AccountsFixtures
  import Converger.TenantsFixtures
  import Converger.ChannelsFixtures

  alias Converger.{Accounts, Channels, Repo}
  alias Converger.AuditLogs.AuditLog
  alias Converger.Auth.ConvergerToken

  setup do
    tenant = tenant_fixture()
    %{tenant: tenant, channel: channel_fixture(tenant, type: "echo")}
  end

  defp admin_conn(conn, role) do
    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> log_in_admin(admin_user_fixture(%{role: role}))
  end

  defp portal_conn(conn, tenant, role) do
    {:ok, user} =
      Accounts.create_tenant_user(%{
        email: "access-#{role}-#{System.unique_integer([:positive])}@test.com",
        password: "testpassword123",
        name: "User",
        role: role,
        tenant_id: tenant.id
      })

    log_in_tenant_user(conn, user)
  end

  defp audit_actions(channel) do
    Repo.all(
      from a in AuditLog,
        where: a.resource_id == ^channel.id,
        order_by: [asc: a.inserted_at, asc: a.id],
        select: a.action
    )
  end

  # Drives the panel on `view` (admin or portal) through every action.
  defp exercise_panel(view, channel) do
    html = view |> element("#client-access-#{channel.id}") |> render_click()
    assert html =~ "Client access: #{channel.name}"
    # The browser's own address, not PHX_HOST.
    assert html =~ "ws://www.example.com/socket/converger/v1"

    html =
      view
      |> form("#test-token-form", access: %{user_id: "  tester-1 "})
      |> render_submit()

    [_, token] = Regex.run(~r/id="test-token-value"[^>]*title="([^"]+)"/, html)
    assert {:ok, claims} = ConvergerToken.verify_token(token)
    assert claims["channel_id"] == channel.id
    assert claims["user_id"] == "tester-1"
    refute Map.has_key?(claims, "conversation_id")

    # A key needs at least one origin.
    html =
      view
      |> form("#allowed-origins-form", access: %{allowed_origins: ""})
      |> put_submitter("#enable-publishable-key")
      |> render_submit()

    assert html =~ "add at least one origin"
    assert Channels.get_channel!(channel.id).publishable_key == nil

    html =
      view
      |> form("#allowed-origins-form", access: %{allowed_origins: "not an origin"})
      |> put_submitter("#enable-publishable-key")
      |> render_submit()

    assert html =~ "not an origin"

    html =
      view
      |> form("#allowed-origins-form",
        access: %{allowed_origins: "https://Shop.example.com/\nhttps://*.widgets.io"}
      )
      |> put_submitter("#enable-publishable-key")
      |> render_submit()

    assert html =~ "Publishable key enabled"
    enabled = Channels.get_channel!(channel.id)
    assert "cvg_pk_" <> _ = enabled.publishable_key
    assert enabled.allowed_origins == ["https://shop.example.com", "https://*.widgets.io"]
    assert html =~ enabled.publishable_key

    html =
      view
      |> form("#allowed-origins-form", access: %{allowed_origins: "http://localhost:5173"})
      |> render_submit()

    assert html =~ "Allowed origins saved"
    assert Channels.get_channel!(channel.id).allowed_origins == ["http://localhost:5173"]

    assert view |> element("#rotate-publishable-key") |> render() =~ "data-confirm"

    assert view |> element("#rotate-publishable-key") |> render_click() =~
             "Publishable key rotated"

    rotated = Channels.get_channel!(channel.id)
    refute rotated.publishable_key == enabled.publishable_key

    assert view |> element("#disable-publishable-key") |> render_click() =~
             "Publishable key disabled"

    assert Channels.get_channel!(channel.id).publishable_key == nil

    assert audit_actions(channel) == ~w(test_token enable_publishable_key update_allowed_origins
             rotate_publishable_key disable_publishable_key)

    refute view |> element("button[phx-click='close_access']") |> render_click() =~
             "Client access:"
  end

  describe "admin panel" do
    test "an admin issues test tokens and manages the publishable key",
         %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(admin_conn(conn, "admin"), ~p"/admin/channels")
      exercise_panel(view, channel)
    end

    test "inactive channels get no test token", %{conn: conn, channel: channel} do
      {:ok, _} = Channels.update_channel(channel, %{status: "inactive"})
      {:ok, view, _html} = live(admin_conn(conn, "super_admin"), ~p"/admin/channels")

      view |> element("#client-access-#{channel.id}") |> render_click()
      assert view |> element("#test-token-form button[type=submit]") |> render() =~ "disabled"

      assert render_submit(view, "issue_test_token", %{
               "access" => %{"channel_id" => channel.id, "user_id" => "x"}
             }) =~ "Enable the channel"

      assert audit_actions(channel) == []
    end

    test "a viewer cannot open the panel or use its events", %{conn: conn, channel: channel} do
      {:ok, view, _html} = live(admin_conn(conn, "viewer"), ~p"/admin/channels")

      refute has_element?(view, "#client-access-#{channel.id}")

      for {event, params} <- [
            {"open_access", %{"id" => channel.id}},
            {"issue_test_token", %{"access" => %{"channel_id" => channel.id}}},
            {"save_origins",
             %{
               "access" => %{"channel_id" => channel.id, "allowed_origins" => "https://a.io"},
               "key" => "new"
             }},
            {"rotate_publishable_key", %{"id" => channel.id}}
          ] do
        assert render_hook(view, event, params) =~ "Viewers have read-only access to channels."
      end

      assert Channels.get_channel!(channel.id).publishable_key == nil
      assert audit_actions(channel) == []
    end
  end

  describe "tenant portal" do
    test "an owner issues test tokens and manages the publishable key",
         %{conn: conn, tenant: tenant, channel: channel} do
      {:ok, view, _html} = live(portal_conn(conn, tenant, "owner"), ~p"/portal/channels")
      exercise_panel(view, channel)
    end

    test "members and viewers get neither", %{conn: conn, tenant: tenant, channel: channel} do
      for role <- ~w(member viewer) do
        {:ok, view, _html} = live(portal_conn(conn, tenant, role), ~p"/portal/channels")

        refute has_element?(view, "#client-access-#{channel.id}")
        assert render_click(view, "open_access", %{"id" => channel.id}) =~ "permission"

        assert render_submit(view, "issue_test_token", %{
                 "access" => %{"channel_id" => channel.id, "user_id" => "x"}
               }) =~ "permission"

        assert render_submit(view, "save_origins", %{
                 "access" => %{"channel_id" => channel.id, "allowed_origins" => "https://a.io"},
                 "key" => "new"
               }) =~ "permission"
      end

      assert Channels.get_channel!(channel.id).publishable_key == nil
      assert audit_actions(channel) == []
    end

    test "cannot act on another tenant's channel", %{conn: conn, tenant: tenant} do
      foreign = channel_fixture(tenant_fixture())
      {:ok, view, _html} = live(portal_conn(conn, tenant, "owner"), ~p"/portal/channels")

      assert render_click(view, "open_access", %{"id" => foreign.id}) =~ "Unauthorized"

      assert render_submit(view, "issue_test_token", %{
               "access" => %{"channel_id" => foreign.id, "user_id" => "x"}
             }) =~ "Unauthorized"

      assert render_click(view, "rotate_publishable_key", %{"id" => foreign.id}) =~
               "Unauthorized"

      assert Channels.get_channel!(foreign.id).publishable_key == nil
      assert audit_actions(foreign) == []
    end
  end
end
