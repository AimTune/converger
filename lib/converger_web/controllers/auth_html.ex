defmodule ConvergerWeb.AuthHTML do
  @moduledoc """
  Pages shared by the admin panel and the tenant portal (ADR-0058): the 2FA
  login step, the security settings and the password reset forms. `@base`
  is `/admin` or `/portal`.
  """
  use ConvergerWeb, :html

  embed_templates "auth_html/*"

  @doc "A session's time for display."
  def format_time(%DateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M UTC")
  def format_time(_), do: ""
end
