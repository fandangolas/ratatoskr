defmodule Ratatoskr.Interfaces.Grpc.Server do
  @moduledoc """
  gRPC server interface adapter for Ratatoskr message broker.

  Implements the MessageBroker service defined in ratatoskr.proto,
  adapting gRPC calls to use cases and converting between protocol types.
  """

  use GRPC.Server, service: Ratatoskr.Grpc.MessageBroker.Service
  require Logger

  alias Ratatoskr.Grpc.{
    CreateTopicRequest,
    CreateTopicResponse,
    DeleteTopicRequest,
    DeleteTopicResponse,
    ListTopicsRequest,
    ListTopicsResponse,
    TopicExistsRequest,
    TopicExistsResponse,
    GetStatsRequest,
    GetStatsResponse,
    PublishRequest,
    PublishResponse,
    PublishBatchRequest,
    PublishBatchResponse,
    SubscribeRequest,
    UnsubscribeRequest,
    UnsubscribeResponse
  }

  alias Ratatoskr.UseCases.{PublishMessage, SubscribeToTopic, ManageTopics}
  alias Ratatoskr.Interfaces.Grpc.Mappers
  alias Ratatoskr.Core.Subscription

  # Dependency injection - will be configured at startup
  @deps %{
    registry: Ratatoskr.Infrastructure.Registry.ProcessRegistry,
    # No persistence in MVP
    storage: nil,
    metrics: Ratatoskr.Infrastructure.Telemetry.MetricsCollector,
    event_publisher: nil
  }

  @doc """
  Creates a new topic.
  """
  @spec create_topic(CreateTopicRequest.t(), GRPC.Server.Stream.t()) :: CreateTopicResponse.t()
  def create_topic(request, _stream) do
    Logger.debug("gRPC CreateTopic: #{request.name}")

    case ManageTopics.create(request.name, [], @deps) do
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

    case ManageTopics.delete(request.name, @deps) do
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

    case ManageTopics.list(@deps) do
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

    exists = ManageTopics.exists?(request.name, @deps)
    %TopicExistsResponse{exists: exists}
  end

  @doc """
  Gets statistics for a topic.
  """
  @spec get_stats(GetStatsRequest.t(), GRPC.Server.Stream.t()) :: GetStatsResponse.t()
  def get_stats(request, _stream) do
    Logger.debug("gRPC GetStats: #{request.topic}")

    case ManageTopics.stats(request.topic, @deps) do
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
  Publishes a single message to a topic.
  """
  @spec publish(PublishRequest.t(), GRPC.Server.Stream.t()) :: PublishResponse.t()
  def publish(request, _stream) do
    Logger.debug("gRPC Publish to: #{request.topic}")

    # Convert gRPC request to domain format
    metadata = Mappers.grpc_metadata_to_map(request.metadata)

    opts = [
      metadata: metadata
    ]

    case PublishMessage.execute(request.topic, request.payload, opts, @deps) do
      {:ok, message_id} ->
        %PublishResponse{
          message_id: message_id,
          timestamp: :os.system_time(:millisecond),
          success: true,
          error: ""
        }

      {:error, reason} ->
        %PublishResponse{
          message_id: "",
          timestamp: :os.system_time(:millisecond),
          success: false,
          error: to_string(reason)
        }
    end
  end

  @doc """
  Publishes multiple messages to a topic in a batch.
  """
  @spec publish_batch(PublishBatchRequest.t(), GRPC.Server.Stream.t()) :: PublishBatchResponse.t()
  def publish_batch(request, _stream) do
    Logger.debug("gRPC PublishBatch to: #{request.topic}, count: #{length(request.messages)}")

    results =
      Enum.map(request.messages, fn msg ->
        metadata = Mappers.grpc_metadata_to_map(msg.metadata)
        topic = if msg.topic != "", do: msg.topic, else: request.topic

        opts = [
          metadata: metadata
        ]

        case PublishMessage.execute(topic, msg.payload, opts, @deps) do
          {:ok, message_id} ->
            %PublishResponse{
              message_id: message_id,
              timestamp: :os.system_time(:millisecond),
              success: true,
              error: ""
            }

          {:error, reason} ->
            %PublishResponse{
              message_id: "",
              timestamp: :os.system_time(:millisecond),
              success: false,
              error: to_string(reason)
            }
        end
      end)

    success_count = Enum.count(results, & &1.success)
    error_count = length(results) - success_count

    %PublishBatchResponse{
      results: results,
      success_count: success_count,
      error_count: error_count
    }
  end

  @doc """
  Subscribes to a topic and streams messages back to the client.
  """
  @spec subscribe(SubscribeRequest.t(), GRPC.Server.Stream.t()) :: any()
  def subscribe(request, stream) do
    Logger.debug("gRPC Subscribe to: #{request.topic}, subscriber: #{request.subscriber_id}")

    # Check if topic exists first
    unless ManageTopics.exists?(request.topic, @deps) do
      GRPC.Server.send_reply(stream, {:error, "Topic does not exist: #{request.topic}"})
      :ok
    else
      handle_valid_subscription(request, stream)
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

      case SubscribeToTopic.unsubscribe(request.topic, ref, @deps) do
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

    case SubscribeToTopic.execute(request.topic, self(), opts, @deps) do
      {:ok, subscription_ref} ->
        Logger.debug("gRPC subscription established: #{inspect(subscription_ref)}")

        # Start a process to handle messages and forward them to the gRPC stream
        spawn_link(fn -> handle_subscription(stream, subscription_ref, request.topic) end)

        # Keep the stream alive by monitoring the subscription
        :timer.sleep(:infinity)

      {:error, reason} ->
        Logger.error("gRPC subscription failed: #{reason}")
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
