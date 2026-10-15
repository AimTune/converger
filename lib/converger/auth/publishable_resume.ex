defmodule Converger.Auth.PublishableResume do
  @moduledoc """
  The `resume` credential of `POST /api/v1/converger/tokens/publishable`
  (ADR-0074): a signed, expiring statement that an anonymous visitor owns a
  conversation of a channel. Presenting it again (a page reload) returns a
  fresh token for the same conversation and end user.

  It is a `Phoenix.Token` signed with the endpoint's `secret_key_base`, so it
  cannot be forged or pointed at another conversation; rotating
  `SECRET_KEY_BASE` invalidates every outstanding credential (visitors then
  start new conversations). Lifetime:

      config :converger, Converger.Auth.PublishableResume, max_age: 604_800

  (`PUBLISHABLE_RESUME_MAX_AGE` in seconds, default 7 days.)
  """

  @salt "converger publishable resume v1"
  @default_max_age 7 * 24 * 3600

  @doc "Signs a credential for `user_id`'s `conversation_id` in `channel_id`."
  def sign(channel_id, conversation_id, user_id) do
    Phoenix.Token.sign(ConvergerWeb.Endpoint, @salt, %{
      "ch" => channel_id,
      "cv" => conversation_id,
      "u" => user_id
    })
  end

  @doc """
  Verifies `credential` for `channel_id`. Returns
  `{:ok, %{conversation_id: _, user_id: _}}`, or `:error` when it is invalid,
  expired or was issued for another channel.
  """
  def verify(credential, channel_id) when is_binary(credential) and credential != "" do
    case Phoenix.Token.verify(ConvergerWeb.Endpoint, @salt, credential, max_age: max_age()) do
      {:ok, %{"ch" => ^channel_id, "cv" => conversation_id, "u" => user_id}} ->
        {:ok, %{conversation_id: conversation_id, user_id: user_id}}

      _ ->
        :error
    end
  end

  def verify(_credential, _channel_id), do: :error

  @doc "How long a credential stays valid, in seconds."
  def max_age do
    :converger
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_age, @default_max_age)
  end
end
