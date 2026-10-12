defmodule ConvergerWeb.ApiSpecTest do
  use ConvergerWeb.ConnCase, async: true

  alias ConvergerWeb.ApiSpec

  @committed "priv/static/openapi.json"

  test "priv/static/openapi.json is up to date (run `mix openapi.spec.json`)" do
    assert File.read!(@committed) == ApiSpec.to_json(),
           "#{@committed} is out of date: run `mix openapi.spec.json` and commit it"
  end

  test "the document is OpenAPI 3.1 without 3.0-only keywords" do
    doc = ApiSpec.to_map()

    assert doc["openapi"] == "3.1.0"
    refute ApiSpec.to_json() =~ ~s("nullable")

    # 3.0 `nullable` became a "null" type member.
    assert doc["components"]["schemas"]["Participant"]["properties"]["display_name"]["type"] ==
             ["string", "null"]

    assert %{"anyOf" => [%{"$ref" => "#/components/schemas/Participant"}, %{"type" => "null"}]} =
             doc["components"]["schemas"]["Conversation"]["properties"]["participant"]
  end

  test "every $ref resolves" do
    doc = ApiSpec.to_map()

    for ref <- refs(doc) do
      ["#" | path] = String.split(ref, "/")
      assert get_in(doc, path), "unresolved #{ref}"
    end
  end

  test "operation ids are unique and named" do
    ids =
      for {_path, item} <- ApiSpec.to_map()["paths"],
          {_verb, %{"operationId" => id}} <- item,
          do: id

    assert ids == Enum.uniq(ids)
    assert Enum.all?(ids, &(&1 =~ ~r/^[a-z][A-Za-z]+$/))
  end

  test "every operation documents its error responses with the envelope" do
    doc = ApiSpec.to_map()

    for {path, item} <- doc["paths"], {verb, op} <- item do
      assert %{"$ref" => "#/components/responses/InternalError"} = op["responses"]["500"],
             "#{verb} #{path} has no 500 response"
    end
  end

  test "deprecated surfaces are marked deprecated" do
    paths = ApiSpec.to_map()["paths"]
    assert paths["/api/v1/tokens"]["post"]["deprecated"] == true
    assert paths["/api/v1/conversations"]["post"]["deprecated"] == true
  end

  describe "served documentation" do
    test "GET /api/openapi.json serves the committed document", %{conn: conn} do
      conn = get(conn, "/api/openapi.json")
      assert response(conn, 200) == File.read!(@committed)
      assert response_content_type(conn, :json)
    end

    test "GET /api/docs renders Swagger UI with bearer auth", %{conn: conn} do
      conn = get(conn, "/api/docs")
      html = html_response(conn, 200)

      assert html =~ "swagger-ui"
      assert html =~ "/api/openapi.json"
      assert html =~ "persistAuthorization"

      [csp] = get_resp_header(conn, "content-security-policy")
      [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, csp)
      assert html =~ ~s(nonce="#{nonce}")

      schemes = ApiSpec.to_map()["components"]["securitySchemes"]
      assert %{"type" => "http", "scheme" => "bearer"} = schemes["convergerToken"]
      assert %{"type" => "http", "scheme" => "bearer"} = schemes["channelSecret"]
      assert %{"type" => "apiKey", "in" => "header", "name" => "x-api-key"} = schemes["apiKey"]
    end
  end

  defp refs(%{"$ref" => ref} = map), do: [ref | map |> Map.delete("$ref") |> refs()]
  defp refs(%{} = map), do: Enum.flat_map(map, fn {_k, v} -> refs(v) end)
  defp refs(list) when is_list(list), do: Enum.flat_map(list, &refs/1)
  defp refs(_), do: []
end
