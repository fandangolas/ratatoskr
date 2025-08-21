defmodule Ratatoskr.Topic.Server do
  @moduledoc """
  GenServer managing a single topic's message queue and subscribers.

  Each topic runs in its own GenServer process, providing fault isolation
  and natural backpressure. Messages are stored in an in-memory queue
  and pushed to all active subscribers.
  """

  use GenServer
  require Logger
  alias Ratatoskr.Message

  @type state :: %{
          name: String.t(),
          messages: :queue.queue(),
          subscribers: list({pid(), reference()})
        }

  @doc """
  Starts a new topic server.
  """
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(topic_name) do
    GenServer.start_link(__MODULE__, topic_name, name: via_tuple(topic_name))
  end

  @doc """
  Publishes a message to this topic.
  """
  @spec publish(String.t(), term(), map()) :: {:ok, String.t()} | {:error, term()}
  def publish(topic_name, payload, metadata \\ %{}) do
    try do
      GenServer.call(via_tuple(topic_name), {:publish, payload, metadata})
    catch
      :exit, {:noproc, _} ->
        {:error, :topic_not_found}
    end
  end

  @doc """
  Subscribes a process to receive messages from this topic.
  """
  @spec subscribe(String.t(), pid()) :: {:ok, reference()} | {:error, term()}
  def subscribe(topic_name, subscriber_pid) do
    try do
      GenServer.call(via_tuple(topic_name), {:subscribe, subscriber_pid})
    catch
      :exit, {:noproc, _} ->
        {:error, :topic_not_found}
    end
  end

  @doc """
  Unsubscribes a process from this topic.
  """
  @spec unsubscribe(String.t(), reference()) :: :ok | {:error, term()}
  def unsubscribe(topic_name, subscription_ref) do
    try do
      GenServer.call(via_tuple(topic_name), {:unsubscribe, subscription_ref})
    catch
      :exit, {:noproc, _} ->
        {:error, :topic_not_found}
    end
  end

  @doc """
  Gets topic statistics.
  """
  @spec stats(String.t()) :: {:ok, map()} | {:error, term()}
  def stats(topic_name) do
    try do
      GenServer.call(via_tuple(topic_name), :stats)
    catch
      :exit, {:noproc, _} ->
        {:error, :topic_not_found}
    end
  end

  # GenServer Callbacks

  @impl true
  def init(topic_name) do
    Logger.info("Starting topic: #{topic_name}")
    {:ok, initial_state(topic_name)}
  end

  @impl true
  def handle_call({:publish, payload, metadata}, _from, state) do
    message = Message.new(state.name, payload, metadata)
    new_state = add_message_and_notify(state, message)
    {:reply, {:ok, message.id}, new_state}
  end

  def handle_call({:subscribe, subscriber_pid}, _from, state) do
    monitor_ref = Process.monitor(subscriber_pid)
    new_subscribers = [{subscriber_pid, monitor_ref} | state.subscribers]
    new_state = %{state | subscribers: new_subscribers}

    Logger.debug("New subscriber for topic #{state.name}: #{inspect(subscriber_pid)}")
    {:reply, {:ok, monitor_ref}, new_state}
  end

  def handle_call({:unsubscribe, subscription_ref}, _from, state) do
    case Enum.find(state.subscribers, fn {_pid, ref} -> ref == subscription_ref end) do
      {_pid, ref} ->
        Process.demonitor(ref, [:flush])
        new_subscribers = Enum.reject(state.subscribers, fn {_pid, r} -> r == ref end)
        new_state = %{state | subscribers: new_subscribers}
        {:reply, :ok, new_state}

      nil ->
        {:reply, {:error, :subscription_not_found}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      topic: state.name,
      message_count: :queue.len(state.messages),
      subscriber_count: length(state.subscribers)
    }

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    Logger.debug("Subscriber #{inspect(pid)} down (#{inspect(reason)}) for topic #{state.name}")
    new_subscribers = Enum.reject(state.subscribers, fn {p, r} -> p == pid or r == ref end)
    new_state = %{state | subscribers: new_subscribers}
    {:noreply, new_state}
  end

  # Private Functions

  defp initial_state(name) do
    %{
      name: name,
      messages: :queue.new(),
      subscribers: []
    }
  end

  defp via_tuple(topic_name) do
    {:via, Registry, {Ratatoskr.Registry, topic_name}}
  end

  defp add_message_and_notify(state, message) do
    new_messages = :queue.in(message, state.messages)

    # Notify all subscribers
    Enum.each(state.subscribers, fn {pid, _ref} ->
      send(pid, {:message, message})
    end)

    %{state | messages: new_messages}
  end
end
