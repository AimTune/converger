defmodule Converger.Channels.Sms do
  @moduledoc """
  What the SMS adapters (`Converger.Channels.Adapters.SmsTwilio`,
  `Converger.Channels.Adapters.SmsVonage`) share: E.164 phone numbers, message
  segmentation and the opt-out keywords.

  ## Segments

  A single SMS carries 160 GSM-7 characters or 70 UCS-2 ones. Longer texts
  are concatenated: each part loses a 6-byte header, so 153 GSM-7 or 67 UCS-2
  characters fit per segment. A text with any character outside the GSM-7
  alphabet (an emoji, a Turkish `ı`) is sent as UCS-2 entirely. Characters of
  the GSM-7 extension table (`€`, `{`, `[`...) take two septets. Every
  segment is billed, and carriers drop very long concatenations, so the
  adapters refuse a text longer than the channel's `max_segments` (default
  10) instead of sending it.

  ## Opt-out

  Carriers require honouring `STOP`: a participant who sends an opt-out
  keyword is marked opted out (`Converger.Participants.set_opted_out/3`) and
  the pipeline fails every later delivery to them fast; an opt-in keyword
  clears the flag. The keywords are the CTIA / Twilio defaults, matched on
  the whole trimmed message, case-insensitive.
  """

  alias Converger.Channels.DeliveryError

  @default_max_segments 10

  @opt_out_keywords ~w(STOP STOPALL UNSUBSCRIBE CANCEL END QUIT OPTOUT REVOKE)
  @opt_in_keywords ~w(START YES UNSTOP OPTIN)

  # GSM 03.38 basic character set, and the extension table (two septets each).
  @gsm7_basic ~c"@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
              |> MapSet.new()
  @gsm7_extended ~c"^{}\\[~]|€\f" |> MapSet.new()

  @doc "Default limit of segments per message (channel config `max_segments`)."
  def default_max_segments, do: @default_max_segments

  @doc """
  Normalise a phone number to E.164 (`+` and 8 to 15 digits).

  Spaces, dashes, dots and parentheses are dropped and a `00` international
  prefix becomes `+`. A national number (leading `0`) needs
  `default_country_code` (e.g. `"90"` or `"+90"`); other numbers without `+`
  are taken as international. Returns `{:ok, e164}` or `:error`.
  """
  def normalize_e164(number, default_country_code \\ nil)

  def normalize_e164(number, default_country_code) when is_binary(number) do
    digits = String.replace(String.trim(number), ~r/[\s\-.()\/]/u, "")

    candidate =
      case digits do
        "+" <> rest -> "+" <> rest
        "00" <> rest -> "+" <> rest
        "0" <> rest -> national(rest, default_country_code)
        rest -> "+" <> rest
      end

    if is_binary(candidate) and Regex.match?(~r/\A\+[1-9]\d{7,14}\z/, candidate),
      do: {:ok, candidate},
      else: :error
  end

  def normalize_e164(_number, _default_country_code), do: :error

  defp national(rest, code) when is_binary(code) and code != "" do
    case String.trim_leading(code, "+") do
      "" -> nil
      code -> "+" <> code <> rest
    end
  end

  defp national(_rest, _code), do: nil

  @doc """
  A participant id for an inbound sender: its E.164 form when it is a phone
  number, the trimmed sender otherwise (short codes and alphanumeric sender
  ids are kept as they are).
  """
  def participant_id(sender, default_country_code \\ nil)

  def participant_id(sender, default_country_code) when is_binary(sender) do
    case normalize_e164(sender, default_country_code) do
      {:ok, e164} -> e164
      :error -> String.trim(sender)
    end
  end

  def participant_id(_sender, _default_country_code), do: nil

  @doc """
  The encoding (`:gsm7` or `:ucs2`) and number of segments of `text`.

      iex> Converger.Channels.Sms.segments("hello")
      {:gsm7, 1}
      iex> Converger.Channels.Sms.segments(String.duplicate("a", 161))
      {:gsm7, 2}
      iex> Converger.Channels.Sms.segments("merhaba ı")
      {:ucs2, 1}
  """
  def segments(text) when is_binary(text) do
    chars = String.to_charlist(text)

    case gsm7_length(chars) do
      {:ok, septets} ->
        {:gsm7, count(septets, 160, 153)}

      :error ->
        # UCS-2 counts UTF-16 code units: characters outside the BMP (most
        # emoji) take two.
        units = div(byte_size(:unicode.characters_to_binary(text, :utf8, :utf16)), 2)
        {:ucs2, count(units, 70, 67)}
    end
  end

  def segments(_text), do: {:gsm7, 0}

  defp gsm7_length(chars) do
    Enum.reduce_while(chars, {:ok, 0}, fn char, {:ok, acc} ->
      cond do
        MapSet.member?(@gsm7_basic, char) -> {:cont, {:ok, acc + 1}}
        MapSet.member?(@gsm7_extended, char) -> {:cont, {:ok, acc + 2}}
        true -> {:halt, :error}
      end
    end)
  end

  defp count(0, _single, _multi), do: 0
  defp count(length, single, _multi) when length <= single, do: 1
  defp count(length, _single, multi), do: div(length + multi - 1, multi)

  @doc """
  The channel's limit of segments per message: config `max_segments`, else
  #{@default_max_segments}.
  """
  def max_segments(channel) do
    case (Map.get(channel, :config) || %{})["max_segments"] do
      n when is_integer(n) and n > 0 ->
        n

      n when is_binary(n) ->
        case Integer.parse(String.trim(n)) do
          {n, ""} when n > 0 -> n
          _ -> @default_max_segments
        end

      _ ->
        @default_max_segments
    end
  end

  @doc """
  `{:ok, segment_count}` when `text` fits the channel's `max_segments`,
  `{:error, message}` otherwise.
  """
  def check_length(channel, text) do
    {encoding, count} = segments(text || "")
    max = max_segments(channel)

    if count <= max,
      do: {:ok, count},
      else:
        {:error,
         "text is #{count} #{encoding} segments, the channel allows #{max} (config max_segments)"}
  end

  @doc """
  Classify an inbound text: `:opt_out` (`STOP`...), `:opt_in` (`START`...)
  or `nil`.
  """
  def opt_keyword(text) when is_binary(text) do
    keyword = text |> String.trim() |> String.upcase()

    cond do
      keyword in @opt_out_keywords -> :opt_out
      keyword in @opt_in_keywords -> :opt_in
      true -> nil
    end
  end

  def opt_keyword(_text), do: nil

  @doc "The opt-out keywords."
  def opt_out_keywords, do: @opt_out_keywords

  @doc "The opt-in keywords."
  def opt_in_keywords, do: @opt_in_keywords

  @doc """
  Turn a parsed inbound SMS into an opt-out / opt-in `event` when its text is
  a keyword (`kind`, or the keyword of `message["text"]` when `kind` is nil):
  the message gets type `event`, `"opt_out"` (`"stop"` or `"start"`, applied
  to the participant by `Converger.Inbound`) and `channelData.smsOptOut`.
  Other messages are returned unchanged.
  """
  def apply_opt_keyword(message, kind \\ nil) do
    case kind || opt_keyword(message["text"]) do
      nil ->
        message

      kind ->
        value = if kind == :opt_out, do: "stop", else: "start"

        message
        |> Map.put("type", "event")
        |> Map.put("opt_out", value)
        |> Map.update("metadata", %{"smsOptOut" => value}, &Map.put(&1, "smsOptOut", value))
    end
  end

  @doc """
  The recipient of an outbound activity in E.164: activity metadata
  `"to"` / `"recipient_phone"`, else the conversation participant on the
  channel.
  """
  def recipient(channel, activity) do
    raw =
      activity.metadata["to"] || activity.metadata["recipient_phone"] ||
        Converger.Participants.recipient_for(activity, Map.get(channel, :id))

    config = Map.get(channel, :config) || %{}

    if is_nil(raw) do
      {:error,
       DeliveryError.permanent(
         "no recipient: set activity metadata 'to', or reply in a conversation with a participant on this channel"
       )}
    else
      case normalize_e164(raw, config["default_country_code"]) do
        {:ok, e164} ->
          {:ok, e164}

        :error ->
          {:error,
           DeliveryError.permanent("recipient #{inspect(raw)} is not an E.164 phone number")}
      end
    end
  end

  @doc false
  def reject_nil_values(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
