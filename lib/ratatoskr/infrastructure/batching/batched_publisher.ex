defmodule Ratatoskr.Infrastructure.Batching.BatchedPublisher do
  @moduledoc """
  High-performance message publishing service with intelligent batching.
  
  This service acts as a layer between the gRPC interface and the core publishing 
  use cases, providing Kafka-like batching optimizations:
  
  - Accumulates messages and flushes when batch size is reached
  - Time-based flushing to ensure low latency
  - Page cache integration for memory efficiency
  - Maintains message ordering guarantees
  """
  
  use GenServer
  require Logger
  
  alias Ratatoskr.Infrastructure.Cache.PageCache
  alias Ratatoskr.Infrastructure.DI.Container
  alias Ratatoskr.UseCases.PublishMessageBatch
  
  defmodule State do
    @moduledoc false
    defstruct [
      :page_cache,
      :deps,
      :batch_size,
      :batch_timeout,
      :timer_ref,
      messages: [],
      message_count: 0,
      total_published: 0,
      total_batches: 0
    ]
  end
  
  ## Public API
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @doc """
  Publishes a single message through the batching system.
  Returns immediately while message is queued for batching.
  """
  def publish_async(topic, payload, metadata \\ %{}) do
    message = %{
      topic: topic,
      payload: payload,
      metadata: metadata,
      timestamp: System.monotonic_time(:millisecond)
    }
    
    GenServer.cast(__MODULE__, {:add_message, message})
    :ok
  end
  
  @doc """
  Publishes multiple messages through the batching system.
  More efficient than multiple single publishes.
  """
  def publish_batch_async(messages) when is_list(messages) do
    timestamped_messages = 
      Enum.map(messages, fn msg ->
        Map.put(msg, :timestamp, System.monotonic_time(:millisecond))
      end)
    
    GenServer.cast(__MODULE__, {:add_messages, timestamped_messages})
    :ok
  end
  
  @doc """
  Forces immediate flush of all pending messages.
  Useful for testing or ensuring delivery before shutdown.
  """
  def flush() do
    GenServer.call(__MODULE__, :flush)
  end
  
  @doc """
  Gets current batching statistics.
  """
  def stats() do
    GenServer.call(__MODULE__, :get_stats)
  end
  
  ## GenServer Callbacks
  
  @impl true
  def init(_opts) do
    # Get batching configuration
    config = Application.get_env(:ratatoskr, :batching, [])
    
    # Initialize page cache if enabled
    page_cache = 
      if Keyword.get(config, :use_page_cache, true) do
        PageCache.new(name: :message_cache, max_size: 50_000, compression: true)
      else
        nil
      end
    
    state = %State{
      page_cache: page_cache,
      deps: Container.deps(),
      batch_size: Keyword.get(config, :batch_size, 100),
      batch_timeout: Keyword.get(config, :batch_timeout, 10),
      timer_ref: nil,
      messages: [],
      message_count: 0,
      total_published: 0,
      total_batches: 0
    }
    
    Logger.info("BatchedPublisher started: batch_size=#{state.batch_size}, timeout=#{state.batch_timeout}ms, page_cache=#{!!page_cache}")
    
    {:ok, state}
  end
  
  @impl true 
  def handle_call(:get_stats, _from, state) do
    cache_stats = 
      if state.page_cache do
        PageCache.stats(state.page_cache)
      else
        %{cache_enabled: false}
      end
    
    publisher_stats = %{
      pending_messages: state.message_count,
      batch_size: state.batch_size,
      batch_timeout: state.batch_timeout,
      total_published: state.total_published,
      total_batches: state.total_batches,
      cache_stats: cache_stats
    }
    
    {:reply, publisher_stats, state}
  end
  
  @impl true
  def handle_call(:flush, _from, state) do
    if state.message_count > 0 do
      flush_messages(state.messages, state)
      {:reply, :ok, reset_state(state)}
    else
      {:reply, :ok, state}
    end
  end
  
  @impl true
  def handle_cast({:add_message, message}, state) do
    new_messages = [message | state.messages]
    new_count = state.message_count + 1
    
    # Start timeout timer if this is the first message
    timer_ref = maybe_start_timer(state.timer_ref, state.batch_timeout)
    
    # Check if we should flush
    if new_count >= state.batch_size do
      flush_messages(new_messages, state)
      {:noreply, reset_state(state)}
    else
      {:noreply, %{state | 
        messages: new_messages, 
        message_count: new_count,
        timer_ref: timer_ref
      }}
    end
  end
  
  @impl true
  def handle_cast({:add_messages, messages}, state) when is_list(messages) do
    new_messages = Enum.reverse(messages) ++ state.messages
    new_count = state.message_count + length(messages)
    
    # Start timeout timer if needed
    timer_ref = maybe_start_timer(state.timer_ref, state.batch_timeout)
    
    # Check if we should flush
    if new_count >= state.batch_size do
      flush_messages(new_messages, state)
      {:noreply, reset_state(state)}
    else
      {:noreply, %{state | 
        messages: new_messages, 
        message_count: new_count,
        timer_ref: timer_ref
      }}
    end
  end
  
  @impl true
  def handle_info(:flush_timeout, state) do
    if state.message_count > 0 do
      flush_messages(state.messages, state)
      {:noreply, reset_state(state)}
    else
      {:noreply, %{state | timer_ref: nil}}
    end
  end
  
  ## Private Functions

  defp maybe_start_timer(nil, timeout_ms) do
    Process.send_after(self(), :flush_timeout, timeout_ms)
  end
  defp maybe_start_timer(existing_ref, _timeout_ms) do
    existing_ref
  end

  defp flush_messages(messages, state) do
    batch_size = length(messages)
    Logger.debug("Processing batch of #{batch_size} messages")
    
    try do
      # Convert to batch message format expected by PublishMessageBatch
      # Reverse to get original order
      ordered_messages = Enum.reverse(messages)
      batch_messages = 
        Enum.map(ordered_messages, fn msg ->
          %{
            topic: msg.topic,
            payload: msg.payload,
            metadata: Map.put(msg.metadata, :batched, true)
          }
        end)
      
      # Use existing batch publishing logic
      case PublishMessageBatch.execute(batch_messages, state.deps) do
        {:ok, results} ->
          success_count = Enum.count(results, & &1.success)
          error_count = batch_size - success_count
          
          Logger.debug("Batch processed: #{success_count} success, #{error_count} errors")
          
          # Store in page cache if enabled
          maybe_cache_results(results, state.page_cache)
          
        {:error, reason} ->
          Logger.error("Batch processing failed: #{inspect(reason)}")
      end
      
    rescue
      error ->
        Logger.error("Error in batch flush: #{inspect(error)}")
    end
  end

  defp reset_state(state) do
    # Cancel existing timer if any
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    
    %{state | 
      messages: [], 
      message_count: 0,
      timer_ref: nil,
      total_published: state.total_published + state.message_count,
      total_batches: state.total_batches + 1
    }
  end
  
  defp maybe_cache_results(_results, nil), do: :ok
  defp maybe_cache_results(results, page_cache) do
    # Cache successful results for potential replay/audit
    successful_results = Enum.filter(results, & &1.success)
    
    cache_entries =
      Enum.map(successful_results, fn result ->
        key = "#{result.topic}:#{result.message_id}"
        value = %{
          topic: result.topic,
          message_id: result.message_id,
          timestamp: System.monotonic_time(:millisecond),
          success: true
        }
        {key, value}
      end)
    
    if length(cache_entries) > 0 do
      PageCache.put_batch(page_cache, cache_entries)
    end
  end
end