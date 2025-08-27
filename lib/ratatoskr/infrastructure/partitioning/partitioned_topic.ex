defmodule Ratatoskr.Infrastructure.Partitioning.PartitionedTopic do
  @moduledoc """
  High-level partitioned topic management with Kafka-style semantics.

  This module provides a unified interface for topics that use partitioning
  for parallel processing and higher throughput. It coordinates between
  the partition manager and individual partition servers.

  Features:
  - Automatic partition creation and management
  - Partition-aware message publishing
  - Load balancing across partitions
  - Consumer group coordination (future)
  - Partition health monitoring
  """

  use GenServer
  require Logger

  alias Ratatoskr.Infrastructure.Partitioning.PartitionManager
  alias Ratatoskr.Infrastructure.DI.Container

  defmodule State do
    @moduledoc false
    defstruct [
      :topic_name,
      :partition_count,
      :partition_manager_pid,
      :config,
      :stats,
      :deps
    ]
  end

  @default_partition_count 4

  ## Public API

  def start_link(opts) do
    topic_name = Keyword.fetch!(opts, :topic_name)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(topic_name))
  end

  @doc """
  Publishes a message to the partitioned topic.
  Uses partition key for routing if provided, otherwise uses default routing.
  """
  def publish_message(topic_name, message, partition_key \\ nil) do
    GenServer.call(via_tuple(topic_name), {:publish_message, message, partition_key})
  end

  @doc """
  Publishes multiple messages to the partitioned topic.
  Each message can have its own partition key for optimal distribution.
  """
  def publish_batch(topic_name, messages) when is_list(messages) do
    GenServer.call(via_tuple(topic_name), {:publish_batch, messages})
  end

  @doc """
  Gets comprehensive topic statistics including per-partition metrics.
  """
  def get_topic_stats(topic_name) do
    GenServer.call(via_tuple(topic_name), :get_topic_stats)
  end

  @doc """
  Gets partition assignment information for load balancing.
  """
  def get_partition_assignments(topic_name) do
    GenServer.call(via_tuple(topic_name), :get_partition_assignments)
  end

  @doc """
  Rebalances partitions for optimal load distribution.
  """
  def rebalance_topic(topic_name) do
    GenServer.call(via_tuple(topic_name), :rebalance_topic)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    topic_name = Keyword.fetch!(opts, :topic_name)
    partition_count = Keyword.get(opts, :partition_count, @default_partition_count)
    config = Keyword.get(opts, :config, %{})

    Logger.info("Starting partitioned topic: #{topic_name} with #{partition_count} partitions")

    # Start partition manager
    partition_manager_opts = [
      topic_name: topic_name,
      partition_count: partition_count
    ]

    case PartitionManager.start_link(partition_manager_opts) do
      {:ok, partition_manager_pid} ->
        state = %State{
          topic_name: topic_name,
          partition_count: partition_count,
          partition_manager_pid: partition_manager_pid,
          config: config,
          stats: initialize_stats(topic_name, partition_count),
          deps: Container.deps()
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error(
          "Failed to start partition manager for topic #{topic_name}: #{inspect(reason)}"
        )

        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:publish_message, message, partition_key}, _from, state) do
    # Route message through partition manager
    case PartitionManager.route_message(state.topic_name, message, partition_key) do
      {:ok, message_id, partition_id} ->
        # Update topic-level statistics
        new_stats = update_topic_stats(state.stats, partition_id, message)
        new_state = %{state | stats: new_stats}

        Logger.debug("Message routed to partition #{partition_id} for topic #{state.topic_name}")

        {:reply, {:ok, message_id, partition_id}, new_state}

      error ->
        Logger.error("Failed to route message for topic #{state.topic_name}: #{inspect(error)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:publish_batch, messages}, _from, state) when is_list(messages) do
    Logger.debug(
      "Publishing batch of #{length(messages)} messages to partitioned topic: #{state.topic_name}"
    )

    # Group messages by partition for optimal batching
    {results, new_stats} = publish_batch_with_partitioning(messages, state)

    new_state = %{state | stats: new_stats}

    {:reply, {:ok, results}, new_state}
  end

  @impl true
  def handle_call(:get_topic_stats, _from, state) do
    # Get detailed partition statistics
    case PartitionManager.get_partition_stats(state.topic_name) do
      {:ok, partition_stats} ->
        combined_stats = %{
          topic_name: state.topic_name,
          partition_count: state.partition_count,
          topic_stats: state.stats,
          partition_stats: partition_stats,
          total_messages: calculate_total_messages(state.stats),
          average_messages_per_partition: calculate_average_messages_per_partition(state.stats)
        }

        {:reply, {:ok, combined_stats}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_partition_assignments, _from, state) do
    case PartitionManager.get_partition_info(state.topic_name) do
      {:ok, partition_info} ->
        {:reply, {:ok, partition_info}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:rebalance_topic, _from, state) do
    Logger.info("Rebalancing partitioned topic: #{state.topic_name}")

    case PartitionManager.rebalance_partitions(state.topic_name) do
      :ok ->
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:publish, message}, from, state) do
    # Use the publish_message handler for consistency
    handle_call({:publish_message, message, message.partition_key}, from, state)
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    {:reply, :ok, state}
  end

  ## Private Functions

  defp via_tuple(topic_name) do
    {:via, Registry, {Ratatoskr.Registry, {:partitioned_topic, topic_name}}}
  end

  defp initialize_stats(topic_name, partition_count) do
    %{
      topic_name: topic_name,
      partition_count: partition_count,
      created_at: System.monotonic_time(:millisecond),
      total_messages: 0,
      partition_message_counts:
        0..(partition_count - 1)
        |> Enum.into(%{}, fn partition_id -> {partition_id, 0} end),
      last_message_at: nil
    }
  end

  defp update_topic_stats(stats, partition_id, message) do
    current_partition_count = Map.get(stats.partition_message_counts, partition_id, 0)

    %{
      stats
      | total_messages: stats.total_messages + 1,
        partition_message_counts:
          Map.put(stats.partition_message_counts, partition_id, current_partition_count + 1),
        last_message_at: message.timestamp || System.monotonic_time(:millisecond)
    }
  end

  defp publish_batch_with_partitioning(messages, state) do
    # Route each message to its target partition
    routed_messages =
      Enum.map(messages, fn message ->
        partition_key = extract_partition_key_from_batch_message(message)

        case PartitionManager.route_message(state.topic_name, message, partition_key) do
          {:ok, message_id, partition_id} ->
            {:ok,
             %{
               message_id: message_id,
               partition_id: partition_id,
               original_message: message,
               success: true,
               error: nil
             }}

          {:error, reason} ->
            {:error,
             %{
               message_id: nil,
               partition_id: nil,
               original_message: message,
               success: false,
               error: to_string(reason)
             }}
        end
      end)

    # Separate successful and failed messages
    {successful_results, failed_results} =
      Enum.split_with(routed_messages, fn
        {:ok, _result} -> true
        {:error, _result} -> false
      end)

    # Update statistics for successful messages
    new_stats =
      successful_results
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.reduce(state.stats, fn result, acc_stats ->
        update_topic_stats(acc_stats, result.partition_id, result.original_message)
      end)

    # Combine all results
    all_results =
      Enum.map(successful_results, fn {:ok, result} -> result end) ++
        Enum.map(failed_results, fn {:error, result} -> result end)

    {all_results, new_stats}
  end

  defp extract_partition_key_from_batch_message(message) do
    # Extract partition key from batch message format
    cond do
      is_map(message) and Map.has_key?(message, :partition_key) ->
        message.partition_key

      is_map(message) and Map.has_key?(message, :metadata) and
          Map.has_key?(message.metadata, :partition_key) ->
        message.metadata.partition_key

      # Default: no specific partition key (will use default routing)
      true ->
        nil
    end
  end

  defp calculate_total_messages(stats) do
    stats.total_messages
  end

  defp calculate_average_messages_per_partition(stats) do
    if stats.partition_count > 0 do
      stats.total_messages / stats.partition_count
    else
      0
    end
  end
end
