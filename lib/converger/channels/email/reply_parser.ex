defmodule Converger.Channels.Email.ReplyParser do
  @moduledoc """
  Strips the quoted history and the signature from the plain-text body of an
  email reply, keeping only what the sender wrote (`talon`-style line
  heuristics).

  The body is cut at the first line that starts quoted history:

    * an attribution line: `On <date>, <name> wrote:` (also wrapped over two
      lines, and the German, French, Spanish, Dutch and Turkish forms);
    * an Outlook header block (`From: ...` followed by `Sent:` / `Date:`), or
      a `-----Original Message-----` / `________` separator;
    * a `>` quoted line;

  and at the first signature marker: the `-- ` delimiter, or a mobile
  footer such as `Sent from my iPhone`.

  When stripping would leave nothing (e.g. a forwarded message that is all
  quote), the whole body is kept. The unstripped body stays available to
  consumers, see `docs/channels/email.md`.
  """

  @attribution [
    # English, possibly wrapped by the client over two lines.
    ~r/^On\s[^\n]{1,300}(\n[^\n]{1,300})?\swrote:\s*$/m,
    # German, French, Spanish, Dutch.
    ~r/^Am\s[^\n]{1,300}schrieb[^\n]{0,100}:\s*$/m,
    ~r/^Le\s[^\n]{1,300}a\s+écrit\s*:\s*$/mu,
    ~r/^El\s[^\n]{1,300}escribió:\s*$/mu,
    ~r/^Op\s[^\n]{1,300}geschreven:\s*$/m,
    # Turkish: "... tarihinde ... şunu yazdı:"
    ~r/^[^\n]{1,300}şunu yazdı:\s*$/mu,
    ~r/^-{2,}\s*Original Message\s*-{2,}/mi,
    ~r/^-{2,}\s*Forwarded message\s*-{2,}/mi,
    ~r/^_{8,}\s*$/m,
    ~r/^\*?From:\*?\s[^\n]+\n\*?(Sent|Date):\*?\s/m,
    ~r/^>/m
  ]

  @signature [
    ~r/^--\s*$/m,
    ~r/^Sent from my [^\n]{1,40}$/mi,
    ~r/^Get Outlook for [^\n]{1,40}$/mi
  ]

  @doc "The reply text of `body` without quoted history and signature."
  @spec strip(String.t() | nil) :: String.t()
  def strip(nil), do: ""

  def strip(body) when is_binary(body) do
    body = body |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

    stripped =
      body
      |> cut_at(@attribution)
      |> cut_at(@signature)
      |> String.trim()

    if stripped == "", do: String.trim(body), else: stripped
  end

  defp cut_at(body, patterns) do
    patterns
    |> Enum.flat_map(fn pattern ->
      case Regex.run(pattern, body, return: :index) do
        [{start, _} | _] -> [start]
        nil -> []
      end
    end)
    |> case do
      [] -> body
      starts -> binary_part(body, 0, Enum.min(starts))
    end
  end
end
