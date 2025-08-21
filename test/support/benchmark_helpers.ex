defmodule BenchmarkHelpers do
  @moduledoc """
  Utilities for benchmarking and performance testing Ratatoskr.

  Provides functions to measure throughput, latency, memory usage,
  and other performance metrics for the message broker.
  """

  require Logger

  @doc """
  Measures message publishing throughput in messages per second.

  ## Parameters
  - `message_count`: Number of messages to publish
  - `topic_name`: Name of topic to publish to

  ## Returns
  `{:ok, %{throughput: float, time_ms: integer, messages_sent: integer}}`
  """
  @spec measure_throughput(integer(), String.t()) :: {:ok, map()} | {:error, term()}
  def measure_throughput(message_count, topic_name) do
    # Ensure topic exists
    case Ratatoskr.create_topic(topic_name) do
      {:ok, _} -> :ok
      {:error, :topic_already_exists} -> :ok
      error -> error
    end

    {time_us, result} =
      :timer.tc(fn ->
        try do
          for i <- 1..message_count do
            case Ratatoskr.publish(topic_name, %{id: i, timestamp: System.monotonic_time()}) do
              {:ok, _} -> :ok
              error -> throw({:publish_error, error})
            end
          end

          :ok
        catch
          {:publish_error, error} -> {:error, error}
        end
      end)

    case result do
      :ok ->
        throughput = message_count / (time_us / 1_000_000)

        {:ok,
         %{
           throughput: throughput,
           time_ms: div(time_us, 1000),
           messages_sent: message_count,
           avg_time_per_message_us: div(time_us, message_count)
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Measures end-to-end message latencies and calculates percentiles.

  ## Parameters  
  - `message_count`: Number of messages to measure
  - `topic_name`: Name of topic to use

  ## Returns
  `{:ok, %{p50: float, p95: float, p99: float, max: float, min: float}}`
  All latencies in milliseconds.
  """
  @spec measure_latencies(integer(), String.t()) :: {:ok, map()} | {:error, term()}
  def measure_latencies(message_count, topic_name) do
    # Ensure topic exists
    case Ratatoskr.create_topic(topic_name) do
      {:ok, _} -> :ok
      {:error, :topic_already_exists} -> :ok
      error -> error
    end

    # Subscribe to receive messages
    case Ratatoskr.subscribe(topic_name) do
      {:ok, _ref} -> :ok
      error -> error
    end

    # Send messages and measure latencies
    latencies =
      for i <- 1..message_count do
        start_time = System.monotonic_time(:microsecond)

        case Ratatoskr.publish(topic_name, %{id: i, start_time: start_time}) do
          {:ok, _} ->
            receive do
              {:message, message} ->
                end_time = System.monotonic_time(:microsecond)
                end_time - message.payload.start_time
            after
              # 5 second timeout per message
              5000 -> :timeout
            end

          error ->
            Logger.error("Failed to publish message #{i}: #{inspect(error)}")
            :error
        end
      end

    # Filter out timeouts and errors
    valid_latencies = Enum.filter(latencies, &is_integer/1)

    if length(valid_latencies) < message_count do
      Logger.warning(
        "Only #{length(valid_latencies)}/#{message_count} messages completed successfully"
      )
    end

    case valid_latencies do
      [] ->
        {:error, :no_successful_measurements}

      latencies ->
        {:ok, calculate_percentiles(latencies)}
    end
  end

  @doc """
  Tests concurrent subscribers receiving the same message.

  ## Parameters
  - `subscriber_count`: Number of concurrent subscribers
  - `topic_name`: Name of topic to use
  - `timeout_ms`: Timeout for all subscribers to receive message

  ## Returns
  `{:ok, %{subscribers_responded: integer, response_time_ms: integer}}`
  """
  @spec test_concurrent_subscribers(integer(), String.t(), integer()) ::
          {:ok, map()} | {:error, term()}
  def test_concurrent_subscribers(subscriber_count, topic_name, timeout_ms \\ 5000) do
    # Ensure topic exists
    case Ratatoskr.create_topic(topic_name) do
      {:ok, _} -> :ok
      {:error, :topic_already_exists} -> :ok
      error -> error
    end

    test_pid = self()

    # Spawn subscriber processes
    subscribers =
      for i <- 1..subscriber_count do
        spawn_link(fn ->
          case Ratatoskr.subscribe(topic_name) do
            {:ok, _ref} ->
              receive do
                {:message, message} ->
                  send(test_pid, {:subscriber_received, i, message, System.monotonic_time()})
              after
                timeout_ms -> send(test_pid, {:subscriber_timeout, i})
              end

            error ->
              send(test_pid, {:subscriber_error, i, error})
          end
        end)
      end

    # Wait for subscriptions to register
    Process.sleep(100)

    # Publish message and measure response time
    start_time = System.monotonic_time()

    case Ratatoskr.publish(topic_name, %{test_message: "concurrent_test", timestamp: start_time}) do
      {:ok, _message_id} ->
        responses = collect_subscriber_responses(subscriber_count, timeout_ms)
        end_time = System.monotonic_time()

        successful_responses =
          Enum.count(responses, fn
            {:subscriber_received, _, _, _} -> true
            _ -> false
          end)

        {:ok,
         %{
           subscribers_spawned: subscriber_count,
           subscribers_responded: successful_responses,
           response_time_ms:
             System.convert_time_unit(end_time - start_time, :native, :millisecond),
           responses: responses
         }}

      error ->
        # Clean up subscribers
        Enum.each(subscribers, &Process.exit(&1, :kill))
        {:error, {:publish_failed, error}}
    end
  end

  @doc """
  Measures memory usage during a benchmark operation.

  ## Parameters
  - `operation`: Function to execute while measuring memory

  ## Returns  
  `{:ok, %{memory_used_bytes: integer, memory_used_mb: float, result: term}}`
  """
  @spec measure_memory_usage(function()) :: {:ok, map()}
  def measure_memory_usage(operation) do
    # Force garbage collection before measurement
    :erlang.garbage_collect()
    # Allow GC to complete
    Process.sleep(10)

    memory_before = :erlang.memory(:total)
    process_count_before = :erlang.system_info(:process_count)

    result = operation.()

    # Force garbage collection after operation
    :erlang.garbage_collect()
    Process.sleep(10)

    memory_after = :erlang.memory(:total)
    process_count_after = :erlang.system_info(:process_count)

    memory_used = memory_after - memory_before

    {:ok,
     %{
       memory_used_bytes: memory_used,
       memory_used_mb: memory_used / 1_048_576,
       process_count_before: process_count_before,
       process_count_after: process_count_after,
       process_count_diff: process_count_after - process_count_before,
       result: result
     }}
  end

  @doc """
  Creates a unique topic name for benchmarking to avoid conflicts.
  """
  @spec benchmark_topic(String.t()) :: String.t()
  def benchmark_topic(prefix \\ "benchmark") do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  @doc """
  Cleans up benchmark topics and resources.
  """
  @spec cleanup_benchmark_topic(String.t()) :: :ok
  def cleanup_benchmark_topic(topic_name) do
    case Ratatoskr.delete_topic(topic_name) do
      :ok ->
        :ok

      {:error, :topic_not_found} ->
        :ok

      error ->
        Logger.warning("Failed to cleanup topic #{topic_name}: #{inspect(error)}")
        :ok
    end
  end

  # Private Functions

  defp calculate_percentiles(latencies) do
    sorted = Enum.sort(latencies)
    len = length(sorted)

    %{
      count: len,
      # Convert μs to ms
      min: (Enum.min(sorted) / 1000) |> Float.round(3),
      # Convert μs to ms  
      max: (Enum.max(sorted) / 1000) |> Float.round(3),
      # Median
      p50: percentile(sorted, 0.50) |> Float.round(3),
      p95: percentile(sorted, 0.95) |> Float.round(3),
      p99: percentile(sorted, 0.99) |> Float.round(3),
      # Average
      avg: (Enum.sum(sorted) / len / 1000) |> Float.round(3)
    }
  end

  defp percentile(sorted_list, percentile) do
    len = length(sorted_list)
    # Convert to 0-based index
    index = max(1, round(percentile * len)) - 1
    # Convert μs to ms
    Enum.at(sorted_list, index) / 1000
  end

  defp collect_subscriber_responses(expected_count, timeout_ms) do
    collect_responses([], expected_count, timeout_ms)
  end

  defp collect_responses(responses, 0, _timeout_ms), do: responses

  defp collect_responses(responses, remaining, timeout_ms) do
    receive do
      response ->
        collect_responses([response | responses], remaining - 1, timeout_ms)
    after
      timeout_ms ->
        # Return what we have so far
        responses
    end
  end
end
