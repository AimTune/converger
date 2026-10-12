defmodule ConvergerWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ConvergerWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  using do
    quote do
      # The default endpoint for testing
      @endpoint ConvergerWeb.Endpoint

      use ConvergerWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ConvergerWeb.ConnCase
    end
  end

  @doc """
  POSTs `params` as a JSON body signed with the channel secret using the
  generic `x-converger-signature` scheme (`t=...,v1=...`).
  """
  def signed_post(conn, path, channel, params, opts \\ []) do
    body = Jason.encode!(params)
    timestamp = Keyword.get(opts, :timestamp, System.system_time(:second))
    signature = Converger.Channels.InboundSignature.sign(channel.secret, body, timestamp)

    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-converger-signature", signature)
    |> Phoenix.ConnTest.dispatch(ConvergerWeb.Endpoint, :post, path, body)
  end

  @doc """
  Asserts that `conn` answered `status` with the API error envelope
  (`ConvergerWeb.APIError`, ADR-0050) and the error `code`, and that the body
  matches the OpenAPI `ErrorResponse` schema. Returns the `error` object.
  """
  def assert_api_error(conn, status, code) do
    body = Phoenix.ConnTest.json_response(conn, status)

    assert %{"error" => error} = body
    assert map_size(body) == 1
    assert error |> Map.keys() |> Enum.sort() == ~w(code details message request_id)
    assert error["code"] == code
    assert code in ConvergerWeb.APIError.code_names()
    assert is_binary(error["message"]) and error["message"] != ""
    assert is_nil(error["details"]) or is_map(error["details"])

    case Plug.Conn.get_resp_header(conn, "x-request-id") do
      [request_id] -> assert error["request_id"] == request_id
      [] -> :ok
    end

    OpenApiSpex.TestAssertions.assert_schema(body, "ErrorResponse", ConvergerWeb.ApiSpec.spec())
    error
  end

  @doc """
  Asserts that the response matches the OpenAPI response schema of the
  operation that handled it (looked up from the controller and action) for
  its status. Returns the conn.
  """
  def assert_api_response(conn) do
    # Plugs that halt (auth, rate limits) answer before the controller runs:
    # find the action from the route.
    %{plug: controller, plug_opts: action} =
      Phoenix.Router.route_info(ConvergerWeb.Router, conn.method, conn.request_path, conn.host)

    %OpenApiSpex.Operation{operationId: operation_id} = controller.open_api_operation(action)

    conn
    |> Plug.Conn.put_private(:open_api_spex, %{spec_module: ConvergerWeb.ApiSpec})
    |> OpenApiSpex.TestAssertions.assert_operation_response(operation_id)
  end

  setup tags do
    Converger.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
