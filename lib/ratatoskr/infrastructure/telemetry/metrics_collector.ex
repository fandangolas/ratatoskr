defmodule Ratatoskr.Infrastructure.Telemetry.MetricsCollector do
  @moduledoc """
  Telemetry-based metrics collector implementation.

  Collects and emits metrics using Elixir's telemetry library.
  Can be extended to support various backends (Prometheus, StatsD, etc.).
  """

  @behaviour Ratatoskr.Core.Behaviours.Metrics

  @impl true
  def increment_counter(name, value, labels)
      when is_atom(name) and is_number(value) and is_map(labels) do
    :telemetry.execute(
      [:ratatoskr, :metrics, name],
      %{value: value},
      Map.put(labels, :metric_type, :counter)
    )

    :ok
  rescue
    # Don't fail application due to metrics errors
    _ -> :ok
  end

  @impl true
  def observe_histogram(name, value, labels)
      when is_atom(name) and is_number(value) and is_map(labels) do
    :telemetry.execute(
      [:ratatoskr, :metrics, name],
      %{value: value},
      Map.put(labels, :metric_type, :histogram)
    )

    :ok
  rescue
    _ -> :ok
  end

  @impl true
  def set_gauge(name, value, labels) when is_atom(name) and is_number(value) and is_map(labels) do
    :telemetry.execute(
      [:ratatoskr, :metrics, name],
      %{value: value},
      Map.put(labels, :metric_type, :gauge)
    )

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Attaches a metrics handler to process telemetry events.
  """
  def attach_handler(handler_id, events, handler_function)
      when is_list(events) and is_function(handler_function) do
    :telemetry.attach_many(handler_id, events, handler_function, %{})
  end

  @doc """
  Attaches multiple handlers for different metric types.
  """
  def attach_default_handlers do
    # Logger handler for debugging - use specific events instead of wildcards
    attach_handler(
      :ratatoskr_metrics_logger,
      [
        [:ratatoskr, :metrics, :messages_published_total],
        [:ratatoskr, :metrics, :subscriptions_created_total],
        [:ratatoskr, :metrics, :topics_created_total]
      ],
      &log_metric/4
    )

    # Console handler for development
    if Mix.env() == :dev do
      attach_handler(
        :ratatoskr_metrics_console,
        [
          [:ratatoskr, :metrics, :messages_published_total],
          [:ratatoskr, :metrics, :subscriptions_created_total],
          [:ratatoskr, :metrics, :topics_created_total]
        ],
        &console_metric/4
      )
    end
  end

  @doc """
  Detaches all metrics handlers.
  """
  def detach_handlers do
    :telemetry.detach(:ratatoskr_metrics_logger)

    if Mix.env() == :dev do
      :telemetry.detach(:ratatoskr_metrics_console)
    end
  end

  # Handler functions

  defp log_metric(event_name, measurements, metadata, _config) do
    require Logger

    Logger.debug("Metric emitted",
      event: event_name,
      measurements: measurements,
      metadata: metadata
    )
  end

  defp console_metric(event_name, measurements, metadata, _config) do
    metric_type = Map.get(metadata, :metric_type, :unknown)
    value = Map.get(measurements, :value, 0)

    IO.puts([
      "📊 [#{metric_type}] ",
      inspect(event_name),
      " = ",
      to_string(value),
      if map_size(metadata) > 1 do
        [" ", inspect(Map.delete(metadata, :metric_type))]
      else
        ""
      end
    ])
  end

  @doc """
  Emits application startup metrics.
  """
  def emit_startup_metrics do
    increment_counter(:application_starts_total, 1, %{})
    set_gauge(:application_uptime_seconds, 0, %{})

    # Emit system info
    observe_histogram(:system_process_count, length(Process.list()), %{})
    observe_histogram(:system_memory_usage_bytes, :erlang.memory(:total), %{})
  end

  @doc """
  Emits periodic system metrics.
  """
  def emit_system_metrics do
    # Process information
    process_count = length(Process.list())
    set_gauge(:system_processes_total, process_count, %{})

    # Memory information
    memory_info = :erlang.memory()

    Enum.each(memory_info, fn {type, bytes} ->
      set_gauge(:system_memory_bytes, bytes, %{type: to_string(type)})
    end)

    # Message queue lengths
    queue_lengths =
      Process.list()
      |> Enum.map(&Process.info(&1, :message_queue_len))
      # Filter out processes that died
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn {_, len} -> len end)
      |> Enum.reject(&is_nil/1)

    if not Enum.empty?(queue_lengths) do
      avg_queue_length = Enum.sum(queue_lengths) / length(queue_lengths)
      max_queue_length = Enum.max(queue_lengths)

      set_gauge(:message_queue_length_avg, avg_queue_length, %{})
      set_gauge(:message_queue_length_max, max_queue_length, %{})
    end
  end

  @doc """
  Starts a periodic metrics emission process.
  """
  def start_periodic_metrics(interval_ms \\ 30_000) do
    spawn_link(fn ->
      periodic_metrics_loop(interval_ms)
    end)
  end

  defp periodic_metrics_loop(interval_ms) do
    emit_system_metrics()
    Process.sleep(interval_ms)
    periodic_metrics_loop(interval_ms)
  end
end
