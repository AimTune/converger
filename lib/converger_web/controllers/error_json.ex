defmodule ConvergerWeb.ErrorJSON do
  @moduledoc """
  Renders errors raised as exceptions (`render_errors` in config/config.exs:
  unknown routes, `Ecto.NoResultsError`, `Phoenix.ActionClauseError`,
  `Plug.Parsers` errors, crashes) in the API error envelope
  (`ConvergerWeb.APIError`). The code is derived from the status; the
  message is the code's generic message, so nothing about the exception
  leaks.
  """

  alias ConvergerWeb.APIError

  def render(template, assigns) do
    status = status_from_template(template)
    code = APIError.code_for_status(status)

    code
    |> APIError.new(nil, nil, status: status)
    |> APIError.body(APIError.request_id(assigns[:conn]))
  end

  defp status_from_template(template) do
    case template |> String.split(".") |> hd() |> Integer.parse() do
      {status, ""} -> status
      _ -> 500
    end
  end
end
