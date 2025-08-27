defmodule Ratatoskr.UseCases.PublishPartitionedMessage do
  @moduledoc """
  Use case for publishing messages to partitioned topics with high throughput.

  This use case extends the basic message publishing to support Kafka-style
  partitioning for parallel processing and improved performance. It integrates
  with both the batching system and partition management.

  Features:
  - Automatic partition routing based on partition keys
  - Integration with intelligent batching per partition
  - Load balancing across partitions
  - Maintains message ordering within partitions
  - Fallback to single-partition for non-partitioned topics
  """

  alias Ratatoskr.Core.Logic.Message
  alias Ratatoskr.Infrastructure.Partitioning.PartitionedTopic
  alias Ratatoskr.UseCases.PublishMessage

  @type deps :: %{
          registry: module(),
          storage: module() | nil,
          metrics: module() | nil,
          event_publisher: module() | nil
        }

  @type result ::
          {:ok, message_id :: String.t(), partition_id :: non_neg_integer()}
          | {:error, reason :: atom()}

  @doc """
  Publishes a message to a partitioned topic.

  ## Parameters
  - topic_name: The name of the topic to publish to
  - payload: The message payload  
  - opts: Publishing options
    - :metadata - Additional message metadata
    - :partition_key - Key for partition routing (overrides default extraction)
    - :persistence - Whether to persist the message
  - deps: Dependency injection map

  ## Returns
  - {:ok, message_id, partition_id} on success
  - {:error, reason} on failure
  """
  @spec execute(String.t(), term(), keyword(), deps()) :: result()
  def execute(topic_name, payload, opts \\ [], deps) do
    partition_key = Keyword.get(opts, :partition_key)

    # Check if topic uses partitioning
    case is_partitioned_topic?(topic_name, deps) do
      true ->
        publish_to_partitioned_topic(topic_name, payload, partition_key, opts, deps)

      false ->
        # Fallback to single-partition publishing
        case PublishMessage.execute(topic_name, payload, opts, deps) do
          # Single partition = partition 0
          {:ok, message_id} -> {:ok, message_id, 0}
          error -> error
        end
    end
  end

  @doc """
  Publishes multiple messages to partitioned topics in batch.

  ## Parameters
  - messages: List of message maps with :topic, :payload, :partition_key (optional)
  - deps: Dependency injection map

  ## Returns
  - {:ok, [result_map]} with results for each message
  - {:error, reason} on batch processing failure
  """
  @spec execute_batch([map()], deps()) :: {:ok, [map()]} | {:error, any()}
  def execute_batch(messages, deps) when is_list(messages) do
    # Group messages by topic for efficient processing
    grouped_messages = Enum.group_by(messages, & &1.topic)

    # Process each topic in parallel
    tasks =
      for {topic_name, topic_messages} <- grouped_messages do
        Task.async(fn ->
          case is_partitioned_topic?(topic_name, deps) do
            true ->
              publish_batch_to_partitioned_topic(topic_name, topic_messages, deps)

            false ->
              # Use existing batch publishing for non-partitioned topics
              fallback_batch_messages =
                Enum.map(topic_messages, fn msg ->
                  %{
                    topic: msg.topic,
                    payload: msg.payload,
                    metadata: Map.get(msg, :metadata, %{})
                  }
                end)

              case Ratatoskr.UseCases.PublishMessageBatch.execute(fallback_batch_messages, deps) do
                {:ok, batch_results} ->
                  Enum.map(batch_results, fn result ->
                    # Add partition_id for consistency
                    %{result | partition_id: 0}
                  end)

                {:error, reason} ->
                  Enum.map(topic_messages, fn msg ->
                    %{
                      message_id: "",
                      topic: msg.topic,
                      partition_id: 0,
                      success: false,
                      error: to_string(reason)
                    }
                  end)
              end
          end
        end)
      end

    # Wait for all tasks and flatten results
    results =
      tasks
      |> Task.await_many(30_000)
      |> List.flatten()

    {:ok, results}
  rescue
    error ->
      {:error, error}
  end

  ## Private Functions

  defp is_partitioned_topic?(topic_name, _deps) do
    # Check if partitioning is enabled globally
    partitioning_config = Application.get_env(:ratatoskr, :partitioning, [])
    partitioning_enabled = Keyword.get(partitioning_config, :enable_partitioning, false)

    if partitioning_enabled do
      # Check if this specific topic exists as a partitioned topic
      case GenServer.whereis(
             {:via, Registry, {Ratatoskr.Registry, {:partitioned_topic, topic_name}}}
           ) do
        pid when is_pid(pid) -> true
        nil -> false
      end
    else
      false
    end
  end

  defp publish_to_partitioned_topic(topic_name, payload, partition_key, opts, deps) do
    # Create message with partition key
    message_opts = Keyword.put(opts, :partition_key, partition_key)

    case Message.new(topic_name, payload, message_opts) do
      {:ok, message} ->
        # Use partitioned topic for publishing
        case PartitionedTopic.publish_message(topic_name, message, partition_key) do
          {:ok, message_id, partition_id} ->
            # Emit metrics and events
            emit_partitioned_metrics(message, partition_id, deps)
            publish_partitioned_domain_event(message, partition_id, deps)

            {:ok, message_id, partition_id}

          error ->
            emit_error_metrics(topic_name, error, deps)
            error
        end

      error ->
        error
    end
  end

  defp publish_batch_to_partitioned_topic(topic_name, messages, _deps) do
    # Convert messages to proper format with Message structs
    processed_messages =
      Enum.map(messages, fn msg ->
        partition_key = Map.get(msg, :partition_key)
        metadata = Map.get(msg, :metadata, %{})

        case Message.new(topic_name, msg.payload,
               metadata: metadata,
               partition_key: partition_key
             ) do
          {:ok, message} ->
            %{
              message: message,
              partition_key: partition_key,
              original: msg
            }

          {:error, reason} ->
            %{
              message: nil,
              partition_key: partition_key,
              original: msg,
              error: reason
            }
        end
      end)

    # Separate valid and invalid messages
    {valid_messages, invalid_messages} =
      Enum.split_with(processed_messages, fn msg -> msg.message != nil end)

    # Publish valid messages to partitioned topic
    valid_results =
      if length(valid_messages) > 0 do
        message_list = Enum.map(valid_messages, & &1.message)

        case PartitionedTopic.publish_batch(topic_name, message_list) do
          {:ok, batch_results} ->
            batch_results

          {:error, reason} ->
            Enum.map(valid_messages, fn _msg ->
              %{
                message_id: "",
                topic: topic_name,
                partition_id: nil,
                success: false,
                error: to_string(reason)
              }
            end)
        end
      else
        []
      end

    # Add error results for invalid messages
    invalid_results =
      Enum.map(invalid_messages, fn msg ->
        %{
          message_id: "",
          topic: topic_name,
          partition_id: nil,
          success: false,
          error: to_string(msg.error)
        }
      end)

    valid_results ++ invalid_results
  end

  defp emit_partitioned_metrics(message, partition_id, %{metrics: metrics})
       when not is_nil(metrics) do
    message_size = Message.size_bytes(message)

    metrics.increment_counter(:partitioned_messages_published_total, 1, %{
      topic: message.topic,
      partition: partition_id
    })

    metrics.observe_histogram(:partitioned_message_size_bytes, message_size, %{
      topic: message.topic,
      partition: partition_id
    })

    :ok
  rescue
    _ -> :ok
  end

  defp emit_partitioned_metrics(_message, _partition_id, _deps), do: :ok

  defp emit_error_metrics(topic_name, reason, %{metrics: metrics}) when not is_nil(metrics) do
    metrics.increment_counter(:partitioned_messages_published_errors_total, 1, %{
      topic: topic_name,
      reason: to_string(reason)
    })

    :ok
  rescue
    _ -> :ok
  end

  defp emit_error_metrics(_topic_name, _reason, _deps), do: :ok

  defp publish_partitioned_domain_event(message, partition_id, %{event_publisher: publisher})
       when not is_nil(publisher) do
    event =
      {:partitioned_message_published,
       %{
         message_id: message.id,
         topic: message.topic,
         partition_id: partition_id,
         timestamp: message.timestamp,
         size_bytes: Message.size_bytes(message)
       }}

    publisher.publish_event(event, %{source: __MODULE__})
    :ok
  rescue
    _ -> :ok
  end

  defp publish_partitioned_domain_event(_message, _partition_id, _deps), do: :ok
end
