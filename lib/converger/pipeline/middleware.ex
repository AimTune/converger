defmodule Converger.Pipeline.Middleware do
  @moduledoc """
  Composable middleware pipeline for transforming activities before delivery.

  Each middleware module implements the `Converger.Pipeline.Middleware` behaviour
  and can modify the activity or halt the delivery chain.

  Middleware is configured per-channel via the `transformations` field:

      %Channel{
        transformations: [
          %{"type" => "add_prefix", "prefix" => "[Alert] "},
          %{"type" => "truncate_text", "max_length" => 160}
        ]
      }
  """

  @type activity :: Converger.Activities.Activity.t()
  @type channel :: Converger.Channels.Channel.t()
  @type opts :: map()

  @doc "Transform an activity for a given channel. Return `{:cont, activity}` to continue or `{:halt, reason}` to stop."
  @callback call(activity, channel, opts) :: {:cont, activity} | {:halt, String.t()}

  @doc "Validate middleware-specific options. Called at channel changeset time."
  @callback validate_opts(opts) :: :ok | {:error, String.t()}

  @registry %{
    "add_prefix" => Converger.Pipeline.Middleware.AddPrefix,
    "add_suffix" => Converger.Pipeline.Middleware.AddSuffix,
    "text_replace" => Converger.Pipeline.Middleware.TextReplace,
    "truncate_text" => Converger.Pipeline.Middleware.TruncateText,
    "set_metadata" => Converger.Pipeline.Middleware.SetMetadata,
    "content_filter" => Converger.Pipeline.Middleware.ContentFilter
  }

  @doc """
  Resolve a middleware type string to its module.

  Built-in middleware can be extended (or overridden) with the
  `:extra_middleware` application env, a map of type string to module.
  """
  def middleware_for(type), do: Map.get(registry(), type)

  @doc "Return all registered middleware type strings."
  def registered_types, do: Map.keys(registry())

  defp registry do
    Map.merge(@registry, Application.get_env(:converger, :extra_middleware, %{}))
  end

  @doc """
  Run the middleware chain for a channel's transformations.

  Returns `{:ok, activity}` if all middleware passed (or chain is empty),
  or `{:halt, reason}` if any middleware halted the chain.
  """
  def run(activity, %{transformations: transformations} = channel)
      when is_list(transformations) and transformations != [] do
    Enum.reduce_while(transformations, {:ok, activity}, fn config, {:ok, acc_activity} ->
      type = Map.get(config, "type")

      case middleware_for(type) do
        nil ->
          {:cont, {:ok, acc_activity}}

        module ->
          case safe_call(module, type, acc_activity, channel, config) do
            {:cont, updated} -> {:cont, {:ok, updated}}
            {:halt, reason} -> {:halt, {:halt, reason}}
          end
      end
    end)
  end

  def run(activity, _channel), do: {:ok, activity}

  # A crashing middleware halts the chain instead of crashing the caller,
  # so a buggy transformation dead-letters the delivery rather than making
  # the job retry forever.
  defp safe_call(module, type, activity, channel, config) do
    module.call(activity, channel, config)
  rescue
    exception ->
      report_exception(module, type, activity, channel, :error, exception, __STACKTRACE__)
      {:halt, "middleware crashed: #{type}: #{Exception.message(exception)}"}
  catch
    kind, reason ->
      report_exception(module, type, activity, channel, kind, reason, __STACKTRACE__)
      {:halt, "middleware crashed: #{type}: #{Exception.format_banner(kind, reason)}"}
  end

  defp report_exception(module, type, activity, channel, kind, reason, stacktrace) do
    :telemetry.execute([:converger, :middleware, :exception], %{count: 1}, %{
      middleware: module,
      type: type,
      activity_id: Map.get(activity, :id),
      channel_id: Map.get(channel, :id),
      kind: kind,
      reason: reason,
      stacktrace: stacktrace
    })
  end

  @doc """
  Validate a list of transformation configs.

  Returns `:ok` if all are valid, or `{:error, message}` for the first invalid one.
  """
  def validate_chain(transformations) when is_list(transformations) do
    Enum.reduce_while(transformations, :ok, fn config, :ok ->
      type = Map.get(config, "type")

      case middleware_for(type) do
        nil ->
          {:halt, {:error, "unknown middleware type: #{type}"}}

        module ->
          case module.validate_opts(config) do
            :ok -> {:cont, :ok}
            {:error, msg} -> {:halt, {:error, "#{type}: #{msg}"}}
          end
      end
    end)
  end

  def validate_chain(_), do: {:error, "transformations must be a list"}
end
