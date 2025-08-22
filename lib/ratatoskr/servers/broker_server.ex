defmodule Ratatoskr.Servers.BrokerServer do
  @moduledoc """
  Broker server that coordinates topic management and provides
  a central point for system-wide operations.

  This server acts as a coordinator but delegates actual business
  logic to the use cases layer.
  """

  use GenServer
  require Logger

  alias Ratatoskr.UseCases.ManageTopics

  # Dependency injection configuration
  @deps %{
    registry: Ratatoskr.Infrastructure.Registry.ProcessRegistry,
    # No persistence in MVP
    storage: nil,
    metrics: Ratatoskr.Infrastructure.Telemetry.MetricsCollector,
    event_publisher: nil
  }

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new topic through the broker.
  """
  def create_topic(topic_name, opts \\ []) do
    GenServer.call(__MODULE__, {:create_topic, topic_name, opts})
  end

  @doc """
  Deletes a topic through the broker.
  """
  def delete_topic(topic_name) do
    GenServer.call(__MODULE__, {:delete_topic, topic_name})
  end

  @doc """
  Lists all topics through the broker.
  """
  def list_topics do
    GenServer.call(__MODULE__, :list_topics)
  end

  @doc """
  Checks if a topic exists.
  """
  def topic_exists?(topic_name) do
    GenServer.call(__MODULE__, {:topic_exists, topic_name})
  end

  @doc """
  Gets statistics for a topic.
  """
  def stats(topic_name) do
    GenServer.call(__MODULE__, {:stats, topic_name})
  end

  @doc """
  Gets broker health information.
  """
  def health_check do
    GenServer.call(__MODULE__, :health_check)
  end

  # GenServer implementation

  @impl true
  def init(_opts) do
    Logger.info("Starting Ratatoskr Broker Server")

    state = %{
      started_at: DateTime.utc_now(),
      topic_count: 0,
      total_messages: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:create_topic, topic_name, opts}, _from, state) do
    Logger.debug("Broker creating topic: #{topic_name}")

    case ManageTopics.create(topic_name, opts, @deps) do
      {:ok, _topic_pid} ->
        new_state = %{state | topic_count: state.topic_count + 1}
        {:reply, {:ok, topic_name}, new_state}

      {:error, reason} = error ->
        Logger.warning("Failed to create topic #{topic_name}: #{reason}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:delete_topic, topic_name}, _from, state) do
    Logger.debug("Broker deleting topic: #{topic_name}")

    case ManageTopics.delete(topic_name, @deps) do
      :ok ->
        new_state = %{state | topic_count: max(0, state.topic_count - 1)}
        {:reply, :ok, new_state}

      {:error, reason} = error ->
        Logger.warning("Failed to delete topic #{topic_name}: #{reason}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:list_topics, _from, state) do
    case ManageTopics.list(@deps) do
      {:ok, topics} ->
        {:reply, {:ok, topics}, state}

      {:error, reason} = error ->
        Logger.warning("Failed to list topics: #{reason}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:topic_exists, topic_name}, _from, state) do
    exists = ManageTopics.exists?(topic_name, @deps)
    {:reply, exists, state}
  end

  @impl true
  def handle_call({:stats, topic_name}, _from, state) do
    case ManageTopics.stats(topic_name, @deps) do
      {:ok, stats} ->
        {:reply, {:ok, stats}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    uptime_seconds = DateTime.diff(DateTime.utc_now(), state.started_at, :second)

    health = %{
      status: :healthy,
      uptime_seconds: uptime_seconds,
      topic_count: state.topic_count,
      total_messages: state.total_messages,
      memory_usage: get_memory_usage(),
      process_count: length(Process.list())
    }

    {:reply, {:ok, health}, state}
  end

  @impl true
  def handle_info({:message_published, _topic_name}, state) do
    # Update message count when notified of new messages
    new_state = %{state | total_messages: state.total_messages + 1}
    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Broker received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp get_memory_usage do
    :erlang.memory(:total)
  end
end
