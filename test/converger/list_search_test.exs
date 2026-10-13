defmodule Converger.ListSearchTest do
  @moduledoc "Search, filters and keyset pagination of the tenant and user lists (#50)."
  use Converger.DataCase, async: true

  import Converger.AccountsFixtures
  import Converger.TenantsFixtures

  alias Converger.{Accounts, Tenants}

  defp ids(%{entries: entries}), do: entries |> Enum.map(& &1.id) |> MapSet.new()

  describe "Tenants.paginate_tenants/2" do
    test "searches by name (escaping wildcards) or exact id, and filters by status" do
      alpha = tenant_fixture(%{name: "Alpha 50%"})
      beta = tenant_fixture(%{name: "Beta", status: "inactive"})

      assert {:ok, page} = Tenants.paginate_tenants(%{"q" => "alpha"})
      assert ids(page) == MapSet.new([alpha.id])

      assert {:ok, page} = Tenants.paginate_tenants(%{"q" => "%"})
      assert ids(page) == MapSet.new([alpha.id])

      assert {:ok, page} = Tenants.paginate_tenants(%{q: " #{beta.id} "})
      assert ids(page) == MapSet.new([beta.id])

      assert {:ok, page} = Tenants.paginate_tenants(%{"status" => "inactive", "q" => ""})
      assert ids(page) == MapSet.new([beta.id])
    end

    test "pages in both directions" do
      [a, b, c] = for _ <- 1..3, do: tenant_fixture()

      {:ok, page} = Tenants.paginate_tenants(%{}, limit: 2)
      assert Enum.map(page.entries, & &1.id) == [c.id, b.id]
      assert page.has_more

      {:ok, page} = Tenants.paginate_tenants(%{}, limit: 2, cursor: page.next_cursor)
      assert Enum.map(page.entries, & &1.id) == [a.id]
      refute page.has_more

      {:ok, page} = Tenants.paginate_tenants(%{}, limit: 2, direction: :asc)
      assert Enum.map(page.entries, & &1.id) == [a.id, b.id]
    end
  end

  describe "Accounts.paginate_admin_users/2" do
    test "searches name/email and filters role and status" do
      ann = admin_user_fixture(%{name: "Ann Ops", role: "admin"})
      ben = admin_user_fixture(%{name: "Ben", email: "ben_x@test.com", role: "viewer"})

      {:ok, cy} =
        Accounts.update_admin_user(admin_user_fixture(%{name: "Cy"}), %{status: "inactive"})

      assert {:ok, page} = Accounts.paginate_admin_users(%{"q" => "ann"})
      assert ids(page) == MapSet.new([ann.id])

      assert {:ok, page} = Accounts.paginate_admin_users(%{"q" => "BEN_X"})
      assert ids(page) == MapSet.new([ben.id])

      assert {:ok, page} = Accounts.paginate_admin_users(%{role: "viewer"})
      assert ids(page) == MapSet.new([ben.id])

      assert {:ok, page} = Accounts.paginate_admin_users(%{"status" => "inactive"})
      assert ids(page) == MapSet.new([cy.id])

      assert {:ok, page} = Accounts.paginate_admin_users(%{}, limit: 1, direction: :asc)
      assert Enum.map(page.entries, & &1.id) == [ann.id]
      assert page.has_more
    end
  end

  describe "Accounts.paginate_tenant_users/2" do
    test "combines tenant, search, role and status filters" do
      tenant = tenant_fixture()
      dee = tenant_user_fixture(tenant, %{name: "Dee", role: "member"})

      {:ok, eve} =
        Accounts.update_tenant_user(tenant_user_fixture(tenant, %{name: "Eve"}), %{
          status: "inactive"
        })

      outsider = tenant_user_fixture(tenant_fixture(), %{name: "Dee Too"})

      assert {:ok, page} = Accounts.paginate_tenant_users(%{"q" => "dee"})
      assert ids(page) == MapSet.new([dee.id, outsider.id])

      assert {:ok, page} =
               Accounts.paginate_tenant_users(%{"tenant_id" => tenant.id, "q" => "dee"})

      assert ids(page) == MapSet.new([dee.id])
      assert [%{tenant: %{id: tenant_id}}] = page.entries
      assert tenant_id == tenant.id

      assert {:ok, page} = Accounts.paginate_tenant_users(%{tenant_id: tenant.id, role: "member"})
      assert ids(page) == MapSet.new([dee.id])

      assert {:ok, page} = Accounts.paginate_tenant_users(%{"status" => "inactive"})
      assert ids(page) == MapSet.new([eve.id])

      assert {:ok, page} = Accounts.paginate_tenant_users(%{"tenant_id" => "nope"})
      assert page.entries == []
    end
  end
end
