defmodule Ratatoskr do
  @moduledoc """
  Ratatoskr - A lightweight message broker built with Elixir/OTP.
  
  Named after the Norse mythology squirrel who carries messages between
  the eagle at the top of Yggdrasil and the dragon at its roots.
  
  ## Usage
  
      # Start the broker (automatically started with the application)
      Application.ensure_all_started(:ratatoskr)
      
      # Create a topic
      {:ok, topic} = Ratatoskr.create_topic("orders")
      
      # Subscribe to messages
      {:ok, subscription_ref} = Ratatoskr.subscribe("orders", fn message ->
        IO.inspect(message)
        :ack
      end)
      
      # Publish a message
      {:ok, message_id} = Ratatoskr.publish("orders", %{id: 123, amount: 99.90})
      
      # Unsubscribe
      :ok = Ratatoskr.unsubscribe("orders", subscription_ref)
      
      # List topics
      {:ok, topics} = Ratatoskr.list_topics()
      
      # Delete topic
      :ok = Ratatoskr.delete_topic("orders")
  """

  alias Ratatoskr.Broker
  alias Ratatoskr.Topic.Server, as: TopicServer

  @type topic_name :: String.t()
  @type message_id :: String.t()
  @type subscription_ref :: reference()
  @type consumer_function :: (Ratatoskr.Message.t() -> :ack | :nack)

  @doc """
  Creates a new topic.
  
  ## Examples
  
      {:ok, "orders"} = Ratatoskr.create_topic("orders")
      {:error, :topic_already_exists} = Ratatoskr.create_topic("orders")
  """
  @spec create_topic(topic_name()) :: {:ok, topic_name()} | {:error, term()}
  def create_topic(topic_name) when is_binary(topic_name) do
    Broker.create_topic(topic_name)
  end

  @doc """
  Deletes an existing topic and stops all its subscribers.
  
  ## Examples
  
      :ok = Ratatoskr.delete_topic("orders")
      {:error, :topic_not_found} = Ratatoskr.delete_topic("nonexistent")
  """
  @spec delete_topic(topic_name()) :: :ok | {:error, term()}
  def delete_topic(topic_name) when is_binary(topic_name) do
    Broker.delete_topic(topic_name)
  end

  @doc """
  Lists all active topics.
  
  ## Examples
  
      {:ok, ["orders", "users"]} = Ratatoskr.list_topics()
  """
  @spec list_topics() :: {:ok, list(topic_name())}
  def list_topics do
    Broker.list_topics()
  end

  @doc """
  Publishes a message to a topic.
  
  ## Examples
  
      {:ok, message_id} = Ratatoskr.publish("orders", %{id: 123})
      {:error, :topic_not_found} = Ratatoskr.publish("nonexistent", %{})
  """
  @spec publish(topic_name(), term(), map()) :: {:ok, message_id()} | {:error, term()}
  def publish(topic_name, payload, metadata \\ %{}) when is_binary(topic_name) do
    TopicServer.publish(topic_name, payload, metadata)
  end

  @doc """
  Subscribes the calling process to receive messages from a topic.
  
  The subscriber process will receive messages in the format:
  `{:message, %Ratatoskr.Message{}}`
  
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
  def subscribe(topic_name, subscriber_pid) when is_binary(topic_name) and is_pid(subscriber_pid) do
    TopicServer.subscribe(topic_name, subscriber_pid)
  end

  @doc """
  Unsubscribes from a topic using the subscription reference.
  
  ## Examples
  
      {:ok, ref} = Ratatoskr.subscribe("orders")
      :ok = Ratatoskr.unsubscribe("orders", ref)
  """
  @spec unsubscribe(topic_name(), subscription_ref()) :: :ok | {:error, term()}
  def unsubscribe(topic_name, subscription_ref) when is_binary(topic_name) and is_reference(subscription_ref) do
    TopicServer.unsubscribe(topic_name, subscription_ref)
  end

  @doc """
  Gets statistics for a topic.
  
  ## Examples
  
      {:ok, %{topic: "orders", message_count: 42, subscriber_count: 3}} = Ratatoskr.stats("orders")
  """
  @spec stats(topic_name()) :: {:ok, map()} | {:error, term()}
  def stats(topic_name) when is_binary(topic_name) do
    TopicServer.stats(topic_name)
  end

  @doc """
  Checks if a topic exists.
  
  ## Examples
  
      true = Ratatoskr.topic_exists?("orders")
      false = Ratatoskr.topic_exists?("nonexistent")
  """
  @spec topic_exists?(topic_name()) :: boolean()
  def topic_exists?(topic_name) when is_binary(topic_name) do
    Broker.topic_exists?(topic_name)
  end
end
