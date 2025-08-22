defmodule Ratatoskr do
  @moduledoc """
  Ratatoskr - A lightweight message broker built with Elixir/OTP.

  Named after the Norse mythology squirrel who carries messages between
  the eagle at the top of Yggdrasil and the dragon at its roots.

  This is the main public API that provides a clean interface to the
  message broker functionality using clean architecture principles.

  ## Usage

      # Start the broker (automatically started with the application)
      Application.ensure_all_started(:ratatoskr)
      
      # Create a topic
      {:ok, topic} = Ratatoskr.create_topic("orders")
      
      # Subscribe to messages
      {:ok, subscription_ref} = Ratatoskr.subscribe("orders")
      
      # Publish a message
      {:ok, message_id} = Ratatoskr.publish("orders", %{id: 123, amount: 99.90})
      
      # Unsubscribe
      :ok = Ratatoskr.unsubscribe("orders", subscription_ref)
      
      # List topics
      {:ok, topics} = Ratatoskr.list_topics()
      
      # Delete topic
      :ok = Ratatoskr.delete_topic("orders")
  """

  alias Ratatoskr.Infrastructure.DI.Container
  alias Ratatoskr.Servers.BrokerServer
  alias Ratatoskr.UseCases.{PublishMessage, SubscribeToTopic}

  @type topic_name :: String.t()
  @type message_id :: String.t()
  @type subscription_ref :: reference()

  @doc """
  Creates a new topic.

  ## Examples

      {:ok, "orders"} = Ratatoskr.create_topic("orders")
      {:error, :topic_already_exists} = Ratatoskr.create_topic("orders")
  """
  @spec create_topic(topic_name()) :: {:ok, topic_name()} | {:error, term()}
  def create_topic(topic_name) when is_binary(topic_name) do
    BrokerServer.create_topic(topic_name)
  end

  @doc """
  Deletes an existing topic and stops all its subscribers.

  ## Examples

      :ok = Ratatoskr.delete_topic("orders")
      {:error, :topic_not_found} = Ratatoskr.delete_topic("nonexistent")
  """
  @spec delete_topic(topic_name()) :: :ok | {:error, term()}
  def delete_topic(topic_name) when is_binary(topic_name) do
    BrokerServer.delete_topic(topic_name)
  end

  @doc """
  Lists all active topics.

  ## Examples

      {:ok, ["orders", "users"]} = Ratatoskr.list_topics()
  """
  @spec list_topics() :: {:ok, list(topic_name())}
  def list_topics do
    BrokerServer.list_topics()
  end

  @doc """
  Publishes a message to a topic.

  ## Examples

      {:ok, message_id} = Ratatoskr.publish("orders", %{id: 123})
      {:error, :topic_not_found} = Ratatoskr.publish("nonexistent", %{})
  """
  @spec publish(topic_name(), term(), keyword()) :: {:ok, message_id()} | {:error, term()}
  def publish(topic_name, payload, opts \\ []) when is_binary(topic_name) do
    # Extract metadata from opts for backward compatibility
    metadata = Keyword.get(opts, :metadata, %{})
    publish_opts = Keyword.put(opts, :metadata, metadata)

    PublishMessage.execute(topic_name, payload, publish_opts, Container.deps())
  end

  @doc """
  Subscribes the calling process to receive messages from a topic.

  The subscriber process will receive messages in the format:
  `{:message, %Ratatoskr.Core.Message{}}`

  ## Examples

      {:ok, ref} = Ratatoskr.subscribe("orders")
      receive do
        {:message, message} -> 
          IO.inspect(message.payload)
      end
  """
  @spec subscribe(topic_name()) :: {:ok, subscription_ref()} | {:error, term()}
  def subscribe(topic_name) when is_binary(topic_name) do
    subscribe(topic_name, self())
  end

  @doc """
  Subscribes a specific process to receive messages from a topic.
  """
  @spec subscribe(topic_name(), pid()) :: {:ok, subscription_ref()} | {:error, term()}
  def subscribe(topic_name, subscriber_pid)
      when is_binary(topic_name) and is_pid(subscriber_pid) do
    SubscribeToTopic.execute(topic_name, subscriber_pid, [], Container.deps())
  end

  @doc """
  Unsubscribes from a topic using the subscription reference.

  ## Examples

      {:ok, ref} = Ratatoskr.subscribe("orders")
      :ok = Ratatoskr.unsubscribe("orders", ref)
  """
  @spec unsubscribe(topic_name(), subscription_ref()) :: :ok | {:error, term()}
  def unsubscribe(topic_name, subscription_ref)
      when is_binary(topic_name) and is_reference(subscription_ref) do
    SubscribeToTopic.unsubscribe(topic_name, subscription_ref, Container.deps())
  end

  @doc """
  Gets statistics for a topic.

  ## Examples

      {:ok, %{topic: "orders", message_count: 42, subscriber_count: 3}} = Ratatoskr.stats("orders")
  """
  @spec stats(topic_name()) :: {:ok, map()} | {:error, term()}
  def stats(topic_name) when is_binary(topic_name) do
    BrokerServer.stats(topic_name)
  end

  @doc """
  Checks if a topic exists.

  ## Examples

      true = Ratatoskr.topic_exists?("orders")
      false = Ratatoskr.topic_exists?("nonexistent")
  """
  @spec topic_exists?(topic_name()) :: boolean()
  def topic_exists?(topic_name) when is_binary(topic_name) do
    BrokerServer.topic_exists?(topic_name)
  end

  @doc """
  Gets broker health information.
  """
  @spec health() :: {:ok, map()} | {:error, term()}
  def health do
    BrokerServer.health_check()
  end
end
