defmodule Converger.Accounts.UserNotifier do
  @moduledoc """
  Account emails to admin and tenant users (password reset), sent through
  `Converger.Mailer` from `:converger, :mailer_from` (env `MAILER_FROM`).
  """

  import Swoosh.Email

  alias Converger.Mailer

  @default_from {"Converger", "noreply@converger.local"}

  @doc "The sender: an address or a `{name, address}` tuple."
  def sender, do: Application.get_env(:converger, :mailer_from) || @default_from

  @doc "Mails the password reset link `url` to `user`."
  def deliver_reset_password_instructions(user, url) do
    deliver(user.email, "Reset your Converger password", """
    Hi #{user.name},

    Someone (hopefully you) asked to reset the password of your Converger
    account #{user.email}. Open this link to choose a new password:

    #{url}

    The link works once and expires in one hour. Resetting the password signs
    you out of every device.

    If you did not ask for this, ignore this email; your password stays as it is.
    """)
  end

  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(sender())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end
end
