defmodule ConvergerWeb.Live.ChannelAccess do
  @moduledoc """
  The channel pages' Client access panel, shared by the admin panel
  (`ConvergerWeb.Admin.ChannelLive`) and the tenant portal
  (`ConvergerWeb.Portal.ChannelLive`): the endpoints a chat client connects
  to, a test token (issue #194) and the publishable key with its allowed
  origins (issue #195, ADR-0074).

  The LiveViews check permissions and the tenant scope, then call these
  functions with the channel and the audit actor.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Converger.Channels

  @default_user_id "test-user"

  def init(socket) do
    assign(socket,
      access_channel: nil,
      access_base_url: nil,
      access_user_id: @default_user_id,
      test_token: nil,
      origins_error: nil
    )
  end

  @doc """
  Remembers the base URL the browser uses (from `handle_params/3`'s URL), so
  the panel shows the address clients reach, whatever `PHX_HOST` says.
  """
  def put_base_url(socket, url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        port = if uri.port in [80, 443], do: "", else: ":#{uri.port}"
        assign(socket, access_base_url: "#{scheme}://#{host}#{port}")

      _ ->
        socket
    end
  end

  def open(socket, channel) do
    assign(socket, access_channel: channel, test_token: nil, origins_error: nil)
  end

  def close(socket), do: assign(socket, access_channel: nil, test_token: nil, origins_error: nil)

  def issue_test_token(socket, channel, user_id, actor) do
    case Channels.issue_test_token(channel, user_id, actor) do
      {:ok, token, claims} ->
        assign(socket,
          access_channel: channel,
          access_user_id: claims["user_id"] || "",
          test_token: %{
            token: token,
            user_id: claims["user_id"],
            expires_at: DateTime.from_unix!(claims["exp"])
          }
        )

      {:error, :inactive} ->
        put_flash(socket, :error, "Enable the channel to issue a test token")
    end
  end

  @doc "`key` is `:keep` (save origins), `:new` (enable or rotate) or `:none`."
  def update_key(socket, channel, attrs, key, actor) do
    case Channels.update_client_access(channel, attrs, key, actor) do
      {:ok, updated} ->
        socket
        |> assign(access_channel: updated, origins_error: nil)
        |> put_flash(:info, key_message(channel, key))

      {:error, %Ecto.Changeset{} = changeset} ->
        message =
          case Keyword.get_values(changeset.errors, :allowed_origins) do
            [{msg, _} | _] -> msg
            _ -> "Failed to update the publishable key"
          end

        assign(socket, access_channel: channel, origins_error: message)
    end
  end

  defp key_message(%{publishable_key: nil}, :new), do: "Publishable key enabled"
  defp key_message(_channel, :new), do: "Publishable key rotated"
  defp key_message(_channel, :none), do: "Publishable key disabled"
  defp key_message(_channel, :keep), do: "Allowed origins saved"
end
