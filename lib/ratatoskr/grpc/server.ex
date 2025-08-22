defmodule Ratatoskr.Grpc.Server do
  @moduledoc """
  gRPC server implementation for Ratatoskr message broker.

  Implements the MessageBroker service defined in ratatoskr.proto,
  bridging gRPC calls to the internal Elixir API.
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
    UnsubscribeResponse,
    Message
  }

  @doc """
  Creates a new topic.
  """
  @spec create_topic(CreateTopicRequest.t(), GRPC.Server.Stream.t()) :: CreateTopicResponse.t()
  def create_topic(request, _stream) do
    Logger.debug("gRPC CreateTopic: #{request.name}")

    case Ratatoskr.create_topic(request.name) do
      {:ok, topic} ->
        %CreateTopicResponse{
          topic: topic,
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

    case Ratatoskr.delete_topic(request.name) do
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

    case Ratatoskr.list_topics() do
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

    exists = Ratatoskr.topic_exists?(request.name)
    %TopicExistsResponse{exists: exists}
  end

  @doc """
  Gets statistics for a topic.
  """
  @spec get_stats(GetStatsRequest.t(), GRPC.Server.Stream.t()) :: GetStatsResponse.t()
  def get_stats(request, _stream) do
    Logger.debug("gRPC GetStats: #{request.topic}")

    case Ratatoskr.stats(request.topic) do
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

    # Convert protobuf metadata map to Elixir map
    metadata = request.metadata |> Enum.into(%{})

    # Create message payload - for gRPC we'll accept the binary payload directly
    payload = %{
      data: request.payload,
      metadata: metadata
    }

    case Ratatoskr.publish(request.topic, payload) do
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
        metadata = msg.metadata |> Enum.into(%{})
        payload = %{data: msg.payload, metadata: metadata}

        # Use the topic from individual message, not from the batch request
        topic = if msg.topic != "", do: msg.topic, else: request.topic

        case Ratatoskr.publish(topic, payload) do
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

    # First check if topic exists
    unless Ratatoskr.topic_exists?(request.topic) do
      GRPC.Server.send_reply(stream, {:error, "Topic does not exist: #{request.topic}"})
      :ok
    else
      handle_valid_subscription(request, stream)
    end
  end

  defp handle_valid_subscription(request, stream) do
    # Subscribe to the topic with a custom handler that sends to gRPC stream
    case Ratatoskr.subscribe(request.topic) do
      {:ok, subscription_ref} ->
        Logger.debug("gRPC subscription established: #{subscription_ref}")

        # Start a process to handle messages and forward them to the gRPC stream
        spawn_link(fn -> handle_subscription(stream, subscription_ref, request.topic) end)

        # Keep the stream alive by monitoring the subscription
        :timer.sleep(:infinity)

      {:error, reason} ->
        Logger.error("gRPC subscription failed: #{reason}")
        GRPC.Server.send_reply(stream, {:error, to_string(reason)})
    end
  end

  @doc """
  Unsubscribes from a topic.
  """
  @spec unsubscribe(UnsubscribeRequest.t(), GRPC.Server.Stream.t()) :: UnsubscribeResponse.t()
  def unsubscribe(request, _stream) do
    Logger.debug("gRPC Unsubscribe from: #{request.topic}, ref: #{request.subscription_ref}")

    # Convert string representation back to reference
    case parse_subscription_ref(request.subscription_ref) do
      {:ok, ref} ->
        case Ratatoskr.unsubscribe(request.topic, ref) do
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

      {:error, reason} ->
        %UnsubscribeResponse{
          success: false,
          error: "Invalid subscription reference: #{reason}"
        }
    end
  end

  # Private functions

  defp handle_subscription(stream, subscription_ref, topic) do
    receive do
      {:message, message} ->
        # Convert internal message to gRPC message
        grpc_message = %Message{
          id: message.id,
          topic: topic,
          payload: get_message_payload(message.payload),
          metadata: convert_metadata(message.metadata),
          timestamp: message.timestamp
        }

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

  defp get_message_payload(payload) when is_map(payload) do
    # If payload has binary data, use that; otherwise encode as JSON
    case Map.get(payload, :data) do
      data when is_binary(data) -> data
      _ -> Jason.encode!(payload) |> :erlang.term_to_binary()
    end
  end

  defp get_message_payload(payload) when is_binary(payload), do: payload

  defp get_message_payload(payload) do
    # Fallback: encode as JSON then to binary
    Jason.encode!(payload) |> :erlang.term_to_binary()
  end

  defp convert_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> Enum.into(%{})
  end

  defp convert_metadata(_), do: %{}

  defp parse_subscription_ref(ref_string) when is_binary(ref_string) do
    try do
      # Try to decode base64 encoded reference term
      decoded = Base.decode64!(ref_string)
      ref = :erlang.binary_to_term(decoded)

      if is_reference(ref) do
        {:ok, ref}
      else
        {:error, "not a reference"}
      end
    rescue
      _ -> {:error, "invalid format"}
    end
  end
end
