defmodule Converger.Channels.Adapters.Email do
  @moduledoc """
  The `email` channel adapter: outbound mail through Swoosh (SMTP, Amazon
  SES, SendGrid, Mailgun, Postmark), inbound mail through the providers'
  parse webhooks or a raw `message/rfc822` body, and bounces / complaints
  as `failed` delivery statuses.

  A participant is a normalized email address. A reply lands in the
  conversation of the email it answers: the inbound message carries the
  ids of its `In-Reply-To` / `References` headers (`"thread_refs"`,
  `"thread_activity_ids"`), which `Converger.Inbound` resolves before falling
  back to the sender's active conversation.

  See `docs/channels/email.md` and `Converger.Channels.Email.Providers`.
  """

  use Converger.Channels.Adapter, type: "email"

  require Logger

  alias Converger.{Activities, Participants, Uploads}
  alias Converger.Channels.{DeliveryError, InboundSignature, UrlGuard}
  alias Converger.Channels.Email.{Address, Outbound, Providers, ReplyParser, SNS}

  @max_text_bytes 60_000
  @max_full_text_bytes 8_000
  @max_subject_bytes 998
  @max_attachments 10
  @max_refs 20

  @impl true
  def capabilities do
    [
      :inbound,
      :outbound,
      :external_delivery,
      :receipts,
      :provider_ack,
      :media,
      activity_types: ~w(message)
    ]
  end

  @impl true
  def config_schema do
    [
      %{
        name: "provider",
        type: :string,
        required: true,
        summary: true,
        label: "Outbound provider",
        placeholder: "smtp, ses, sendgrid, mailgun or postmark"
      },
      %{
        name: "from",
        type: :string,
        required: true,
        summary: true,
        label: "From",
        placeholder: "Support <support@example.com>"
      },
      %{name: "reply_to", type: :string, label: "Reply-To"},
      %{
        name: "subject_template",
        type: :string,
        label: "Subject template",
        placeholder: "New message",
        help:
          "Subject of emails that do not reply to an inbound email. {{conversation_id}} and {{sender}} are replaced."
      },
      %{name: "smtp_host", type: :string, label: "SMTP host", help: "smtp provider only"},
      %{name: "smtp_port", type: :integer, label: "SMTP port", placeholder: "587"},
      %{name: "smtp_username", type: :string, label: "SMTP username"},
      %{name: "password", type: :string, secret: true, label: "SMTP password"},
      %{
        name: "smtp_ssl",
        type: :boolean,
        label: "SMTP implicit TLS",
        help: "true for port 465; otherwise STARTTLS is required"
      },
      %{name: "aws_region", type: :string, label: "AWS region", help: "ses provider only"},
      %{name: "aws_access_key_id", type: :string, label: "AWS access key id"},
      %{
        name: "aws_access_key_secret",
        type: :string,
        secret: true,
        label: "AWS secret access key"
      },
      %{
        name: "api_key",
        type: :string,
        secret: true,
        label: "API key",
        help: "sendgrid, mailgun (private API key) or postmark (server token)"
      },
      %{name: "mailgun_domain", type: :string, label: "Mailgun domain"},
      %{name: "mailgun_region", type: :string, label: "Mailgun region", placeholder: "us or eu"},
      %{
        name: "inbound_provider",
        type: :string,
        label: "Inbound provider",
        placeholder: "ses, sendgrid, mailgun, postmark or rfc822",
        help: "Defaults to the outbound provider (rfc822 for smtp)"
      },
      %{
        name: "inbound_secret",
        type: :string,
        secret: true,
        label: "Inbound basic auth password",
        help: "sendgrid, postmark, rfc822: the password of the webhook URL's basic auth"
      },
      %{
        name: "ses_topic_arn",
        type: :string,
        label: "SES SNS topic ARN",
        help: "ses inbound: only this topic is accepted"
      },
      %{
        name: "mailgun_signing_secret",
        type: :string,
        secret: true,
        label: "Mailgun webhook signing key"
      },
      %{name: "max_attachment_bytes", type: :integer, form: false}
    ]
  end

  @impl true
  def validate_config(config) do
    provider = config["provider"]
    inbound = inbound_provider(config)

    with :ok <- one_of("provider", provider, Outbound.providers()),
         :ok <- one_of("inbound_provider", inbound, Providers.providers()),
         :ok <- check_from(config),
         :ok <- require_fields(config, provider_fields(provider)),
         :ok <- require_fields(config, inbound_fields(inbound)),
         :ok <- check_mailgun_region(config) do
      check_smtp_host(provider, config["smtp_host"])
    end
  end

  defp provider_fields("smtp"), do: ~w(smtp_host)
  defp provider_fields("ses"), do: ~w(aws_region aws_access_key_id aws_access_key_secret)
  defp provider_fields("mailgun"), do: ~w(api_key mailgun_domain)
  defp provider_fields(_), do: ~w(api_key)

  defp inbound_fields("ses"), do: ~w(ses_topic_arn)
  defp inbound_fields("mailgun"), do: ~w(mailgun_signing_secret)
  defp inbound_fields(_), do: []

  defp one_of(name, value, allowed) do
    if value in allowed,
      do: :ok,
      else:
        {:error, "email config '#{name}' must be one of: #{Enum.join(Enum.sort(allowed), ", ")}"}
  end

  defp check_from(config) do
    if Address.parse(config["from"]),
      do: :ok,
      else: {:error, "email config 'from' must be an email address"}
  end

  defp require_fields(config, fields) do
    case Enum.filter(fields, &(config[&1] in [nil, ""])) do
      [] -> :ok
      missing -> {:error, "email config missing: #{Enum.join(missing, ", ")}"}
    end
  end

  defp check_mailgun_region(%{"mailgun_region" => region}) when region not in [nil, ""],
    do: one_of("mailgun_region", region, Outbound.mailgun_regions())

  defp check_mailgun_region(_config), do: :ok

  # The SMTP relay is per-tenant config the server connects to: same SSRF
  # guard as webhook URLs (the host is checked, the port is not).
  defp check_smtp_host("smtp", host) do
    case UrlGuard.check("https://" <> host) do
      :ok -> :ok
      {:error, message} -> {:error, "email config smtp_host is not allowed: #{message}"}
    end
  end

  defp check_smtp_host(_provider, _host), do: :ok

  @doc "The inbound provider of a channel config."
  def inbound_provider(config) do
    case config["inbound_provider"] do
      provider when provider not in [nil, ""] -> provider
      _ -> if config["provider"] == "smtp", do: "rfc822", else: config["provider"]
    end
  end

  ## Outbound

  @impl true
  def deliver_activity(channel, activity) do
    config = channel.config || %{}
    thread = Outbound.thread(activity)

    with {:ok, recipient} <- recipient(channel, activity, thread),
         :ok <- check_target(config) do
      email = Outbound.build(channel, activity, recipient, thread)
      message_id = Outbound.message_id(activity, config)
      {adapter, swoosh_config} = Outbound.swoosh(config)

      case send_email(adapter, email, swoosh_config) do
        {:ok, result} ->
          provider_id =
            case result do
              %{id: id} when is_binary(id) and id != "" -> Address.normalize_id(id)
              _ -> message_id
            end

          {:ok, %{provider_message_id: provider_id, email_message_id: message_id}}

        {:error, reason} ->
          {:error, classify(config["provider"], reason)}
      end
    end
  end

  defp send_email(adapter, email, config) do
    adapter.deliver(email, config)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  end

  defp recipient(channel, activity, thread) do
    metadata = activity.metadata || %{}

    candidate =
      metadata["email_to"] || metadata["to"] ||
        Participants.recipient_for(activity, Map.get(channel, :id)) ||
        (thread && thread["from"])

    case Address.address(candidate) do
      nil ->
        {:error,
         DeliveryError.permanent(
           "no recipient: set activity metadata 'email_to' or 'to', or reply in a conversation with an email participant"
         )}

      address ->
        {:ok, address}
    end
  end

  defp check_target(%{"provider" => "smtp", "smtp_host" => host}) do
    case UrlGuard.resolve("https://" <> (host || "")) do
      {:ok, _target} ->
        :ok

      {:error, {:unresolvable, _} = reason} ->
        {:error, %DeliveryError{reason: "SMTP host rejected: " <> UrlGuard.format_error(reason)}}

      {:error, reason} ->
        {:error, DeliveryError.permanent("SMTP host rejected: " <> UrlGuard.format_error(reason))}
    end
  end

  defp check_target(_config), do: :ok

  # Swoosh API adapters return {status, body}; SES an error code; SMTP a
  # gen_smtp failure.
  defp classify(_provider, {status, body}) when is_integer(status),
    do: DeliveryError.from_http(status, [], body, "Email provider")

  defp classify("ses", %{code: code, message: message}) do
    error = %DeliveryError{reason: "Amazon SES error #{code}: #{message}"}

    if code in ["Throttling", "ServiceUnavailable", "InternalFailure", "RequestExpired"],
      do: error,
      else: %{error | retryable?: false}
  end

  defp classify(_provider, {:send, {:permanent_failure, _host, message}}),
    do: DeliveryError.permanent("SMTP permanent failure: #{inspect(message)}")

  defp classify(_provider, {:permanent_failure, _host, message}),
    do: DeliveryError.permanent("SMTP permanent failure: #{inspect(message)}")

  defp classify(_provider, reason), do: DeliveryError.from_transport(reason, "Email provider")

  ## Inbound

  @impl true
  def verify_inbound_signature(channel, headers, raw_body) do
    config = channel.config || %{}

    case inbound_provider(config) do
      "ses" ->
        with {:ok, message} <- SNS.decode(raw_body),
             do: SNS.verify(message, config["ses_topic_arn"])

      # Mailgun signs fields of the payload (timestamp, token): checked by
      # parse_inbound/2 and parse_status_update/2, which see the params.
      "mailgun" ->
        :ok

      _ ->
        case basic_auth_password(headers) do
          nil -> InboundSignature.verify(channel, headers, raw_body)
          password -> check_password(config["inbound_secret"], password)
        end
    end
  end

  defp basic_auth_password(headers) do
    with {_, "Basic " <> encoded} <- List.keyfind(headers, "authorization", 0),
         {:ok, decoded} <- Base.decode64(String.trim(encoded)),
         [_user, password] <- String.split(decoded, ":", parts: 2) do
      password
    else
      _ -> nil
    end
  end

  defp check_password(secret, password) when is_binary(secret) and secret != "" do
    if Plug.Crypto.secure_compare(secret, password), do: :ok, else: {:error, :invalid_credentials}
  end

  defp check_password(_secret, _password), do: {:error, :inbound_secret_not_configured}

  @impl true
  def parse_inbound(channel, params) do
    config = channel.config || %{}
    provider = inbound_provider(config)

    with :ok <- authorize_payload(provider, config, params),
         :ok <- maybe_confirm_subscription(provider, params),
         {:ok, emails} <- Providers.emails(provider, params) do
      {:ok,
       emails
       |> Enum.filter(&accept?(channel, &1))
       |> Enum.map(&to_message(channel, provider, &1))}
    end
  end

  @impl true
  def parse_status_update(channel, params) do
    config = channel.config || %{}
    provider = inbound_provider(config)

    with :ok <- authorize_payload(provider, config, params) do
      case Providers.events(provider, params) do
        [] -> :ignore
        updates -> {:ok, updates}
      end
    end
  end

  defp authorize_payload("mailgun", config, params) do
    signature =
      case params["signature"] do
        %{} = signature -> signature
        _ -> params
      end

    with secret when is_binary(secret) and secret != "" <- config["mailgun_signing_secret"],
         timestamp when is_binary(timestamp) <- to_string_or_nil(signature["timestamp"]),
         token when is_binary(token) <- signature["token"],
         given when is_binary(given) <- signature["signature"],
         expected =
           :crypto.mac(:hmac, :sha256, secret, timestamp <> token) |> Base.encode16(case: :lower),
         true <- Plug.Crypto.secure_compare(expected, String.downcase(given)) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp authorize_payload(_provider, _config, _params), do: :ok

  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp to_string_or_nil(_), do: nil

  # The SNS signature was checked by verify_inbound_signature/3.
  defp maybe_confirm_subscription("ses", params) do
    case SNS.envelope(params) do
      {:ok, %{"Type" => "SubscriptionConfirmation"} = message} ->
        case SNS.confirm_subscription(message) do
          :ok ->
            Logger.info("Confirmed SNS subscription for #{message["TopicArn"]}")
            :ok

          {:error, reason} ->
            Logger.warning("SNS subscription confirmation failed", reason: inspect(reason))
            {:error, :subscription_confirmation_failed}
        end

      _ ->
        :ok
    end
  end

  defp maybe_confirm_subscription(_provider, _params), do: :ok

  defp accept?(channel, email) do
    own = Address.address((channel.config || %{})["from"])

    cond do
      is_nil(email.from) ->
        Logger.warning("Skipped inbound email without a From address", channel_id: channel.id)
        false

      # A copy of our own mail (a forwarding loop, a Cc to ourselves).
      email.from == own ->
        Logger.info("Skipped inbound email sent by the channel itself", channel_id: channel.id)
        false

      true ->
        true
    end
  end

  defp to_message(channel, provider, email) do
    full_text = email.text || html_to_text(email.html) || ""
    text = truncate(email.stripped_text || ReplyParser.strip(full_text), @max_text_bytes)
    message_id = email.message_id
    refs = Enum.uniq(email.in_reply_to ++ Enum.reverse(email.references))

    # A re-delivered webhook is a duplicate: do not store its files again.
    duplicate? = Activities.get_activity_by_channel_idempotency_key(channel.id, message_id) != nil

    {attachments, skipped} =
      if duplicate?, do: {[], []}, else: store_attachments(channel, email.attachments)

    email_metadata =
      reject_empty(%{
        "message_id" => message_id,
        "subject" => email.subject && truncate(email.subject, @max_subject_bytes),
        "from" => email.from,
        "from_name" => email.from_name,
        "to" => Enum.take(email.to, @max_refs),
        "cc" => Enum.take(email.cc, @max_refs),
        "in_reply_to" => List.first(email.in_reply_to),
        "references" => Enum.take(email.references, -@max_refs),
        "provider" => provider,
        "auto_submitted" => email.auto_submitted || nil,
        "skipped_attachments" => skipped
      })

    metadata =
      if String.trim(full_text) != text do
        Map.put(email_metadata_wrapper(email_metadata), "channelData", %{
          "provider" => provider,
          "fullText" => truncate(full_text, @max_full_text_bytes),
          "fullTextTruncated" => byte_size(full_text) > @max_full_text_bytes
        })
      else
        email_metadata_wrapper(email_metadata)
      end

    %{
      "sender" => email.from,
      "type" => "message",
      "text" => text,
      "attachments" => attachments,
      "metadata" => metadata,
      "idempotency_key" => message_id,
      "reply_to_provider_id" => List.first(email.in_reply_to),
      "thread_refs" =>
        refs |> Enum.flat_map(&ref_candidates/1) |> Enum.uniq() |> Enum.take(@max_refs),
      "thread_activity_ids" =>
        refs
        |> Enum.map(&Outbound.activity_id_from_message_id/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq(),
      "participant" => %{"external_id" => email.from, "display_name" => email.from_name}
    }
  end

  defp email_metadata_wrapper(email_metadata), do: %{"email" => email_metadata}

  # Providers that rewrite Message-ID (SES: <ses-id@email.amazonses.com>)
  # keep their own id in the local part.
  defp ref_candidates(ref) do
    case String.split(ref, "@", parts: 2) do
      [local, _domain] when local != "" -> [ref, local]
      _ -> [ref]
    end
  end

  defp store_attachments(channel, files) do
    {stored, skipped} =
      files
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {{name, file}, index}, {stored, skipped} ->
        name = name || "attachment"

        if index >= @max_attachments do
          {stored, [name | skipped]}
        else
          case Uploads.create_attachment(channel.tenant_id, file_source(name, file)) do
            {:ok, attachment} ->
              {[
                 %{
                   "contentType" => attachment.content_type,
                   "contentUrl" => "/api/v1/converger/attachments/#{attachment.id}",
                   "name" => attachment.filename || name,
                   "size" => attachment.size
                 }
                 | stored
               ], skipped}

            {:error, reason} ->
              Logger.info("Skipped inbound email attachment",
                channel_id: channel.id,
                reason: inspect(reason)
              )

              {stored, [name | skipped]}
          end
        end
      end)

    {Enum.reverse(stored), Enum.reverse(skipped)}
  end

  defp file_source(_name, %Plug.Upload{} = upload), do: upload
  defp file_source(name, data) when is_binary(data), do: {name, data}

  @doc false
  def html_to_text(nil), do: nil

  def html_to_text(html) do
    html
    |> String.replace(~r/<(script|style|head)[^>]*>.*?<\/\1>/is, "")
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/(p|div|tr|li|h[1-6]|blockquote)>/i, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/&nbsp;/i, " ")
    |> String.replace(~r/&lt;/i, "<")
    |> String.replace(~r/&gt;/i, ">")
    |> String.replace(~r/&quot;/i, "\"")
    |> String.replace(~r/&#39;|&apos;/i, "'")
    |> String.replace(~r/&amp;/i, "&")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # Cut at a character boundary, at most `max` bytes.
  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    text
    |> binary_part(0, max)
    |> String.chunk(:valid)
    |> Enum.take_while(&String.valid?/1)
    |> Enum.join()
  end

  defp reject_empty(map),
    do: map |> Enum.reject(fn {_k, v} -> v in [nil, [], ""] end) |> Map.new()
end
