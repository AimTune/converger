defmodule ConvergerWeb.ApiDocsController do
  @moduledoc """
  `GET /api/openapi.json`: the OpenAPI 3.1 document
  (`ConvergerWeb.ApiSpec.to_json/0`, the same bytes as the committed
  `priv/static/openapi.json`). Behind `ConvergerWeb.Plugs.ApiDocs`.
  """
  use ConvergerWeb, :controller

  @cache_key {__MODULE__, :spec}

  # sobelow_skip ["XSS.SendResp"]
  def spec(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, document())
  end

  # The document only changes with the code: built once per node in prod;
  # elsewhere rebuilt per request, so code reloading shows changes.
  defp document do
    if Application.get_env(:converger, :env) == :prod do
      case :persistent_term.get(@cache_key, nil) do
        nil ->
          json = ConvergerWeb.ApiSpec.to_json()
          :persistent_term.put(@cache_key, json)
          json

        json ->
          json
      end
    else
      ConvergerWeb.ApiSpec.to_json()
    end
  end
end
