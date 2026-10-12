defmodule ConvergerWeb.Plugs.ApiDocs do
  @moduledoc """
  Guards the API documentation routes (`GET /api/docs`, Swagger UI, and
  `GET /api/openapi.json`, ADR-0050).

  They are served only when `config :converger, :api_docs, enabled: true`:
  on in dev and test, off in prod unless `API_DOCS_ENABLED=true`. Disabled,
  they answer `404 not_found` like any unknown route.

  Swagger UI loads its bundle from cdnjs and boots with an inline script, so
  the page gets its own Content-Security-Policy with a per-request script
  nonce (assigned as `:csp_nonce`, read by `OpenApiSpex.Plug.SwaggerUI`).
  """

  @behaviour Plug

  import Plug.Conn

  alias ConvergerWeb.APIError

  @cdn "https://cdnjs.cloudflare.com"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if enabled?() do
      nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

      conn
      |> assign(:csp_nonce, nonce)
      |> put_resp_header("content-security-policy", csp(nonce))
      |> put_resp_header("x-content-type-options", "nosniff")
    else
      APIError.send_error(conn, "not_found")
    end
  end

  @doc "Whether the API documentation routes are served."
  def enabled?, do: Keyword.get(Application.get_env(:converger, :api_docs, []), :enabled, false)

  defp csp(nonce) do
    "default-src 'self'; script-src 'self' 'nonce-#{nonce}' #{@cdn}; " <>
      "style-src 'self' 'unsafe-inline' #{@cdn}; img-src 'self' data:; connect-src 'self'; " <>
      "object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
  end
end
