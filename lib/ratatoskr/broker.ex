defmodule Ratatoskr.Broker do
  @moduledoc """
  Broker coordinator that manages topic lifecycle and provides the main interface
  for topic operations like create, delete, and list.
  """

  use GenServer
  require Logger
  alias Ratatoskr.Topic.Server, as: TopicServer

  @type state :: %{
    topics: MapSet.t(String.t())
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Creates a new topic.
  """
  @spec create_topic(String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_topic(topic_name) do
    GenServer.call(__MODULE__, {:create_topic, topic_name})
  end

  @doc """
  Deletes an existing topic.
  """
  @spec delete_topic(String.t()) :: :ok | {:error, term()}
  def delete_topic(topic_name) do
    GenServer.call(__MODULE__, {:delete_topic, topic_name})
  end

  @doc """
  Lists all active topics.
  """
  @spec list_topics() :: {:ok, list(String.t())}
  def list_topics do
    GenServer.call(__MODULE__, :list_topics)
  end

  @doc """
  Checks if a topic exists.
  """
  @spec topic_exists?(String.t()) :: boolean()
  def topic_exists?(topic_name) do
    case Registry.lookup(Ratatoskr.Registry, topic_name) do
      [] -> false
      [_] -> true
    end
  end

  # GenServer Callbacks

  @impl true
  def init(:ok) do
    Logger.info("Starting Ratatoskr Broker")
    {:ok, %{topics: MapSet.new()}}
  end

  @impl true
  def handle_call({:create_topic, topic_name}, _from, state) do
    if MapSet.member?(state.topics, topic_name) do
      {:reply, {:error, :topic_already_exists}, state}
    else
      case start_topic_server(topic_name) do
        {:ok, _pid} ->
          new_state = %{state | topics: MapSet.put(state.topics, topic_name)}
          Logger.info("Created topic: #{topic_name}")
          {:reply, {:ok, topic_name}, new_state}
        
        {:error, reason} ->
          Logger.error("Failed to create topic #{topic_name}: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:delete_topic, topic_name}, _from, state) do
    if MapSet.member?(state.topics, topic_name) do
      case stop_topic_server(topic_name) do
        :ok ->
          new_state = %{state | topics: MapSet.delete(state.topics, topic_name)}
          Logger.info("Deleted topic: #{topic_name}")
          {:reply, :ok, new_state}
        
        {:error, reason} ->
          Logger.error("Failed to delete topic #{topic_name}: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :topic_not_found}, state}
    end
  end

  def handle_call(:list_topics, _from, state) do
    topics = MapSet.to_list(state.topics)
    {:reply, {:ok, topics}, state}
  end

  # Private Functions

  defp start_topic_server(topic_name) do
    child_spec = %{
      id: {TopicServer, topic_name},
      start: {TopicServer, :start_link, [topic_name]},
      restart: :transient
    }
    
    DynamicSupervisor.start_child(Ratatoskr.Topic.Supervisor, child_spec)
  end

  defp stop_topic_server(topic_name) do
    case Registry.lookup(Ratatoskr.Registry, topic_name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Ratatoskr.Topic.Supervisor, pid)
      [] ->
        {:error, :topic_not_found}
    end
  end
end