defmodule Converger.Channels.Email.Outbound do
  @moduledoc """
  Builds the outbound email of an activity, and the Swoosh adapter and config
  of an `email` channel.

  ## Threading

  Every email gets a deterministic `Message-ID`,
  `<converger.<activity id>@<from domain>>`, so a retried delivery sends the
  same id. When the conversation already holds an inbound email (on any email
  channel), the outbound one is a reply to the latest of them: `In-Reply-To`
  is its `Message-ID`, `References` its references plus that id, and the
  subject is `Re: <its subject>`. Replies to the outbound email carry these
  ids back, and `Converger.Inbound` resolves them to the conversation.

  ## Content

  The text part is the activity text, followed by links to its attachments
  that are not attached. The HTML part is the escaped text with line breaks.
  Attachments uploaded to Converger (`/api/v1/converger/attachments/:id` of
  the channel's tenant) are attached, up to `max_attachment_bytes` in total
  (default: the upload size limit); others are linked.
  """

  import Ecto.Query, warn: false

  alias Converger.Activities.Activity
  alias Converger.Channels.Email.Address
  alias Converger.{Repo, Uploads}

  @providers %{
    "smtp" => Swoosh.Adapters.SMTP,
    "ses" => Swoosh.Adapters.AmazonSES,
    "sendgrid" => Swoosh.Adapters.Sendgrid,
    "mailgun" => Swoosh.Adapters.Mailgun,
    "postmark" => Swoosh.Adapters.Postmark
  }

  @mailgun_base_urls %{
    "us" => "https://api.mailgun.net/v3",
    "eu" => "https://api.eu.mailgun.net/v3"
  }

  @upload_path ~r"/api/v1/converger/attachments/([0-9a-fA-F-]{36})\z"

  @doc "The outbound providers."
  def providers, do: Map.keys(@providers)

  @doc """
  The Swoosh adapter module and config of a channel. Tests replace the
  adapter with `config :converger, :email_swoosh_adapter`.
  """
  @spec swoosh(map()) :: {module(), keyword()}
  def swoosh(config) do
    provider = config["provider"]

    adapter =
      Application.get_env(:converger, :email_swoosh_adapter) || Map.fetch!(@providers, provider)

    {adapter, swoosh_config(provider, config)}
  end

  defp swoosh_config("smtp", config) do
    [
      relay: config["smtp_host"],
      port: to_int(config["smtp_port"]) || 587,
      username: config["smtp_username"],
      password: config["password"],
      ssl: config["smtp_ssl"] in [true, "true"],
      tls: if(config["smtp_ssl"] in [true, "true"], do: :never, else: :always),
      auth: if(blank?(config["smtp_username"]), do: :never, else: :always),
      retries: 0,
      no_mx_lookups: true
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp swoosh_config("ses", config) do
    [
      region: config["aws_region"],
      access_key: config["aws_access_key_id"],
      secret: config["aws_access_key_secret"]
    ]
  end

  defp swoosh_config("mailgun", config) do
    [
      api_key: config["api_key"],
      domain: config["mailgun_domain"],
      base_url: Map.get(@mailgun_base_urls, config["mailgun_region"] || "us")
    ]
  end

  defp swoosh_config(_provider, config), do: [api_key: config["api_key"]]

  @doc "The Mailgun regions (`mailgun_region`)."
  def mailgun_regions, do: Map.keys(@mailgun_base_urls)

  @doc "The `Message-ID` (without brackets) of the email of `activity`."
  def message_id(activity, config) do
    {_, from} = Address.parse(config["from"]) || {nil, "converger@localhost"}
    "converger.#{activity.id}@#{Address.domain(from) || "localhost"}"
  end

  @doc """
  The activity id embedded in one of our `Message-ID`s (`message_id/2`), or
  nil.
  """
  def activity_id_from_message_id(id) when is_binary(id) do
    case Regex.run(~r/\Aconverger\.([0-9a-fA-F-]{36})@/, id) do
      [_, activity_id] -> activity_id
      nil -> nil
    end
  end

  def activity_id_from_message_id(_), do: nil

  @doc """
  The latest inbound email of the activity's conversation (its `metadata`
  `"email"` map), or nil.
  """
  def thread(%Activity{conversation_id: conversation_id}) when is_binary(conversation_id) do
    from(a in Activity,
      where:
        a.conversation_id == ^conversation_id and
          not is_nil(fragment("?->'email'->>'message_id'", a.metadata)),
      order_by: [desc: a.seq],
      limit: 1,
      select: fragment("?->'email'", a.metadata)
    )
    |> Repo.one()
  end

  def thread(_activity), do: nil

  @doc "Build the `Swoosh.Email` of `activity` to `recipient`."
  @spec build(map(), Activity.t(), String.t(), map() | nil) :: Swoosh.Email.t()
  def build(channel, activity, recipient, thread) do
    config = channel.config || %{}
    id = message_id(activity, config)
    {attached, linked} = attachments(channel, activity, config)

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to(recipient)
      |> Swoosh.Email.from(sender(config["from"]))
      |> Swoosh.Email.subject(subject(activity, config, thread))
      |> Swoosh.Email.header("Message-ID", Address.bracket(id))
      |> Swoosh.Email.text_body(text_body(activity.text, linked))
      |> Swoosh.Email.html_body(html_body(activity.text, linked))
      |> maybe_reply_to(config["reply_to"])
      |> thread_headers(thread)

    Enum.reduce(attached, email, &Swoosh.Email.attachment(&2, &1))
  end

  defp sender(value) do
    case Address.parse(value) do
      {nil, address} -> address
      {name, address} -> {name, address}
      nil -> value
    end
  end

  defp maybe_reply_to(email, value) when value in [nil, ""], do: email
  defp maybe_reply_to(email, value), do: Swoosh.Email.reply_to(email, sender(value))

  defp thread_headers(email, %{"message_id" => parent} = thread) when is_binary(parent) do
    references =
      (List.wrap(thread["references"]) ++ [parent])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.take(-20)
      |> Enum.map_join(" ", &Address.bracket/1)

    email
    |> Swoosh.Email.header("In-Reply-To", Address.bracket(parent))
    |> Swoosh.Email.header("References", references)
  end

  defp thread_headers(email, _thread), do: email

  @doc """
  The subject: the activity's `metadata.email_subject`, else `Re: <subject>`
  of the thread, else the channel's `subject_template` (`{{conversation_id}}`
  and `{{sender}}` are replaced; default `New message`).
  """
  def subject(activity, config, thread) do
    thread_subject = thread && thread["subject"]

    cond do
      is_binary(activity.metadata["email_subject"]) and activity.metadata["email_subject"] != "" ->
        activity.metadata["email_subject"]

      is_binary(thread_subject) and thread_subject != "" ->
        if Regex.match?(~r/\A\s*re:/i, thread_subject),
          do: thread_subject,
          else: "Re: " <> thread_subject

      true ->
        (config["subject_template"] || "New message")
        |> String.replace("{{conversation_id}}", to_string(activity.conversation_id))
        |> String.replace("{{sender}}", to_string(activity.sender))
    end
  end

  defp text_body(text, linked) do
    links = for {name, url} <- linked, do: "#{name}: #{url}"
    Enum.join(Enum.reject([text || "" | links], &(&1 == "")), "\n\n")
  end

  defp html_body(text, linked) do
    paragraphs =
      (text || "")
      |> escape()
      |> String.replace(~r/\r?\n/, "<br>\n")

    links =
      for {name, url} <- linked do
        ~s(<p><a href="#{escape(url)}">#{escape(name)}</a></p>)
      end

    Enum.join(["<p>#{paragraphs}</p>" | links], "\n")
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  # {[Swoosh.Attachment], [{name, url}]}
  defp attachments(channel, activity, config) do
    budget = to_int(config["max_attachment_bytes"]) || Uploads.max_file_size()

    {attached, linked, _budget} =
      activity.attachments
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.reduce({[], [], budget}, fn attachment, {attached, linked, budget} ->
        url = attachment["contentUrl"]
        name = attachment["name"] || "attachment"

        case stored(channel.tenant_id, url) do
          %Uploads.Attachment{size: size} = stored when size <= budget ->
            case Uploads.read(stored) do
              {:ok, data} ->
                file =
                  Swoosh.Attachment.new({:data, data},
                    filename: attachment["name"] || stored.filename || "attachment",
                    content_type: stored.content_type
                  )

                {[file | attached], linked, budget - size}

              {:error, _} ->
                {attached, link(linked, name, url), budget}
            end

          _ ->
            {attached, link(linked, name, url), budget}
        end
      end)

    {Enum.reverse(attached), Enum.reverse(linked)}
  end

  defp link(linked, _name, url) when not is_binary(url) or url == "", do: linked
  defp link(linked, name, url), do: [{name, absolute(url)} | linked]

  defp absolute("/" <> _ = path), do: ConvergerWeb.Endpoint.url() <> path
  defp absolute(url), do: url

  defp stored(tenant_id, url) when is_binary(url) do
    case Regex.run(@upload_path, URI.parse(url).path || "") do
      [_, id] -> Uploads.get_attachment(tenant_id, id)
      nil -> nil
    end
  end

  defp stored(_tenant_id, _url), do: nil

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  defp blank?(value), do: value in [nil, ""]
end
