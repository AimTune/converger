defmodule ConvergerWeb.MessageComponents do
  @moduledoc """
  Server-side rendering of the rich message vocabulary (#68,
  `docs/protocol/messages.md`) in the admin (`/admin/conversations/:id`) and
  portal (`/portal/conversations/:id`) transcripts.

  A `message` activity with a `message_type` and a `payload` is shown natively
  with daisyUI: actions as (non-interactive) chips, cards, carousels, media,
  locations, contacts, and the mekik-native frames (`tool_call`, `genui`,
  `interrupt`, `interrupt_resolved`, `skill`). A plain message renders its
  `text` as before; an unknown renderer-named type shows its `data.text`, or
  its payload as JSON.

  Payloads are client input. Everything is rendered through HEEx escaping
  (never `raw/1`); only values that are strings or numbers are interpolated;
  links are only rendered for `http(s)` URLs and same-origin `/api/` paths
  (`safe_url/1`); JSON previews are truncated (`json_preview/1`). Media are
  never loaded inline: the admin CSP (`img-src 'self'`) blocks third-party
  content, which also keeps tracking pixels out, and attachment URLs need an
  API token, so media show as a link with their metadata.
  """
  use Phoenix.Component

  import ConvergerWeb.CoreComponents, only: [icon: 1]

  @max_json_chars 2_000
  @link_rel "noopener noreferrer nofollow"

  # ---------------------------------------------------------------------------
  # Interrupt bookkeeping (open / resolved)
  # ---------------------------------------------------------------------------

  @doc """
  A fresh interrupt state: the ids of resolved interrupts seen in the
  transcript and the loaded `interrupt` rows by id (to re-render one when it
  is resolved live).
  """
  def interrupt_state, do: %{resolved: MapSet.new(), rows: %{}}

  @doc "Adds the interrupts and resolutions among `activities` to `state`."
  def track_interrupts(state, activities) do
    Enum.reduce(activities, state, fn activity, acc ->
      case interrupt_ref(activity) do
        {"interrupt", id} -> %{acc | rows: Map.put(acc.rows, id, activity)}
        {"interrupt_resolved", id} -> %{acc | resolved: MapSet.put(acc.resolved, id)}
        nil -> acc
      end
    end)
  end

  @doc """
  The loaded `interrupt` row that `activity` resolves, if any: the transcript
  re-inserts it so it shows as resolved.
  """
  def resolved_interrupt_row(state, activity) do
    case interrupt_ref(activity) do
      {"interrupt_resolved", id} -> Map.get(state.rows, id)
      _ -> nil
    end
  end

  defp interrupt_ref(%{message_type: type, payload: %{} = payload})
       when type in ["interrupt", "interrupt_resolved"] do
    case payload["id"] || payload[:id] do
      id when is_binary(id) -> {type, id}
      _ -> nil
    end
  end

  defp interrupt_ref(_activity), do: nil

  # ---------------------------------------------------------------------------
  # Entry point
  # ---------------------------------------------------------------------------

  @doc """
  The body of one transcript activity: its plain `text`, or the native
  rendering of its typed message.
  """
  attr :activity, :any, required: true
  attr :resolved_interrupts, :any, default: nil, doc: "MapSet of resolved interrupt ids"

  def message_body(%{activity: %{message_type: type, payload: %{} = payload}} = assigns)
      when is_binary(type) do
    payload = normalize(payload)

    assigns =
      assign(assigns,
        type: type,
        payload: payload,
        data: map_or_empty(payload["data"]),
        resolved_interrupts: assigns.resolved_interrupts || MapSet.new()
      )

    ~H"""
    <div class="space-y-1.5" data-message-type={@type}>
      <span class="badge badge-ghost badge-xs font-mono">{@type}</span>
      <.typed
        type={@type}
        payload={@payload}
        data={@data}
        text={@activity.text}
        resolved_interrupts={@resolved_interrupts}
      />
    </div>
    """
  end

  def message_body(assigns) do
    ~H"""
    {@activity.text}
    """
  end

  # ---------------------------------------------------------------------------
  # Per type
  # ---------------------------------------------------------------------------

  attr :type, :string, required: true
  attr :payload, :map, required: true
  attr :data, :map, required: true
  attr :text, :any, default: nil
  attr :resolved_interrupts, :any, required: true

  defp typed(%{type: "text"} = assigns) do
    ~H"""
    <p class="whitespace-pre-wrap">{str(@data["text"]) || str(@text)}</p>
    <.chips actions={@payload["actions"] || @data["actions"]} />
    """
  end

  defp typed(%{type: "quick-reply"} = assigns) do
    ~H"""
    <p :if={str(@data["text"])} class="whitespace-pre-wrap">{str(@data["text"])}</p>
    <.chips actions={@data["actions"] || @payload["actions"]} />
    """
  end

  defp typed(%{type: "buttons"} = assigns) do
    ~H"""
    <p :if={str(@data["text"])} class="whitespace-pre-wrap">{str(@data["text"])}</p>
    <.chips actions={@data["buttons"]} class="flex-col items-start" />
    """
  end

  defp typed(%{type: "card"} = assigns) do
    ~H"""
    <.card card={@data} />
    """
  end

  defp typed(%{type: "carousel"} = assigns) do
    assigns = assign(assigns, cards: maps(assigns.data["cards"]))

    ~H"""
    <p :if={str(@data["text"])} class="whitespace-pre-wrap">{str(@data["text"])}</p>
    <div class="flex gap-2 overflow-x-auto pb-2">
      <.card :for={card <- @cards} card={card} />
    </div>
    """
  end

  defp typed(%{type: type} = assigns) when type in ~w(image video audio file) do
    ~H"""
    <.media type={@type} data={@data} />
    """
  end

  defp typed(%{type: "location"} = assigns) do
    assigns = assign(assigns, map_url: osm_url(assigns.data), url: safe_url(assigns.data["url"]))

    ~H"""
    <div class="flex items-start gap-2 rounded-box border border-base-300 p-2 max-w-md">
      <.icon name="hero-map-pin" class="size-5 shrink-0 opacity-70" />
      <div class="min-w-0 space-y-0.5">
        <p :if={str(@data["name"])} class="font-semibold">{str(@data["name"])}</p>
        <p :if={str(@data["address"])} class="text-sm">{str(@data["address"])}</p>
        <p :if={@map_url} class="text-xs opacity-70 font-mono">
          {str(@data["latitude"])}, {str(@data["longitude"])}
        </p>
        <a :if={@map_url} href={@map_url} target="_blank" rel={link_rel()} class="link text-sm">
          Open in OpenStreetMap
        </a>
        <a :if={@url} href={@url} target="_blank" rel={link_rel()} class="link text-sm break-all">
          {@url}
        </a>
      </div>
    </div>
    """
  end

  defp typed(%{type: "contact"} = assigns) do
    assigns =
      assign(assigns,
        phones: maps(assigns.data["phones"]),
        emails: maps(assigns.data["emails"]),
        url: safe_url(assigns.data["url"])
      )

    ~H"""
    <div class="flex items-start gap-2 rounded-box border border-base-300 p-2 max-w-md">
      <.icon name="hero-user-circle" class="size-5 shrink-0 opacity-70" />
      <div class="min-w-0 space-y-0.5">
        <p class="font-semibold">{str(@data["name"])}</p>
        <p :if={str(@data["organization"])} class="text-sm">{str(@data["organization"])}</p>
        <p :for={phone <- @phones} class="text-sm">
          <span :if={str(phone["label"])} class="opacity-70">{str(phone["label"])}:</span>
          {str(phone["number"])}
        </p>
        <p :for={email <- @emails} class="text-sm break-all">
          <span :if={str(email["label"])} class="opacity-70">{str(email["label"])}:</span>
          {str(email["address"])}
        </p>
        <a :if={@url} href={@url} target="_blank" rel={link_rel()} class="link text-sm break-all">
          {@url}
        </a>
      </div>
    </div>
    """
  end

  defp typed(%{type: "tool_call"} = assigns) do
    ~H"""
    <details class="rounded-box border border-base-300 p-2 max-w-2xl">
      <summary class="cursor-pointer flex flex-wrap items-center gap-2">
        <.icon name="hero-wrench-screwdriver" class="size-4 opacity-70" />
        <span class="font-mono font-semibold">{str(@data["name"]) || "tool"}</span>
        <span class={["badge badge-sm", tool_status_class(@data["status"])]}>
          {str(@data["status"]) || "unknown"}
        </span>
      </summary>
      <div class="mt-2 space-y-2 text-sm">
        <p :if={str(@data["description"])}>{str(@data["description"])}</p>
        <.json_block :if={Map.has_key?(@data, "params")} label="Params" value={@data["params"]} />
        <.json_block :if={Map.has_key?(@data, "result")} label="Result" value={@data["result"]} />
        <p :if={str(@data["error"])} class="text-error whitespace-pre-wrap">
          {str(@data["error"])}
        </p>
      </div>
    </details>
    """
  end

  defp typed(%{type: "genui"} = assigns) do
    assigns = assign(assigns, chunk: map_or_empty(assigns.payload["chunk"]))

    ~H"""
    <div class="flex flex-wrap items-center gap-2 text-xs opacity-70">
      <span>stream <span class="font-mono">{str(@payload["streamId"])}</span></span>
      <span :if={@payload["done"] == true} class="badge badge-xs badge-success">done</span>
    </div>
    <.genui_chunk chunk={@chunk} />
    """
  end

  defp typed(%{type: "interrupt"} = assigns) do
    resolved? = MapSet.member?(assigns.resolved_interrupts, assigns.payload["id"])
    payload = assigns.data["payload"]

    assigns =
      assign(assigns,
        resolved?: resolved?,
        prompt:
          title_of(payload) || str(assigns.data["text"]) || str(assigns.text) || "Interrupt",
        interrupt_payload: payload
      )

    ~H"""
    <div class="rounded-box border border-warning/50 p-2 max-w-2xl space-y-1.5">
      <div class="flex flex-wrap items-center gap-2">
        <.icon name="hero-hand-raised" class="size-4 opacity-70" />
        <span class="font-semibold whitespace-pre-wrap">{@prompt}</span>
        <span
          class={["badge badge-sm", if(@resolved?, do: "badge-success", else: "badge-warning")]}
          data-interrupt-state={if @resolved?, do: "resolved", else: "open"}
        >
          {if @resolved?, do: "resolved", else: "open"}
        </span>
        <span :if={is_map(@data["ui"])} class="badge badge-ghost badge-xs">form</span>
        <span :if={@data["tool"]} class="badge badge-ghost badge-xs">tool</span>
        <span :if={@data["event"]} class="badge badge-ghost badge-xs">event</span>
      </div>
      <.chips actions={@data["actions"]} />
      <.json_block :if={is_map(@interrupt_payload)} label="Payload" value={@interrupt_payload} />
      <p class="text-xs opacity-60 font-mono break-all">{str(@payload["id"])}</p>
    </div>
    """
  end

  defp typed(%{type: "interrupt_resolved"} = assigns) do
    ~H"""
    <p class="text-sm opacity-80 flex flex-wrap items-center gap-1">
      <.icon name="hero-check-circle" class="size-4 text-success" />
      Interrupt <span class="font-mono break-all">{str(@payload["id"])}</span> resolved
    </p>
    <.json_block :if={Map.has_key?(@data, "answer")} label="Answer" value={@data["answer"]} />
    """
  end

  defp typed(%{type: "skill"} = assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <span class="badge badge-sm badge-accent">
        <.icon name="hero-puzzle-piece" class="size-3" /> skill: {str(@data["name"])}
      </span>
      <span class={["badge badge-sm", skill_status_class(@data["status"])]}>
        {str(@data["status"])}
      </span>
      <span :if={str(@data["source"])} class="text-xs opacity-70">{str(@data["source"])}</span>
    </div>
    <p :if={str(@data["error"])} class="text-error text-sm">{str(@data["error"])}</p>
    """
  end

  # Open renderer-named types (rule 5): `data.text` is the fallback.
  defp typed(assigns) do
    assigns = assign(assigns, fallback: str(assigns.data["text"]) || str(assigns.text))

    ~H"""
    <p :if={@fallback} class="whitespace-pre-wrap">{@fallback}</p>
    <.json_block :if={!@fallback} label="Payload" value={@payload} />
    """
  end

  # ---------------------------------------------------------------------------
  # Building blocks
  # ---------------------------------------------------------------------------

  attr :actions, :any, required: true
  attr :class, :any, default: nil

  defp chips(assigns) do
    assigns =
      assign(assigns,
        items:
          Enum.flat_map(maps(assigns.actions), fn action ->
            case str(action["label"]) do
              nil -> []
              label -> [%{label: label, url: safe_url(action["url"])}]
            end
          end)
      )

    ~H"""
    <div :if={@items != []} class={["flex flex-wrap gap-1", @class]}>
      <%= for item <- @items do %>
        <a
          :if={item.url}
          href={item.url}
          target="_blank"
          rel={link_rel()}
          class="badge badge-outline badge-primary gap-1"
        >
          {item.label} <.icon name="hero-arrow-top-right-on-square" class="size-3" />
        </a>
        <span :if={!item.url} class="badge badge-outline">{item.label}</span>
      <% end %>
    </div>
    """
  end

  attr :card, :map, required: true

  defp card(assigns) do
    assigns = assign(assigns, image: safe_url(assigns.card["image"]))

    ~H"""
    <div class="card card-border bg-base-100 w-64 shrink-0">
      <div class="card-body p-3 gap-1">
        <a
          :if={@image}
          href={@image}
          target="_blank"
          rel={link_rel()}
          class="link text-xs inline-flex items-center gap-1"
        >
          <.icon name="hero-photo" class="size-4" /> Image
        </a>
        <h3 :if={str(@card["title"])} class="card-title text-sm">{str(@card["title"])}</h3>
        <p :if={str(@card["subtitle"])} class="text-xs opacity-70">{str(@card["subtitle"])}</p>
        <p :if={str(@card["text"])} class="text-sm whitespace-pre-wrap">{str(@card["text"])}</p>
        <.chips actions={@card["buttons"]} />
      </div>
    </div>
    """
  end

  attr :type, :string, required: true
  attr :data, :map, required: true

  defp media(assigns) do
    data = assigns.data
    raw_url = if assigns.type == "file", do: data["url"], else: data["src"]

    assigns =
      assign(assigns,
        url: safe_url(raw_url),
        refused?: raw_url != nil and safe_url(raw_url) == nil,
        label: media_label(assigns.type, data),
        poster: safe_url(data["poster"]),
        details: media_details(data)
      )

    ~H"""
    <div class="flex items-start gap-2 rounded-box border border-base-300 p-2 max-w-md">
      <.icon name={media_icon(@type)} class="size-5 shrink-0 opacity-70" />
      <div class="min-w-0 space-y-0.5">
        <a :if={@url} href={@url} target="_blank" rel={link_rel()} class="link break-all">
          {@label}
        </a>
        <span :if={!@url} class="break-all">{@label}</span>
        <span :if={@refused?} class="badge badge-warning badge-xs" data-refused-url>
          unsafe URL not shown
        </span>
        <p :if={@details != ""} class="text-xs opacity-70">{@details}</p>
        <p :if={str(@data["caption"])} class="text-sm whitespace-pre-wrap">
          {str(@data["caption"])}
        </p>
        <a :if={@poster} href={@poster} target="_blank" rel={link_rel()} class="link text-xs">
          Poster image
        </a>
      </div>
    </div>
    """
  end

  attr :chunk, :map, required: true

  defp genui_chunk(%{chunk: %{"type" => "ui"}} = assigns) do
    ~H"""
    <p class="text-sm">
      Component <span class="font-mono font-semibold">{str(@chunk["component"])}</span>
    </p>
    <.json_block :if={Map.has_key?(@chunk, "props")} label="Props" value={@chunk["props"]} />
    """
  end

  defp genui_chunk(%{chunk: %{"type" => "text"}} = assigns) do
    ~H"""
    <p class="whitespace-pre-wrap">{str(@chunk["content"])}</p>
    """
  end

  defp genui_chunk(%{chunk: %{"type" => "event"}} = assigns) do
    ~H"""
    <p class="text-sm">Event <span class="font-mono">{str(@chunk["name"])}</span></p>
    """
  end

  defp genui_chunk(assigns) do
    ~H"""
    <.json_block label="Chunk" value={@chunk} />
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp json_block(assigns) do
    assigns = assign(assigns, json: json_preview(assigns.value))

    ~H"""
    <div>
      <p class="text-xs font-semibold opacity-70">{@label}</p>
      <pre class="text-xs bg-base-200 rounded p-2 overflow-x-auto max-h-64 whitespace-pre-wrap break-all">{@json}</pre>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  `url` when it is safe to link from the admin UI: an absolute `http`/`https`
  URL with a host, or a same-origin `/api/` path. Anything else
  (`javascript:`, `data:`, protocol-relative `//host`, relative paths) is nil.
  """
  def safe_url("/api/" <> _ = path) do
    if String.contains?(path, ["\\", " "]) or not String.printable?(path), do: nil, else: path
  end

  def safe_url(url) when is_binary(url) and byte_size(url) <= 4_096 do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  def safe_url(_url), do: nil

  @doc "Pretty JSON of `value`, cut at #{@max_json_chars} characters."
  def json_preview(value) do
    json =
      case Jason.encode(value, pretty: true) do
        {:ok, json} -> json
        {:error, _} -> inspect(value, limit: 50)
      end

    if String.length(json) > @max_json_chars,
      do: String.slice(json, 0, @max_json_chars) <> "\n… (truncated)",
      else: json
  end

  # Payloads are stored as JSON (string keys); a live broadcast carries the
  # in-memory map, which an internal caller may have built with atom keys.
  defp normalize(payload) do
    case Jason.encode(payload) do
      {:ok, json} -> Jason.decode!(json)
      {:error, _} -> %{}
    end
  end

  defp link_rel, do: @link_rel

  defp str(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp str(value) when is_integer(value), do: Integer.to_string(value)
  defp str(value) when is_float(value), do: Float.to_string(value)
  defp str(_value), do: nil

  defp map_or_empty(%{} = map), do: map
  defp map_or_empty(_), do: %{}

  defp maps(list) when is_list(list), do: Enum.filter(list, &is_map/1)
  defp maps(_), do: []

  defp title_of(%{"title" => title}), do: str(title)
  defp title_of(_), do: nil

  defp media_icon("image"), do: "hero-photo"
  defp media_icon("video"), do: "hero-film"
  defp media_icon("audio"), do: "hero-musical-note"
  defp media_icon(_), do: "hero-paper-clip"

  defp media_label("image", data), do: str(data["alt"]) || "Image"
  defp media_label("file", data), do: str(data["name"]) || "File"
  defp media_label("audio", %{"voice" => true}), do: "Voice message"
  defp media_label("audio", _data), do: "Audio"
  defp media_label("video", _data), do: "Video"

  defp media_details(data) do
    [
      str(data["mimeType"]),
      format_bytes(data["size"]),
      dimensions(data["width"], data["height"]),
      duration(data["durationMs"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp dimensions(w, h) when is_integer(w) and is_integer(h), do: "#{w}×#{h}"
  defp dimensions(_w, _h), do: nil

  defp duration(ms) when is_number(ms) and ms >= 0 do
    seconds = round(ms / 1000)

    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp duration(_ms), do: nil

  defp format_bytes(n) when is_integer(n) and n >= 1_048_576,
    do: "#{Float.round(n / 1_048_576, 1)} MB"

  defp format_bytes(n) when is_integer(n) and n >= 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp format_bytes(n) when is_integer(n) and n >= 0, do: "#{n} B"
  defp format_bytes(_n), do: nil

  defp osm_url(%{"latitude" => lat, "longitude" => lon})
       when is_number(lat) and is_number(lon) and lat >= -90 and lat <= 90 and lon >= -180 and
              lon <= 180 do
    "https://www.openstreetmap.org/?mlat=#{lat}&mlon=#{lon}#map=16/#{lat}/#{lon}"
  end

  defp osm_url(_data), do: nil

  defp tool_status_class("running"), do: "badge-info"
  defp tool_status_class("completed"), do: "badge-success"
  defp tool_status_class("error"), do: "badge-error"
  defp tool_status_class(_), do: "badge-ghost"

  defp skill_status_class("loaded"), do: "badge-success"
  defp skill_status_class("error"), do: "badge-error"
  defp skill_status_class(_), do: "badge-ghost"
end
