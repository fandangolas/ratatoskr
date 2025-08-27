defmodule Ratatoskr.Infrastructure.Cache.TopicCache do
  @moduledoc """
  ETS-based caching for topic PID lookups to optimize performance.

  Reduces Registry lookup overhead by maintaining an in-memory cache
  of topic names to PID mappings with TTL and invalidation support.
  """

  use GenServer
  require Logger

  @table_name :ratatoskr_topic_cache
  # 30 seconds TTL
  @default_ttl_ms 30_000
  # Clean up every minute
  @cleanup_interval_ms 60_000

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a topic PID from cache or falls back to Registry lookup.
  """
  @spec get_topic_pid(String.t(), module()) :: {:ok, pid()} | {:error, :not_found}
  def get_topic_pid(topic_name, registry) do
    case lookup_cache(topic_name) do
      {:ok, pid} when is_pid(pid) ->
        # Verify PID is still alive
        if Process.alive?(pid) do
          {:ok, pid}
        else
          # PID is dead, remove from cache and fallback to registry
          invalidate(topic_name)
          lookup_from_registry(topic_name, registry)
        end

      :not_found ->
        lookup_from_registry(topic_name, registry)
    end
  end

  @doc """
  Caches a topic PID with TTL.
  """
  @spec put_topic_pid(String.t(), pid()) :: :ok
  def put_topic_pid(topic_name, pid) when is_binary(topic_name) and is_pid(pid) do
    expiry_time = System.monotonic_time(:millisecond) + @default_ttl_ms
    :ets.insert(@table_name, {topic_name, pid, expiry_time})
    :ok
  end

  @doc """
  Invalidates a topic from cache.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(topic_name) when is_binary(topic_name) do
    :ets.delete(@table_name, topic_name)
    :ok
  end

  @doc """
  Clears all cache entries.
  """
  @spec clear_all() :: :ok
  def clear_all do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Gets cache statistics.
  """
  @spec stats() :: %{entries: non_neg_integer(), memory_words: non_neg_integer()}
  def stats do
    info = :ets.info(@table_name)

    %{
      entries: info[:size] || 0,
      memory_words: info[:memory] || 0
    }
  end

  # GenServer implementation

  @impl true
  def init(_opts) do
    Logger.info("Starting topic cache with TTL: #{@default_ttl_ms}ms")

    # Create ETS table
    table =
      :ets.new(@table_name, [
        # Set-based table (unique keys)
        :set,
        # Access by name
        :named_table,
        # Public access
        :public,
        # Concurrent writes
        {:write_concurrency, true},
        # Concurrent reads
        {:read_concurrency, true}
      ])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    cleanup_expired_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Topic cache received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp lookup_cache(topic_name) do
    case :ets.lookup(@table_name, topic_name) do
      [{^topic_name, pid, expiry_time}] ->
        current_time = System.monotonic_time(:millisecond)

        if current_time < expiry_time do
          {:ok, pid}
        else
          # Expired entry
          :ets.delete(@table_name, topic_name)
          :not_found
        end

      [] ->
        :not_found
    end
  end

  defp lookup_from_registry(topic_name, registry) do
    case registry.lookup_topic(topic_name) do
      {:ok, pid} = result ->
        # Cache the result for future lookups
        put_topic_pid(topic_name, pid)
        result

      {:error, :not_found} = error ->
        error
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired, @cleanup_interval_ms)
  end

  defp cleanup_expired_entries do
    current_time = System.monotonic_time(:millisecond)

    # Find and delete expired entries
    expired_count =
      :ets.select_delete(@table_name, [
        {{:_, :_, :"$1"}, [{:<, :"$1", current_time}], [true]}
      ])

    if expired_count > 0 do
      Logger.debug("Cleaned up #{expired_count} expired topic cache entries")
    end
  end
end
