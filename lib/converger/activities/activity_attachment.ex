defmodule Converger.Activities.ActivityAttachment do
  @moduledoc """
  The attachment descriptor of an activity, validated on write.

  Wire shape (camelCase keys, as stored in `activities.attachments` and
  returned by every API):

      %{
        "contentType" => "image/png",          # required, a MIME type
        "contentUrl" => "https://...",         # optional, http(s) or a server path
        "name" => "screenshot.png",            # optional
        "size" => 48213,                       # optional, bytes
        "thumbnailUrl" => "https://...",       # optional
        "content" => %{...},                   # optional, inline JSON (cards, location)
        "channelData" => %{...}                # optional, provider passthrough
      }

  Well-known Converger content types carry their payload in `content`:
  `application/vnd.converger.card.*` (must be an object),
  `application/vnd.converger.location` and `application/vnd.converger.contacts`.
  Provider-specific fields (a WhatsApp media id, a checksum) go in
  `channelData`; other unknown keys are dropped.

  This is an embedded schema used for validation and normalisation only: the
  `activities.attachments` column stays a list of maps, so attachments stored
  before this schema existed (possibly without `contentType`) still load
  unchanged. Validation applies to new writes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @card_prefix "application/vnd.converger.card."

  @well_known_content_types [
    "application/vnd.converger.location",
    "application/vnd.converger.contacts"
  ]

  # wire key => schema field
  @wire_fields %{
    "contentType" => :content_type,
    "contentUrl" => :content_url,
    "name" => :name,
    "size" => :size,
    "thumbnailUrl" => :thumbnail_url,
    "channelData" => :channel_data
  }

  @content_type_format ~r{\A[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/([A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*|\*)\z}

  @primary_key false
  embedded_schema do
    field :content_type, :string
    field :content_url, :string
    field :name, :string
    field :size, :integer
    field :thumbnail_url, :string
    field :channel_data, :map
    # Any JSON value (object or list); validated by hand, see changeset/2.
    field :content, :any, virtual: true
  end

  @doc "Prefix of the well-known card content types."
  def card_prefix, do: @card_prefix

  @doc "Well-known Converger content types other than cards."
  def well_known_content_types, do: @well_known_content_types

  @doc """
  Validates one attachment map (string or atom keys, camelCase as on the
  wire). Returns a changeset over this embedded schema.
  """
  def changeset(attrs) when is_map(attrs) do
    params =
      Enum.reduce(attrs, %{}, fn {key, value}, acc ->
        case Map.fetch(@wire_fields, to_string(key)) do
          {:ok, field} -> Map.put(acc, field, value)
          :error -> acc
        end
      end)

    content = Map.get(attrs, "content", Map.get(attrs, :content))

    %__MODULE__{}
    |> cast(params, Map.values(@wire_fields))
    |> validate_required([:content_type])
    |> validate_length(:content_type, max: 255)
    |> validate_format(:content_type, @content_type_format, message: "must be a MIME type")
    |> validate_length(:name, max: 1024)
    |> validate_number(:size, greater_than_or_equal_to: 0)
    |> validate_url(:content_url)
    |> validate_url(:thumbnail_url)
    |> put_content(content)
  end

  def changeset(_attrs) do
    %__MODULE__{}
    |> change()
    |> add_error(:attachment, "must be an object")
  end

  @doc """
  Validates and normalises an attachment. Returns `{:ok, wire_map}` (camelCase
  string keys, nil values dropped) or `{:error, changeset}`.
  """
  def normalize(attrs) do
    changeset = changeset(attrs)

    case apply_action(changeset, :validate) do
      {:ok, attachment} -> {:ok, to_wire(attachment)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "The wire map of a validated attachment."
  def to_wire(%__MODULE__{} = attachment) do
    @wire_fields
    |> Enum.map(fn {key, field} -> {key, Map.fetch!(attachment, field)} end)
    |> Enum.concat([{"content", attachment.content}])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp put_content(changeset, nil), do: maybe_require_card_content(changeset, nil)

  defp put_content(changeset, content) when is_map(content) or is_list(content) do
    changeset
    |> put_change(:content, content)
    |> maybe_require_card_content(content)
  end

  defp put_content(changeset, _content),
    do: add_error(changeset, :content, "must be an object or a list")

  defp maybe_require_card_content(changeset, content) do
    content_type = get_field(changeset, :content_type)

    if is_binary(content_type) and String.starts_with?(content_type, @card_prefix) and
         not is_map(content) do
      add_error(changeset, :content, "is required (an object) for card attachments")
    else
      changeset
    end
  end

  # Absolute http(s) URLs or server-relative paths (an uploaded attachment's
  # `/api/v1/converger/attachments/:id`). Anything else (javascript:, data:)
  # is rejected so renderers can use the URL as is.
  defp validate_url(changeset, field) do
    changeset
    |> validate_length(field, max: 2048)
    |> validate_change(field, fn ^field, url ->
      if valid_url?(url), do: [], else: [{field, "must be an http(s) URL or an absolute path"}]
    end)
  end

  defp valid_url?("/" <> rest), do: not String.starts_with?(rest, "/")

  defp valid_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _ ->
        false
    end
  end
end
