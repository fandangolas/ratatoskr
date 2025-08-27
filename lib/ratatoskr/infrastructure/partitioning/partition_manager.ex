defmodule Ratatoskr.Infrastructure.Partitioning.PartitionManager do
  @moduledoc """
  Kafka-style partition management for topics.

  Manages partition assignment, routing, and load balancing across multiple
  partition processes. Provides consistent hashing for partition assignment
  and maintains message ordering within partitions.

  Key features:
  - Consistent hash-based partition routing
  - Configurable partition count per topic  
  - Partition key extraction and custom routing
  - Load balancing across partitions
  - Support for partition rebalancing
  """

  use GenServer
  require Logger

  alias Ratatoskr.Infrastructure.DI.Container
  alias Ratatoskr.Servers.TopicServer

  defmodule State do
    @moduledoc false
    defstruct [
      :topic_name,
      :partition_count,
      :partition_servers,
      :partition_assignments,
      :hash_ring,
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
  Routes a message to the appropriate partition based on partition key.
  """
  def route_message(topic_name, message, partition_key \\ nil) do
    GenServer.call(via_tuple(topic_name), {:route_message, message, partition_key})
  end

  @doc """
  Gets partition assignment information for consumers.
  """
  def get_partition_info(topic_name) do
    GenServer.call(via_tuple(topic_name), :get_partition_info)
  end

  @doc """
  Rebalances partitions (for future consumer group support).
  """
  def rebalance_partitions(topic_name) do
    GenServer.call(via_tuple(topic_name), :rebalance_partitions)
  end

  @doc """
  Gets current partition statistics.
  """
  def get_partition_stats(topic_name) do
    GenServer.call(via_tuple(topic_name), :get_partition_stats)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    topic_name = Keyword.fetch!(opts, :topic_name)
    partition_count = Keyword.get(opts, :partition_count, @default_partition_count)

    Logger.info(
      "Starting partition manager for topic: #{topic_name} with #{partition_count} partitions"
    )

    # Start partition servers
    {:ok, partition_servers} = start_partition_servers(topic_name, partition_count)

    # Create hash ring for consistent hashing
    hash_ring = create_hash_ring(partition_count)

    # Create partition assignments map
    partition_assignments =
      0..(partition_count - 1)
      |> Enum.into(%{}, fn partition_id ->
        {partition_id,
         %{
           server_pid: Map.get(partition_servers, partition_id),
           message_count: 0,
           last_message_at: nil
         }}
      end)

    state = %State{
      topic_name: topic_name,
      partition_count: partition_count,
      partition_servers: partition_servers,
      partition_assignments: partition_assignments,
      hash_ring: hash_ring,
      deps: Container.deps()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:route_message, message, partition_key}, _from, state) do
    # Determine partition for message
    partition_id =
      calculate_partition(message, partition_key, state.partition_count, state.hash_ring)

    # Get target partition server
    case Map.get(state.partition_servers, partition_id) do
      nil ->
        {:reply, {:error, :partition_not_found}, state}

      partition_server ->
        # Route message to partition server
        case GenServer.call(partition_server, {:publish, message}) do
          {:ok, message_id} ->
            # Update partition statistics
            new_assignments =
              update_partition_stats(state.partition_assignments, partition_id, message)

            new_state = %{state | partition_assignments: new_assignments}

            {:reply, {:ok, message_id, partition_id}, new_state}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_call(:get_partition_info, _from, state) do
    partition_info = %{
      topic_name: state.topic_name,
      partition_count: state.partition_count,
      partitions:
        Enum.map(0..(state.partition_count - 1), fn partition_id ->
          assignment = Map.get(state.partition_assignments, partition_id)

          %{
            partition_id: partition_id,
            server_pid: assignment.server_pid,
            message_count: assignment.message_count,
            last_message_at: assignment.last_message_at
          }
        end)
    }

    {:reply, {:ok, partition_info}, state}
  end

  @impl true
  def handle_call(:rebalance_partitions, _from, state) do
    # For now, return current state - future consumer group implementation
    Logger.info("Partition rebalance requested for topic: #{state.topic_name}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_partition_stats, _from, state) do
    stats = %{
      topic_name: state.topic_name,
      partition_count: state.partition_count,
      total_messages:
        Map.values(state.partition_assignments)
        |> Enum.map(fn assignment -> assignment.message_count end)
        |> Enum.sum(),
      partition_distribution:
        Enum.into(state.partition_assignments, %{}, fn {partition_id, assignment} ->
          {partition_id,
           %{
             message_count: assignment.message_count,
             last_message_at: assignment.last_message_at
           }}
        end)
    }

    {:reply, {:ok, stats}, state}
  end

  ## Private Functions

  defp via_tuple(topic_name) do
    {:via, Registry, {Ratatoskr.Registry, {:partition_manager, topic_name}}}
  end

  defp start_partition_servers(topic_name, partition_count) do
    partition_servers =
      0..(partition_count - 1)
      |> Enum.reduce(%{}, fn partition_id, acc ->
        # Start a topic server for this partition
        partition_name = "#{topic_name}_partition_#{partition_id}"

        case start_partition_server(partition_name, topic_name, partition_id) do
          {:ok, pid} ->
            Map.put(acc, partition_id, pid)

          {:error, reason} ->
            Logger.error(
              "Failed to start partition server #{partition_id} for topic #{topic_name}: #{inspect(reason)}"
            )

            acc
        end
      end)

    if map_size(partition_servers) == partition_count do
      {:ok, partition_servers}
    else
      {:error, :partition_server_startup_failed}
    end
  end

  defp start_partition_server(partition_name, topic_name, partition_id) do
    # Create a topic for this partition using existing topic server
    topic_config = %Ratatoskr.Core.Logic.Topic{
      name: partition_name,
      partition_id: partition_id,
      parent_topic: topic_name,
      max_subscribers: 1_000,
      # 24 hours
      retention_ms: 86_400_000
    }

    # Start the partition server
    case TopicServer.start_link(topic_config) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      error ->
        error
    end
  end

  defp create_hash_ring(partition_count) do
    # Create consistent hash ring with virtual nodes for better distribution
    virtual_nodes_per_partition = 100

    ring =
      0..(partition_count - 1)
      |> Enum.flat_map(fn partition_id ->
        0..(virtual_nodes_per_partition - 1)
        |> Enum.map(fn virtual_node ->
          # Create hash for virtual node
          hash_input = "#{partition_id}:#{virtual_node}"
          hash = :erlang.phash2(hash_input, 1_000_000_000)
          {hash, partition_id}
        end)
      end)
      |> Enum.sort_by(fn {hash, _partition_id} -> hash end)
      |> Enum.into(%{})

    # Convert to sorted list for binary search
    sorted_ring = Enum.sort(ring, fn {hash1, _}, {hash2, _} -> hash1 <= hash2 end)

    %{
      ring: ring,
      sorted_ring: sorted_ring,
      partition_count: partition_count
    }
  end

  defp calculate_partition(message, partition_key, partition_count, hash_ring) do
    # Extract partition key from message or use provided key
    key = partition_key || extract_partition_key(message)

    # Hash the key
    hash = :erlang.phash2(key, 1_000_000_000)

    # Find partition using consistent hashing
    find_partition_in_ring(hash, hash_ring.sorted_ring, partition_count)
  end

  defp extract_partition_key(message) do
    # Default partition key extraction - can be customized per topic
    cond do
      # If message has an explicit partition key
      Map.has_key?(message.metadata, :partition_key) ->
        message.metadata.partition_key

      # Use message ID as partition key (random distribution)
      Map.has_key?(message, :id) ->
        message.id

      # Fallback to message payload hash
      true ->
        :erlang.phash2(message.payload, 1_000_000)
    end
  end

  defp find_partition_in_ring(hash, sorted_ring, _partition_count) do
    # Binary search for the first hash >= target hash
    case Enum.find(sorted_ring, fn {ring_hash, _partition_id} -> ring_hash >= hash end) do
      {_ring_hash, partition_id} ->
        partition_id

      nil ->
        # Wrap around to first partition
        case sorted_ring do
          [{_first_hash, first_partition_id} | _] -> first_partition_id
          # Fallback
          [] -> 0
        end
    end
  end

  defp update_partition_stats(assignments, partition_id, message) do
    case Map.get(assignments, partition_id) do
      nil ->
        assignments

      assignment ->
        updated_assignment = %{
          assignment
          | message_count: assignment.message_count + 1,
            last_message_at: message.timestamp || System.monotonic_time(:millisecond)
        }

        Map.put(assignments, partition_id, updated_assignment)
    end
  end
end
