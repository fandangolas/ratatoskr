defmodule Ratatoskr.Infrastructure.Cache.PageCache do
  @moduledoc """
  Page cache optimization for memory-efficient message storage.
  
  Inspired by Kafka's page cache usage:
  - Uses ETS ordered_set for sequential access patterns
  - Leverages BEAM's memory management 
  - Reduces garbage collection pressure
  - Optimizes for batch operations
  """


  defstruct [:table_name, :max_size, :use_compression]

  def new(opts \\ []) do
    table_name = Keyword.get(opts, :name, :page_cache)
    max_size = Keyword.get(opts, :max_size, 100_000)
    use_compression = Keyword.get(opts, :compression, false)

    # Create ETS table optimized for sequential access
    :ets.new(table_name, [
      :ordered_set,
      :public, 
      :named_table,
      {:write_concurrency, true},
      {:read_concurrency, true}
    ])

    %__MODULE__{
      table_name: table_name,
      max_size: max_size,
      use_compression: use_compression
    }
  end

  @doc """
  Store messages in batch for better performance.
  Uses sequential keys for cache-friendly access patterns.
  """
  def put_batch(cache, key_value_pairs) when is_list(key_value_pairs) do
    # Use ETS insert for batch operations (atomic and fast)
    processed_pairs = 
      if cache.use_compression do
        Enum.map(key_value_pairs, fn {k, v} -> 
          {k, compress_message(v)} 
        end)
      else
        key_value_pairs
      end

    :ets.insert(cache.table_name, processed_pairs)
    
    # Evict old entries if cache is too large
    maybe_evict_old_entries(cache)
    
    :ok
  end

  @doc """
  Get multiple values efficiently in batch.
  """
  def get_batch(cache, keys) when is_list(keys) do
    results = Enum.map(keys, fn key ->
      case :ets.lookup(cache.table_name, key) do
        [{^key, value}] -> 
          decompressed_value = 
            if cache.use_compression do
              decompress_message(value)
            else
              value
            end
          {key, decompressed_value}
        [] -> 
          {key, nil}
      end
    end)
    
    results
  end

  @doc """
  Get range of sequential entries (Kafka-like log reading).
  """
  def get_range(cache, start_key, end_key) do
    # Use ETS select for efficient range queries
    match_spec = [{{:'$1', :'$2'}, 
                   [{:andalso, {:>=, :'$1', start_key}, {:'=<', :'$1', end_key}}], 
                   [{{:'$1', :'$2'}}]}]
    
    results = :ets.select(cache.table_name, match_spec)
    
    if cache.use_compression do
      Enum.map(results, fn {k, v} -> {k, decompress_message(v)} end)
    else
      results
    end
  end

  @doc """
  Get cache statistics for monitoring.
  """
  def stats(cache) do
    info = :ets.info(cache.table_name)
    
    %{
      size: info[:size],
      memory_bytes: info[:memory] * :erlang.system_info(:wordsize),
      table_name: cache.table_name,
      max_size: cache.max_size,
      compression_enabled: cache.use_compression
    }
  end

  @doc """
  Clear all entries efficiently.
  """
  def clear(cache) do
    :ets.delete_all_objects(cache.table_name)
    :ok
  end

  ## Private Functions

  defp compress_message(message) do
    # Use Erlang's built-in compression
    :erlang.term_to_binary(message, [:compressed])
  end

  defp decompress_message(compressed) do
    :erlang.binary_to_term(compressed)
  end

  defp maybe_evict_old_entries(cache) do
    current_size = :ets.info(cache.table_name, :size)
    
    if current_size > cache.max_size do
      # Remove oldest entries (lowest keys in ordered_set)
      entries_to_remove = current_size - cache.max_size + 1000  # Remove extra for headroom
      
      # Get oldest keys
      oldest_keys = 
        :ets.first(cache.table_name)
        |> get_next_keys(cache.table_name, entries_to_remove - 1, [])
        
      # Delete oldest entries
      Enum.each(oldest_keys, fn key ->
        :ets.delete(cache.table_name, key)
      end)
    end
  end

  defp get_next_keys(:'$end_of_table', _table, _remaining, acc), do: Enum.reverse(acc)
  defp get_next_keys(_key, _table, 0, acc), do: Enum.reverse(acc)
  defp get_next_keys(key, table, remaining, acc) do
    next_key = :ets.next(table, key)
    get_next_keys(next_key, table, remaining - 1, [key | acc])
  end

  ## Behaviour Implementation

  def get(cache, key) do
    case :ets.lookup(cache.table_name, key) do
      [{^key, value}] -> 
        if cache.use_compression do
          decompress_message(value)
        else
          value
        end
      [] -> 
        nil
    end
  end

  def put(cache, key, value) do
    processed_value = 
      if cache.use_compression do
        compress_message(value)
      else
        value
      end
    
    :ets.insert(cache.table_name, {key, processed_value})
    maybe_evict_old_entries(cache)
    :ok
  end

  def delete(cache, key) do
    :ets.delete(cache.table_name, key)
    :ok
  end
end