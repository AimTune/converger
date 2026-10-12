defmodule Converger.RoutingRules.Conditions do
  @moduledoc """
  Conditions of a routing rule: a tree of predicates over the activity, its
  conversation, the conversation's participant and the time.

  A condition is stored as a JSON object:

    * `{}` (or nothing) matches every activity;
    * a predicate `{"field": "metadata.vip", "op": "eq", "value": true}`;
    * a group `{"all": [...]}` (AND), `{"any": [...]}` (OR) or `{"not": node}`.

  A list given as the whole condition means `{"all": list}`.

  ## Fields

  | Field | Value |
  | --- | --- |
  | `type`, `sender`, `text` | The activity's |
  | `metadata.<path>` | A key in the activity's metadata (`metadata.order.total`) |
  | `conversation.metadata.<path>`, `conversation.status` | The conversation's |
  | `participant.external_id`, `participant.display_name`, `participant.metadata.<path>` | The conversation's participant, if any |
  | `time.hour`, `time.minute`, `time.minute_of_day`, `time.weekday`, `time.date` | The activity's `inserted_at` in UTC, shifted by the predicate's optional `utc_offset_minutes`; `weekday` is 1 (Monday) to 7, `date` is `YYYY-MM-DD` |

  ## Operators

  `eq`, `neq`, `in` (value is a list), `contains` (substring of a string,
  element of a list, key of an object), `regex` (string fields), `exists`
  (value `true`, the default, or `false`), `gt`, `lt` (two numbers or two
  strings). A missing field equals nothing: `eq`, `in`, `contains`, `regex`,
  `gt` and `lt` are false and `neq` is true.

  ## Limits

  Conditions are validated when a rule is saved (`validate/1`): at most
  32 predicates, nesting depth 4, 100 values per `in`, field paths of
  8 segments. A regex is at most 256 bytes, must compile, and runs with
  a PCRE match limit, so a pathological pattern fails (no match) instead of
  blocking a delivery.
  """

  @ops ~w(eq neq in contains regex exists gt lt)
  @time_fields ~w(hour minute minute_of_day weekday date)
  @predicate_keys ~w(field op value utc_offset_minutes)

  @max_predicates 32
  @max_depth 4
  @max_in_values 100
  @max_segments 8
  @max_regex_bytes 256
  @regex_match_limit 100_000

  @type t :: map()

  @doc "Supported operators."
  def ops, do: @ops

  @doc "Maximum regex length in bytes."
  def max_regex_bytes, do: @max_regex_bytes

  @doc """
  Normalise a condition as given by a client: `nil` is `%{}` and a list is
  `%{"all" => list}`. Atom keys become strings.
  """
  def normalize(nil), do: %{}
  def normalize(list) when is_list(list), do: %{"all" => stringify(list)}
  def normalize(map) when is_map(map), do: stringify(map)
  def normalize(other), do: other

  defp stringify(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  @doc """
  Validate a (normalised) condition. Returns `:ok` or `{:error, message}`.
  """
  def validate(conditions) when conditions == %{}, do: :ok

  def validate(conditions) when is_map(conditions) do
    with {:ok, count} <- validate_node(conditions, 1, "conditions") do
      if count > @max_predicates,
        do: {:error, "has #{count} predicates, at most #{@max_predicates} are allowed"},
        else: :ok
    end
  end

  def validate(_), do: {:error, "must be an object or a list of predicates"}

  defp validate_node(_node, depth, path) when depth > @max_depth,
    do: {:error, "#{path}: nested deeper than #{@max_depth} levels"}

  defp validate_node(%{"all" => children} = node, depth, path) when map_size(node) == 1,
    do: validate_children(children, depth, "#{path}.all")

  defp validate_node(%{"any" => children} = node, depth, path) when map_size(node) == 1,
    do: validate_children(children, depth, "#{path}.any")

  defp validate_node(%{"not" => child} = node, depth, path) when map_size(node) == 1 do
    if is_map(child) and child != %{},
      do: validate_node(child, depth + 1, "#{path}.not"),
      else: {:error, "#{path}.not: must be a condition object"}
  end

  defp validate_node(%{"field" => _} = predicate, _depth, path),
    do: validate_predicate(predicate, path)

  defp validate_node(node, _depth, path) when is_map(node),
    do:
      {:error,
       "#{path}: expected a predicate (field, op, value) or a single all / any / not group"}

  defp validate_node(_node, _depth, path), do: {:error, "#{path}: must be an object"}

  defp validate_children(children, depth, path) when is_list(children) and children != [] do
    children
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, 0}, fn {child, index}, {:ok, count} ->
      case validate_node(child, depth + 1, "#{path}[#{index}]") do
        {:ok, n} -> {:cont, {:ok, count + n}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_children(_children, _depth, path),
    do: {:error, "#{path}: must be a non-empty list"}

  defp validate_predicate(predicate, path) do
    unknown = Map.keys(predicate) -- @predicate_keys

    with :ok <- if(unknown == [], do: :ok, else: {:error, "unknown keys #{inspect(unknown)}"}),
         :ok <- validate_field(predicate["field"]),
         :ok <- validate_op(predicate["op"], predicate),
         :ok <- validate_offset(predicate) do
      {:ok, 1}
    else
      {:error, message} -> {:error, "#{path}: #{message}"}
    end
  end

  defp validate_field(field) when is_binary(field) do
    segments = String.split(field, ".")

    cond do
      length(segments) > @max_segments ->
        {:error, "field #{field} has more than #{@max_segments} segments"}

      Enum.any?(segments, &(&1 == "")) ->
        {:error, "field #{field} has an empty segment"}

      known_field?(segments) ->
        :ok

      true ->
        {:error,
         "unknown field #{field} (use type, sender, text, metadata.*, conversation.metadata.*, " <>
           "conversation.status, participant.external_id, participant.display_name, " <>
           "participant.metadata.* or time.#{Enum.join(@time_fields, "|")})"}
    end
  end

  defp validate_field(_), do: {:error, "field must be a string"}

  defp known_field?([root]) when root in ~w(type sender text), do: true
  defp known_field?(["metadata", _ | _]), do: true
  defp known_field?(["conversation", "metadata", _ | _]), do: true
  defp known_field?(["conversation", "status"]), do: true
  defp known_field?(["participant", key]) when key in ~w(external_id display_name), do: true
  defp known_field?(["participant", "metadata", _ | _]), do: true
  defp known_field?(["time", key]) when key in @time_fields, do: true
  defp known_field?(_), do: false

  defp validate_op(op, predicate) when op in ~w(eq neq) do
    if Map.has_key?(predicate, "value"), do: :ok, else: {:error, "#{op} needs a value"}
  end

  defp validate_op("in", %{"value" => values}) when is_list(values) do
    if length(values) <= @max_in_values,
      do: :ok,
      else: {:error, "in accepts at most #{@max_in_values} values"}
  end

  defp validate_op("in", _), do: {:error, "in needs a list value"}

  defp validate_op("contains", %{"value" => value}) when not is_nil(value), do: :ok
  defp validate_op("contains", _), do: {:error, "contains needs a value"}

  defp validate_op("regex", %{"value" => pattern}) when is_binary(pattern) do
    cond do
      byte_size(pattern) > @max_regex_bytes ->
        {:error, "regex is longer than #{@max_regex_bytes} bytes"}

      match?({:ok, _}, compile(pattern)) ->
        :ok

      true ->
        {:error, "regex does not compile: #{inspect(pattern)}"}
    end
  end

  defp validate_op("regex", _), do: {:error, "regex needs a string value"}

  defp validate_op("exists", predicate) do
    if Map.get(predicate, "value", true) in [true, false],
      do: :ok,
      else: {:error, "exists takes true or false"}
  end

  defp validate_op(op, %{"value" => value}) when op in ~w(gt lt) do
    if is_number(value) or is_binary(value),
      do: :ok,
      else: {:error, "#{op} needs a number or a string value"}
  end

  defp validate_op(op, _) when op in ~w(gt lt), do: {:error, "#{op} needs a value"}

  defp validate_op(op, _),
    do: {:error, "unknown op #{inspect(op)} (use #{Enum.join(@ops, ", ")})"}

  defp validate_offset(%{"utc_offset_minutes" => offset} = predicate) do
    cond do
      not String.starts_with?(predicate["field"], "time.") ->
        {:error, "utc_offset_minutes only applies to time.* fields"}

      is_integer(offset) and offset >= -720 and offset <= 840 ->
        :ok

      true ->
        {:error, "utc_offset_minutes must be an integer from -720 to 840"}
    end
  end

  defp validate_offset(_predicate), do: :ok

  # --- Evaluation ---

  @doc """
  The evaluation context of an activity.

  `activity` and `conversation` may be structs or maps; `participant` is a
  participant (or nil). The time is the activity's `inserted_at`, or `at`
  (default: now) for an activity that is not stored yet.
  """
  def context(activity, conversation, participant, at \\ nil) do
    %{
      "type" => Map.get(activity, :type),
      "sender" => Map.get(activity, :sender),
      "text" => Map.get(activity, :text),
      "metadata" => Map.get(activity, :metadata) || %{},
      "conversation" => %{
        "metadata" => (conversation && Map.get(conversation, :metadata)) || %{},
        "status" => conversation && Map.get(conversation, :status)
      },
      "participant" => participant_context(participant),
      "time" => Map.get(activity, :inserted_at) || at || DateTime.utc_now()
    }
  end

  defp participant_context(nil), do: %{}

  defp participant_context(participant) do
    %{
      "external_id" => Map.get(participant, :external_id),
      "display_name" => Map.get(participant, :display_name),
      "metadata" => Map.get(participant, :metadata) || %{}
    }
  end

  @doc "Whether the condition holds in `context` (see `context/4`)."
  def matches?(conditions, _context) when conditions == %{} or is_nil(conditions), do: true

  def matches?(%{"all" => children}, context) when is_list(children),
    do: Enum.all?(children, &__MODULE__.matches?(&1, context))

  def matches?(%{"any" => children}, context) when is_list(children),
    do: Enum.any?(children, &__MODULE__.matches?(&1, context))

  def matches?(%{"not" => child}, context), do: not __MODULE__.matches?(child, context)

  def matches?(%{"field" => field, "op" => op} = predicate, context) do
    value = resolve(field, predicate, context)
    apply_op(op, value, predicate)
  end

  # Anything else was rejected by validate/1; an invalid stored condition
  # never matches.
  def matches?(_conditions, _context), do: false

  defp resolve("time." <> key, predicate, context) do
    offset = Map.get(predicate, "utc_offset_minutes", 0)
    time_value(key, DateTime.add(to_datetime(context["time"]), offset * 60, :second))
  end

  defp resolve(field, _predicate, context), do: dig(context, String.split(field, "."))

  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]) when not is_struct(map), do: dig(Map.get(map, key), rest)
  defp dig(_value, _path), do: nil

  defp to_datetime(%DateTime{} = at), do: at
  defp to_datetime(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp time_value("hour", at), do: at.hour
  defp time_value("minute", at), do: at.minute
  defp time_value("minute_of_day", at), do: at.hour * 60 + at.minute
  defp time_value("weekday", at), do: Date.day_of_week(at)
  defp time_value("date", at), do: at |> DateTime.to_date() |> Date.to_iso8601()
  defp time_value(_key, _at), do: nil

  defp apply_op("eq", value, %{"value" => expected}), do: equal?(value, expected)
  defp apply_op("neq", value, %{"value" => expected}), do: not equal?(value, expected)

  defp apply_op("in", value, %{"value" => values}) when is_list(value),
    do: Enum.any?(value, fn v -> Enum.any?(values, &equal?(v, &1)) end)

  defp apply_op("in", value, %{"value" => values}), do: Enum.any?(values, &equal?(value, &1))

  defp apply_op("contains", value, %{"value" => needle}) when is_binary(value),
    do: String.contains?(value, to_string(needle))

  defp apply_op("contains", value, %{"value" => needle}) when is_list(value),
    do: Enum.any?(value, &equal?(&1, needle))

  defp apply_op("contains", %{} = value, %{"value" => needle}) when is_binary(needle),
    do: Map.has_key?(value, needle)

  defp apply_op("regex", value, %{"value" => pattern}) when is_binary(value),
    do: regex_match?(pattern, value)

  defp apply_op("exists", value, predicate),
    do: not is_nil(value) == Map.get(predicate, "value", true)

  defp apply_op("gt", value, %{"value" => bound}), do: compare(value, bound) == :gt
  defp apply_op("lt", value, %{"value" => bound}), do: compare(value, bound) == :lt
  defp apply_op(_op, _value, _predicate), do: false

  # JSON has no integer / float distinction: 1 equals 1.0.
  defp equal?(a, b) when is_number(a) and is_number(b), do: a == b
  defp equal?(a, b), do: a === b

  defp compare(a, b) when is_number(a) and is_number(b) do
    cond do
      a > b -> :gt
      a < b -> :lt
      true -> :eq
    end
  end

  defp compare(a, b) when is_binary(a) and is_binary(b) do
    cond do
      a > b -> :gt
      a < b -> :lt
      true -> :eq
    end
  end

  defp compare(_a, _b), do: :incomparable

  defp compile(pattern), do: :re.compile(pattern, [:unicode])

  # Patterns are bounded at validation; PCRE's match limit bounds the work of
  # one match, so catastrophic backtracking ends as "no match".
  defp regex_match?(pattern, subject) do
    case compile(pattern) do
      {:ok, compiled} ->
        :re.run(subject, compiled, [{:capture, :none}, {:match_limit, @regex_match_limit}]) ==
          :match

      _ ->
        false
    end
  rescue
    # A subject that is not valid UTF-8.
    ArgumentError -> false
  end
end
