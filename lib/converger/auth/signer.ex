defmodule Converger.Auth.Signer do
  @moduledoc """
  Shared Joken signer for all token modules.
  """

  def signer do
    secret = Application.get_env(:converger, ConvergerWeb.Endpoint)[:secret_key_base]
    Joken.Signer.create("HS256", secret)
  end
end
