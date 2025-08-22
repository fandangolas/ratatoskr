defmodule Ratatoskr.Infrastructure.Storage.EtsAdapter do
  @moduledoc """
  ETS-based storage adapter for in-memory message persistence.

  This is the current implementation that provides fast in-memory storage
  but doesn't survive process restarts.
  """

  @behaviour Ratatoskr.Core.Behaviours.Storage

  use GenServer

  @table_name :ratatoskr_messages
  @stats_table :ratatoskr_topic_stats

  # Public API

  @doc """
  Starts the ETS storage adapter.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def persist_message(topic, message) do
    GenServer.call(__MODULE__, {:persist_message, topic, message})
  end

  @impl true
  def load_messages(topic, offset, limit) do
    GenServer.call(__MODULE__, {:load_messages, topic, offset, limit})
  end

  @impl true
  def delete_messages(topic, before_offset) do
    GenServer.call(__MODULE__, {:delete_messages, topic, before_offset})
  end

  @impl true
  def get_topic_stats(topic) do
    GenServer.call(__MODULE__, {:get_topic_stats, topic})
  end

  # Additional helper functions

  @doc """
  Gets the next available offset for a topic.
  """
  def get_next_offset(topic) do
    GenServer.call(__MODULE__, {:get_next_offset, topic})
  end

  @doc """
  Gets total storage statistics.
  """
  def get_storage_stats do
    GenServer.call(__MODULE__, :get_storage_stats)
  end

  # GenServer implementation

  @impl true
  def init(_opts) do
    # Create ETS tables
    :ets.new(@table_name, [:ordered_set, :named_table, :public, {:read_concurrency, true}])
    :ets.new(@stats_table, [:set, :named_table, :public, {:read_concurrency, true}])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:persist_message, topic, message}, _from, state) do
    offset = get_next_offset_internal(topic)
    key = {topic, offset}

    # Store message with timestamp for cleanup
    message_data = %{
      message: message,
      stored_at: System.monotonic_time(:millisecond)
    }

    :ets.insert(@table_name, {key, message_data})
    update_topic_stats(topic, :increment_message)

    {:reply, {:ok, offset}, state}
  end

  @impl true
  def handle_call({:load_messages, topic, offset, limit}, _from, state) do
    _start_key = {topic, offset}
    _end_key = {topic, offset + limit - 1}

    messages =
      :ets.select(@table_name, [
        {{{topic, :"$1"}, :"$2"},
         [{:andalso, {:>=, :"$1", offset}, {:"=<", :"$1", offset + limit - 1}}], [:"$2"]}
      ])
      |> Enum.map(fn %{message: message} -> message end)
      |> Enum.sort_by(& &1.timestamp, DateTime)

    {:reply, {:ok, messages}, state}
  end

  @impl true
  def handle_call({:delete_messages, topic, before_offset}, _from, state) do
    case before_offset do
      :all ->
        # Delete all messages for topic
        pattern = {{topic, :_}, :_}
        :ets.match_delete(@table_name, pattern)
        reset_topic_stats(topic)

      offset when is_integer(offset) ->
        # Delete messages before specific offset
        to_delete =
          :ets.select(@table_name, [
            {{{topic, :"$1"}, :_}, [{:<, :"$1", offset}], [{{topic, :"$1"}}]}
          ])

        Enum.each(to_delete, fn key -> :ets.delete(@table_name, key) end)
        update_topic_stats(topic, {:decrement_messages, length(to_delete)})
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_topic_stats, topic}, _from, state) do
    case :ets.lookup(@stats_table, topic) do
      [{^topic, stats}] -> {:reply, {:ok, stats}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_next_offset, topic}, _from, state) do
    offset = get_next_offset_internal(topic)
    {:reply, offset, state}
  end

  @impl true
  def handle_call(:get_storage_stats, _from, state) do
    total_messages = :ets.info(@table_name, :size)
    memory_usage = :ets.info(@table_name, :memory) * :erlang.system_info(:wordsize)
    topic_count = :ets.info(@stats_table, :size)

    stats = %{
      total_messages: total_messages,
      memory_bytes: memory_usage,
      topic_count: topic_count,
      table_info: %{
        messages_table: :ets.info(@table_name),
        stats_table: :ets.info(@stats_table)
      }
    }

    {:reply, {:ok, stats}, state}
  end

  # Private functions

  defp get_next_offset_internal(topic) do
    case :ets.select(@table_name, [
           {{{topic, :"$1"}, :_}, [], [:"$1"]}
         ]) do
      [] -> 0
      offsets -> Enum.max(offsets) + 1
    end
  end

  defp update_topic_stats(topic, operation) do
    current_stats =
      case :ets.lookup(@stats_table, topic) do
        [{^topic, stats}] -> stats
        [] -> %{message_count: 0, size_bytes: 0, created_at: DateTime.utc_now()}
      end

    new_stats =
      case operation do
        :increment_message ->
          %{
            current_stats
            | message_count: current_stats.message_count + 1,
              size_bytes: current_stats.size_bytes + estimate_message_size()
          }

        {:decrement_messages, count} ->
          %{
            current_stats
            | message_count: max(0, current_stats.message_count - count),
              size_bytes: max(0, current_stats.size_bytes - count * estimate_message_size())
          }
      end

    :ets.insert(@stats_table, {topic, new_stats})
  end

  defp reset_topic_stats(topic) do
    stats = %{
      message_count: 0,
      size_bytes: 0,
      created_at: DateTime.utc_now()
    }

    :ets.insert(@stats_table, {topic, stats})
  end

  defp estimate_message_size do
    # Rough estimate for memory accounting
    # Real implementation would calculate actual message size
    # 1KB average
    1024
  end
end
