defmodule Ratatoskr.Infrastructure.Batching.MessageBatcher do
  @moduledoc """
  Kafka-inspired intelligent message batching for performance optimization.
  
  Accumulates messages and flushes when:
  - Batch size reaches threshold
  - Timeout expires
  - Manual flush is requested
  
  Provides significant throughput improvements by reducing per-message overhead.
  """
  
  use GenServer
  require Logger

  @default_batch_size 100
  @default_batch_timeout 10
  @default_buffer_size 1000

  defmodule State do
    @moduledoc false
    defstruct [
      :batch_size,
      :batch_timeout,
      :buffer_size,
      :timer_ref,
      :callback,
      messages: [],
      message_count: 0
    ]
  end

  ## Public API

  def start_link(opts \\ []) do
    callback = Keyword.get(opts, :callback)
    if callback == nil, do: raise("callback function required")
    
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Add a message to the batch. Will trigger flush if batch_size reached.
  """
  def add_message(message) do
    GenServer.cast(__MODULE__, {:add_message, message})
  end

  @doc """
  Add multiple messages to the batch efficiently.
  """
  def add_messages(messages) when is_list(messages) do
    GenServer.cast(__MODULE__, {:add_messages, messages})
  end

  @doc """
  Force flush all pending messages immediately.
  """
  def flush() do
    GenServer.call(__MODULE__, :flush)
  end

  @doc """
  Get current batch statistics.
  """
  def stats() do
    GenServer.call(__MODULE__, :stats)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    # Get batching configuration
    config = Application.get_env(:ratatoskr, :batching, [])
    
    state = %State{
      batch_size: Keyword.get(config, :batch_size, @default_batch_size),
      batch_timeout: Keyword.get(config, :batch_timeout, @default_batch_timeout),
      buffer_size: Keyword.get(config, :buffer_size, @default_buffer_size),
      callback: Keyword.get(opts, :callback),
      messages: [],
      message_count: 0,
      timer_ref: nil
    }

    Logger.info("MessageBatcher started: batch_size=#{state.batch_size}, timeout=#{state.batch_timeout}ms")
    
    {:ok, state}
  end

  @impl true
  def handle_cast({:add_message, message}, state) do
    new_messages = [message | state.messages]
    new_count = state.message_count + 1
    
    # Start timeout timer if this is the first message
    timer_ref = maybe_start_timer(state.timer_ref, state.batch_timeout)
    
    # Check if we should flush
    if new_count >= state.batch_size do
      flush_messages(new_messages, state.callback)
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
      flush_messages(new_messages, state.callback)
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
  def handle_call(:flush, _from, state) do
    if state.message_count > 0 do
      flush_messages(state.messages, state.callback)
    end
    {:reply, :ok, reset_state(state)}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      pending_messages: state.message_count,
      batch_size: state.batch_size,
      batch_timeout: state.batch_timeout
    }
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush_timeout, state) do
    if state.message_count > 0 do
      flush_messages(state.messages, state.callback)
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

  defp flush_messages(messages, callback) do
    # Reverse to get original order
    ordered_messages = Enum.reverse(messages)
    
    # Call the callback with the batch
    try do
      callback.(ordered_messages)
      Logger.debug("Batched #{length(ordered_messages)} messages")
    rescue
      error ->
        Logger.error("Batch flush error: #{inspect(error)}")
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
      timer_ref: nil
    }
  end
end