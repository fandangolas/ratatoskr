defmodule Ratatoskr.UseCases.PublishMessageBatch do
  @moduledoc """
  Optimized batch message publishing use case.

  Provides high-performance batch publishing by:
  1. Grouping messages by topic for efficient routing
  2. Batch processing messages within each topic
  3. Concurrent processing across different topics
  4. Reduced GenServer call overhead
  """

  alias Ratatoskr.Core.Logic.Message
  alias Ratatoskr.UseCases.ManageTopics

  @type batch_message :: %{
          topic: String.t(),
          payload: binary(),
          metadata: map()
        }

  @type batch_result :: %{
          message_id: String.t(),
          topic: String.t(),
          success: boolean(),
          error: String.t() | nil
        }

  @type deps :: %{
          registry: module(),
          storage: module() | nil,
          metrics: module() | nil,
          event_publisher: module() | nil
        }

  @doc """
  Publishes multiple messages in an optimized batch.

  ## Parameters
  - messages: List of batch_message structs
  - deps: Dependency injection map

  ## Returns
  - {:ok, [batch_result]} on success
  - {:error, reason} if batch processing fails
  """
  @spec execute([batch_message()], deps()) :: {:ok, [batch_result()]} | {:error, any()}
  def execute(messages, deps) when is_list(messages) do
    # Group messages by topic for efficient processing
    grouped_messages = Enum.group_by(messages, & &1.topic)

    # Process each topic's messages in parallel
    tasks =
      for {topic, topic_messages} <- grouped_messages do
        Task.async(fn ->
          publish_to_topic_batch(topic, topic_messages, deps)
        end)
      end

    # Wait for all tasks and flatten results
    results =
      tasks
      # 30 second timeout
      |> Task.await_many(30_000)
      |> List.flatten()

    {:ok, results}
  rescue
    error ->
      {:error, error}
  end

  @spec publish_to_topic_batch(String.t(), [batch_message()], deps()) :: [batch_result()]
  defp publish_to_topic_batch(topic, messages, deps) do
    case find_topic_process(topic, deps.registry) do
      {:ok, topic_pid} ->
        # Batch call to topic process
        publish_batch_to_topic(topic_pid, topic, messages, deps)

      {:error, :not_found} ->
        # Create topic and then publish
        case create_topic_and_publish(topic, messages, deps) do
          {:ok, results} ->
            results

          {:error, _reason} ->
            # Return error results for all messages in this topic
            Enum.map(messages, fn msg ->
              %{
                message_id: "",
                topic: msg.topic,
                success: false,
                error: "topic_creation_failed"
              }
            end)
        end
    end
  end

  @spec publish_batch_to_topic(pid(), String.t(), [batch_message()], deps()) :: [batch_result()]
  defp publish_batch_to_topic(topic_pid, topic, messages, _deps) do
    case validate_and_convert_messages(topic, messages) do
      {:ok, message_structs} ->
        publish_validated_batch(topic_pid, message_structs, messages)

      {:error, message_results} ->
        handle_partial_message_failures(message_results, messages)
    end
  end

  @spec validate_and_convert_messages(String.t(), [batch_message()]) ::
          {:ok, [Message.t()]} | {:error, list()}
  defp validate_and_convert_messages(topic, messages) do
    message_results =
      Enum.map(messages, fn msg ->
        case Message.new(topic, msg.payload, metadata: msg.metadata) do
          {:ok, message} -> {:ok, message}
          {:error, reason} -> {:error, reason}
        end
      end)

    case Enum.split_with(message_results, fn
           {:ok, _} -> true
           {:error, _} -> false
         end) do
      {successful_messages, []} ->
        message_structs = Enum.map(successful_messages, fn {:ok, msg} -> msg end)
        {:ok, message_structs}

      _ ->
        {:error, message_results}
    end
  end

  @spec publish_validated_batch(pid(), [Message.t()], [batch_message()]) :: [batch_result()]
  defp publish_validated_batch(topic_pid, message_structs, original_messages) do
    case GenServer.call(topic_pid, {:publish_batch, message_structs}, 30_000) do
      {:ok, message_ids} when is_list(message_ids) ->
        process_successful_response(message_ids, original_messages)

      {:error, reason} ->
        create_error_results_for_all(original_messages, to_string(reason))
    end
  catch
    :exit, {:timeout, _} ->
      create_error_results_for_all(original_messages, "genserver_timeout")

    :exit, {:noproc, _} ->
      create_error_results_for_all(original_messages, "topic_process_not_found")

    kind, reason ->
      create_error_results_for_all(original_messages, "#{kind}:#{inspect(reason)}")
  end

  @spec process_successful_response(list(), [batch_message()]) :: [batch_result()]
  defp process_successful_response(message_ids, original_messages) do
    case List.first(message_ids) do
      id when is_binary(id) ->
        # Regular TopicServer response: list of message IDs
        message_ids
        |> Enum.zip(original_messages)
        |> Enum.map(fn {message_id, original_msg} ->
          %{
            message_id: message_id,
            topic: original_msg.topic,
            success: true,
            error: nil
          }
        end)

      %{message_id: _, success: _, error: _} ->
        # PartitionedTopic response: list of result maps
        Enum.map(message_ids, fn result ->
          %{
            message_id: result.message_id || "",
            topic: result[:topic] || result.original_message.topic,
            success: result.success,
            error: result.error
          }
        end)

      _ ->
        # Unknown format
        create_error_results_for_all(original_messages, "unknown_response_format")
    end
  end

  @spec create_error_results_for_all([batch_message()], String.t()) :: [batch_result()]
  defp create_error_results_for_all(messages, error_message) do
    Enum.map(messages, fn msg ->
      %{
        message_id: "",
        topic: msg.topic,
        success: false,
        error: error_message
      }
    end)
  end

  @spec handle_partial_message_failures(list(), [batch_message()]) :: [batch_result()]
  defp handle_partial_message_failures(message_results, original_messages) do
    Enum.zip(message_results, original_messages)
    |> Enum.map(fn {result, original_msg} ->
      case result do
        {:ok, _message} ->
          %{
            message_id: "",
            topic: original_msg.topic,
            success: false,
            error: "batch_partial_failure"
          }

        {:error, reason} ->
          %{
            message_id: "",
            topic: original_msg.topic,
            success: false,
            error: to_string(reason)
          }
      end
    end)
  end

  @spec create_topic_and_publish(String.t(), [batch_message()], deps()) ::
          {:ok, [batch_result()]} | {:error, any()}
  defp create_topic_and_publish(topic, messages, deps) do
    # Use existing topic creation logic
    case ManageTopics.create(topic, [], deps) do
      {:ok, topic_pid} ->
        results = publish_batch_to_topic(topic_pid, topic, messages, deps)
        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec find_topic_process(String.t(), module()) :: {:ok, pid()} | {:error, :not_found}
  defp find_topic_process(topic, registry) do
    # Use registry dependency directly for tests compatibility
    case registry.lookup_topic(topic) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          {:error, :topic_process_dead}
        end

      {:ok, not_pid} ->
        {:error, {:invalid_pid, not_pid}}

      {:error, :not_found} ->
        {:error, :not_found}

      other ->
        {:error, {:unexpected_response, other}}
    end
  rescue
    error -> {:error, {:registry_error, error}}
  end
end
