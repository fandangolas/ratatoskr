defmodule Ratatoskr.Interfaces.Grpc.Server do
  @moduledoc """
  gRPC server interface adapter for Ratatoskr message broker.

  Implements the MessageBroker service defined in ratatoskr.proto,
  adapting gRPC calls to use cases and converting between protocol types.
  """

  use GRPC.Server, service: Ratatoskr.Grpc.MessageBroker.Service
  require Logger
  
  alias UUID

  alias Ratatoskr.Grpc.{
    CreateTopicRequest,
    CreateTopicResponse,
    DeleteTopicRequest,
    DeleteTopicResponse,
    GetStatsRequest,
    GetStatsResponse,
    ListTopicsRequest,
    ListTopicsResponse,
    PublishBatchRequest,
    PublishBatchResponse,
    PublishRequest,
    PublishResponse,
    SubscribeRequest,
    TopicExistsRequest,
    TopicExistsResponse,
    UnsubscribeRequest,
    UnsubscribeResponse
  }

  alias Ratatoskr.Core.Logic.Subscription
  alias Ratatoskr.Infrastructure.Batching.BatchedPublisher
  alias Ratatoskr.Infrastructure.DI.Container
  alias Ratatoskr.Infrastructure.Monitoring.MetricsEndpoint
  alias Ratatoskr.Interfaces.Grpc.Mappers
  alias Ratatoskr.UseCases.{ManageTopics, SubscribeToTopic}

  @doc """
  Creates a new topic.
  """
  @spec create_topic(CreateTopicRequest.t(), GRPC.Server.Stream.t()) :: CreateTopicResponse.t()
  def create_topic(request, _stream) do
    Logger.debug("gRPC CreateTopic: #{request.name}")

    case ManageTopics.create(request.name, [], Container.deps()) do
      {:ok, _topic_pid} ->
        %CreateTopicResponse{
          topic: request.name,
          created: true,
          error: ""
        }

      {:error, reason} ->
        %CreateTopicResponse{
          topic: request.name,
          created: false,
          error: to_string(reason)
        }
    end
  end

  @doc """
  Deletes an existing topic.
  """
  @spec delete_topic(DeleteTopicRequest.t(), GRPC.Server.Stream.t()) :: DeleteTopicResponse.t()
  def delete_topic(request, _stream) do
    Logger.debug("gRPC DeleteTopic: #{request.name}")

    case ManageTopics.delete(request.name, Container.deps()) do
      :ok ->
        %DeleteTopicResponse{
          success: true,
          error: ""
        }

      {:error, reason} ->
        %DeleteTopicResponse{
          success: false,
          error: to_string(reason)
        }
    end
  end

  @doc """
  Lists all existing topics.
  """
  @spec list_topics(ListTopicsRequest.t(), GRPC.Server.Stream.t()) :: ListTopicsResponse.t()
  def list_topics(_request, _stream) do
    Logger.debug("gRPC ListTopics")

    case ManageTopics.list(Container.deps()) do
      {:ok, topics} ->
        %ListTopicsResponse{topics: topics}

      {:error, _reason} ->
        %ListTopicsResponse{topics: []}
    end
  end

  @doc """
  Checks if a topic exists.
  """
  @spec topic_exists(TopicExistsRequest.t(), GRPC.Server.Stream.t()) :: TopicExistsResponse.t()
  def topic_exists(request, _stream) do
    Logger.debug("gRPC TopicExists: #{request.name}")

    exists = ManageTopics.exists?(request.name, Container.deps())
    %TopicExistsResponse{exists: exists}
  end

  @doc """
  Gets statistics for a topic.
  """
  @spec get_stats(GetStatsRequest.t(), GRPC.Server.Stream.t()) :: GetStatsResponse.t()
  def get_stats(request, _stream) do
    Logger.debug("gRPC GetStats: #{request.topic}")

    case ManageTopics.stats(request.topic, Container.deps()) do
      {:ok, stats} ->
        %GetStatsResponse{
          topic: stats.topic,
          message_count: stats.message_count,
          subscriber_count: stats.subscriber_count,
          error: ""
        }

      {:error, reason} ->
        %GetStatsResponse{
          topic: request.topic,
          message_count: 0,
          subscriber_count: 0,
          error: to_string(reason)
        }
    end
  end

  @doc """
  Publishes a single message to a topic using intelligent batching.
  """
  @spec publish(PublishRequest.t(), GRPC.Server.Stream.t()) :: PublishResponse.t()
  def publish(request, _stream) do
    Logger.debug("gRPC Publish to: #{request.topic}")

    # Convert gRPC request to domain format
    metadata = Mappers.grpc_metadata_to_map(request.metadata)

    # Use batched publishing for better performance
    message_id = UUID.uuid4()
    
    case BatchedPublisher.publish_async(request.topic, request.payload, metadata) do
      :ok ->
        # Increment real metrics
        MetricsEndpoint.increment_counter(:messages_published, 1)
        MetricsEndpoint.increment_counter(:grpc_publish_success, 1)
        
        %PublishResponse{
          message_id: message_id,
          timestamp: :os.system_time(:millisecond),
          success: true,
          error: ""
        }

      {:error, reason} ->
        # Increment error metrics
        MetricsEndpoint.increment_counter(:grpc_publish_error, 1)
        
        %PublishResponse{
          message_id: "",
          timestamp: :os.system_time(:millisecond),
          success: false,
          error: to_string(reason)
        }
    end
  end

  @doc """
  Publishes multiple messages to a topic in a batch using intelligent batching.
  """
  @spec publish_batch(PublishBatchRequest.t(), GRPC.Server.Stream.t()) :: PublishBatchResponse.t()
  def publish_batch(request, _stream) do
    Logger.debug("gRPC PublishBatch to: #{request.topic}, count: #{length(request.messages)}")

    # Convert gRPC messages to batch_message format with pre-generated IDs
    batch_messages =
      Enum.map(request.messages, fn msg ->
        metadata = Mappers.grpc_metadata_to_map(msg.metadata)
        topic = if msg.topic != "", do: msg.topic, else: request.topic
        message_id = UUID.uuid4()

        %{
          topic: topic,
          payload: msg.payload,
          metadata: Map.put(metadata, :message_id, message_id)
        }
      end)

    # Use the high-performance batched publisher
    case BatchedPublisher.publish_batch_async(batch_messages) do
      :ok ->
        # Generate response for all messages (they're queued for processing)
        results =
          Enum.map(batch_messages, fn msg ->
            %PublishResponse{
              message_id: msg.metadata.message_id,
              timestamp: :os.system_time(:millisecond),
              success: true,
              error: ""
            }
          end)

        success_count = length(results)
        
        # Increment real batch metrics
        MetricsEndpoint.increment_counter(:messages_published, success_count)
        MetricsEndpoint.increment_counter(:grpc_publish_batch_success, 1)

        %PublishBatchResponse{
          results: results,
          success_count: success_count,
          error_count: 0
        }

      {:error, reason} ->
        # Increment batch error metrics
        MetricsEndpoint.increment_counter(:grpc_publish_batch_error, 1)
        
        # Return error for all messages
        results =
          Enum.map(request.messages, fn _msg ->
            %PublishResponse{
              message_id: "",
              timestamp: :os.system_time(:millisecond),
              success: false,
              error: to_string(reason)
            }
          end)

        %PublishBatchResponse{
          results: results,
          success_count: 0,
          error_count: length(results)
        }
    end
  end

  @doc """
  Subscribes to a topic and streams messages back to the client.
  """
  @spec subscribe(SubscribeRequest.t(), GRPC.Server.Stream.t()) :: any()
  def subscribe(request, stream) do
    Logger.debug("gRPC Subscribe to: #{request.topic}, subscriber: #{request.subscriber_id}")

    # Check if topic exists first
    if ManageTopics.exists?(request.topic, Container.deps()) do
      handle_valid_subscription(request, stream)
    else
      GRPC.Server.send_reply(stream, {:error, "Topic does not exist: #{request.topic}"})
      :ok
    end
  end

  @doc """
  Unsubscribes from a topic.
  """
  @spec unsubscribe(UnsubscribeRequest.t(), GRPC.Server.Stream.t()) :: UnsubscribeResponse.t()
  def unsubscribe(request, _stream) do
    Logger.debug("gRPC Unsubscribe from: #{request.topic}, ref: #{request.subscription_ref}")

    # Parse subscription reference from gRPC format
    try do
      ref = Subscription.deserialize_reference(request.subscription_ref)

      case SubscribeToTopic.unsubscribe(request.topic, ref, Container.deps()) do
        :ok ->
          %UnsubscribeResponse{
            success: true,
            error: ""
          }

        {:error, reason} ->
          %UnsubscribeResponse{
            success: false,
            error: to_string(reason)
          }
      end
    rescue
      ArgumentError ->
        %UnsubscribeResponse{
          success: false,
          error: "Invalid subscription reference"
        }
    end
  end

  # Private functions

  defp handle_valid_subscription(request, stream) do
    # Create a subscription through the use case
    opts = [
      subscriber_id: if(request.subscriber_id != "", do: request.subscriber_id, else: nil),
      metadata: %{grpc_stream: true}
    ]

    case SubscribeToTopic.execute(request.topic, self(), opts, Container.deps()) do
      {:ok, subscription_ref} ->
        Logger.debug("gRPC subscription established: #{inspect(subscription_ref)}")
        
        # Increment successful subscribe metrics
        MetricsEndpoint.increment_counter(:grpc_subscribe_success, 1)

        # Start a process to handle messages and forward them to the gRPC stream
        spawn_link(fn -> handle_subscription(stream, subscription_ref, request.topic) end)

        # Keep the stream alive by monitoring the subscription
        :timer.sleep(:infinity)

      {:error, reason} ->
        Logger.error("gRPC subscription failed: #{reason}")
        
        # Increment subscribe error metrics
        MetricsEndpoint.increment_counter(:grpc_subscribe_error, 1)
        
        GRPC.Server.send_reply(stream, {:error, to_string(reason)})
    end
  end

  defp handle_subscription(stream, subscription_ref, topic) do
    receive do
      {:message, message} ->
        # Convert domain message to gRPC message
        grpc_message = Mappers.domain_message_to_grpc(message, topic)

        # Send to gRPC stream
        GRPC.Server.send_reply(stream, grpc_message)
        
        # Increment message consumed counter
        MetricsEndpoint.increment_counter(:messages_consumed, 1)

        # Continue listening for more messages
        handle_subscription(stream, subscription_ref, topic)

      {:error, reason} ->
        Logger.error("Subscription error: #{reason}")
        GRPC.Server.send_reply(stream, {:error, to_string(reason)})

      other ->
        Logger.debug("Unexpected message in subscription: #{inspect(other)}")
        handle_subscription(stream, subscription_ref, topic)
    end
  end
end
