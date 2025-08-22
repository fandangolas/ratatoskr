defmodule Ratatoskr.Servers.TopicServer do
  @moduledoc """
  GenServer managing a single topic's message queue and subscribers.

  This server handles the OTP process concerns and delegates business
  logic to the domain and use cases layers.
  """

  use GenServer
  require Logger

  alias Ratatoskr.Core.{Topic, Message, Subscription}

  @type state :: %{
          topic: Topic.t(),
          messages: :queue.queue(),
          subscribers: %{reference() => Subscription.t()},
          stats: map()
        }

  # Note: @deps removed as it's not used in this server implementation
  # Dependency injection happens at the use case layer

  # Public API

  @doc """
  Starts a new topic server.
  """
  @spec start_link(Topic.t()) :: GenServer.on_start()
  def start_link(%Topic{} = topic) do
    GenServer.start_link(__MODULE__, topic, name: via_tuple(topic.name))
  end

  @doc """
  Publishes a message to this topic server directly.
  """
  @spec publish_to_server(pid(), Message.t()) :: {:ok, String.t()} | {:error, term()}
  def publish_to_server(pid, %Message{} = message) do
    GenServer.call(pid, {:publish, message})
  end

  @doc """
  Subscribes to this topic server directly.
  """
  @spec subscribe_to_server(pid(), Subscription.t()) :: {:ok, reference()} | {:error, term()}
  def subscribe_to_server(pid, %Subscription{} = subscription) do
    GenServer.call(pid, {:subscribe, subscription})
  end

  @doc """
  Unsubscribes from this topic server.
  """
  @spec unsubscribe_from_server(pid(), reference()) :: :ok | {:error, term()}
  def unsubscribe_from_server(pid, subscription_ref) do
    GenServer.call(pid, {:unsubscribe, subscription_ref})
  end

  @doc """
  Gets topic statistics.
  """
  @spec get_stats(pid()) :: {:ok, map()} | {:error, term()}
  def get_stats(pid) do
    GenServer.call(pid, :stats)
  end

  @doc """
  Health check for the topic server.
  """
  @spec health_check(pid()) :: :ok | {:error, term()}
  def health_check(pid) do
    GenServer.call(pid, :health_check)
  end

  # GenServer implementation

  @impl true
  def init(%Topic{} = topic) do
    Logger.info("Starting topic server: #{topic.name}")

    state = %{
      topic: topic,
      messages: :queue.new(),
      subscribers: %{},
      stats: Topic.stats_template(topic)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:publish, %Message{} = message}, _from, state) do
    Logger.debug("Publishing message to topic: #{state.topic.name}")

    # Add message to queue
    new_messages = :queue.in(message, state.messages)

    # Deliver to all active subscribers
    active_subscribers = filter_active_subscribers(state.subscribers)
    delivered_count = deliver_to_subscribers(message, active_subscribers)

    # Update statistics
    new_stats = %{
      state.stats
      | message_count: state.stats.message_count + 1,
        last_message_at: message.timestamp
    }

    new_state = %{
      state
      | messages: new_messages,
        subscribers: active_subscribers,
        stats: new_stats
    }

    Logger.debug("Message delivered to #{delivered_count} subscribers")
    {:reply, {:ok, message.id}, new_state}
  end

  @impl true
  def handle_call({:subscribe, %Subscription{} = subscription}, _from, state) do
    Logger.debug("Adding subscription to topic: #{state.topic.name}")

    # Check if we can accept more subscribers
    current_count = map_size(state.subscribers)

    if Topic.can_add_subscriber?(state.topic, current_count) do
      # Monitor the subscriber process
      Process.monitor(subscription.subscriber_pid)

      # Add to subscribers map
      new_subscribers = Map.put(state.subscribers, subscription.id, subscription)

      # Update stats
      new_stats = %{state.stats | subscriber_count: current_count + 1}

      new_state = %{state | subscribers: new_subscribers, stats: new_stats}

      {:reply, {:ok, subscription.id}, new_state}
    else
      {:reply, {:error, :max_subscribers_reached}, state}
    end
  end

  @impl true
  def handle_call({:unsubscribe, subscription_ref}, _from, state) do
    case Map.pop(state.subscribers, subscription_ref) do
      {nil, _} ->
        {:reply, {:error, :subscription_not_found}, state}

      {_subscription, new_subscribers} ->
        new_stats = %{state.stats | subscriber_count: state.stats.subscriber_count - 1}

        new_state = %{state | subscribers: new_subscribers, stats: new_stats}

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, {:ok, state.stats}, state}
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    # Simple health check - if we can respond, we're healthy
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:can_add_subscriber, _subscription}, _from, state) do
    current_count = map_size(state.subscribers)
    can_add = Topic.can_add_subscriber?(state.topic, current_count)

    if can_add do
      {:reply, :ok, state}
    else
      {:reply, {:error, :max_subscribers_reached}, state}
    end
  end

  @impl true
  def handle_call({:update_config, new_config}, _from, state) do
    case Topic.update_config(state.topic, new_config) do
      {:ok, updated_topic} ->
        new_state = %{state | topic: updated_topic}
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Clean up dead subscriber
    Logger.debug("Cleaning up dead subscriber: #{inspect(pid)}")

    new_subscribers =
      state.subscribers
      |> Enum.reject(fn {_ref, subscription} ->
        subscription.subscriber_pid == pid
      end)
      |> Enum.into(%{})

    removed_count = map_size(state.subscribers) - map_size(new_subscribers)

    new_stats = %{state.stats | subscriber_count: state.stats.subscriber_count - removed_count}

    new_state = %{state | subscribers: new_subscribers, stats: new_stats}

    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Topic server received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp via_tuple(topic_name) do
    {:via, Registry, {Ratatoskr.Registry, topic_name}}
  end

  defp filter_active_subscribers(subscribers) do
    subscribers
    |> Enum.filter(fn {_ref, subscription} ->
      Subscription.active?(subscription)
    end)
    |> Enum.into(%{})
  end

  defp deliver_to_subscribers(message, subscribers) do
    delivered_count =
      subscribers
      |> Enum.map(fn {_ref, subscription} ->
        if Subscription.should_deliver?(subscription, message) do
          send(subscription.subscriber_pid, {:message, message})
          1
        else
          0
        end
      end)
      |> Enum.sum()

    delivered_count
  end
end
