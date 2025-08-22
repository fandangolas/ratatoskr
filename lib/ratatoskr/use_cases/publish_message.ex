defmodule Ratatoskr.UseCases.PublishMessage do
  @moduledoc """
  Use case for publishing messages to topics.

  Orchestrates the business workflow of message publishing, including
  validation, routing, persistence, and delivery to subscribers.
  """

  alias Ratatoskr.Core.{Message}

  @type deps :: %{
          registry: module(),
          storage: module() | nil,
          metrics: module() | nil,
          event_publisher: module() | nil
        }

  @type result :: {:ok, message_id :: String.t()} | {:error, reason :: atom()}

  @doc """
  Publishes a message to a topic.

  ## Parameters
  - topic_name: The name of the topic to publish to
  - payload: The message payload
  - opts: Publishing options
    - :metadata - Additional message metadata
    - :partition_key - Key for partition routing
    - :persistence - Whether to persist the message (default: true if storage available)
  - deps: Dependency injection map

  ## Returns
  - {:ok, message_id} on success
  - {:error, reason} on failure
  """
  @spec execute(String.t(), term(), keyword(), deps()) :: result()
  def execute(topic_name, payload, opts \\ [], deps) do
    with {:ok, message} <- create_message(topic_name, payload, opts),
         {:ok, topic_pid} <- find_or_create_topic(topic_name, deps),
         :ok <- validate_topic_can_accept_message(topic_pid),
         :ok <- persist_message_if_enabled(message, deps),
         :ok <- deliver_to_topic(topic_pid, message),
         :ok <- emit_metrics(message, deps),
         :ok <- publish_domain_event(message, deps) do
      {:ok, message.id}
    else
      {:error, reason} = error ->
        emit_error_metrics(topic_name, reason, deps)
        error
    end
  end

  # Private functions

  defp create_message(topic_name, payload, opts) do
    Message.new(topic_name, payload, opts)
  end

  defp find_or_create_topic(topic_name, %{registry: registry}) when not is_nil(registry) do
    case registry.lookup_topic(topic_name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        # Delegate topic creation to ManageTopics use case
        Ratatoskr.UseCases.ManageTopics.create(topic_name, [], %{registry: registry})
    end
  end

  defp validate_topic_can_accept_message(topic_pid) do
    # Check if topic server is responsive and not overloaded
    try do
      case GenServer.call(topic_pid, :health_check, 1000) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, {:timeout, _} -> {:error, :topic_timeout}
      :exit, {:noproc, _} -> {:error, :topic_not_found}
    end
  end

  defp persist_message_if_enabled(message, %{storage: storage}) when not is_nil(storage) do
    case storage.persist_message(message.topic, message) do
      {:ok, _offset} -> :ok
      {:error, reason} -> {:error, {:persistence_failed, reason}}
    end
  end

  defp persist_message_if_enabled(_message, _deps), do: :ok

  defp deliver_to_topic(topic_pid, message) do
    try do
      case GenServer.call(topic_pid, {:publish, message}) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, {:timeout, _} -> {:error, :delivery_timeout}
      :exit, {:noproc, _} -> {:error, :topic_not_found}
    end
  end

  defp emit_metrics(message, %{metrics: metrics}) when not is_nil(metrics) do
    message_size = Message.size_bytes(message)

    metrics.increment_counter(:messages_published_total, 1, %{topic: message.topic})
    metrics.observe_histogram(:message_size_bytes, message_size, %{topic: message.topic})

    :ok
  rescue
    # Don't fail publishing due to metrics errors
    _ -> :ok
  end

  defp emit_metrics(_message, _deps), do: :ok

  defp emit_error_metrics(topic_name, reason, %{metrics: metrics}) when not is_nil(metrics) do
    metrics.increment_counter(:messages_published_errors_total, 1, %{
      topic: topic_name,
      reason: to_string(reason)
    })

    :ok
  rescue
    _ -> :ok
  end

  defp emit_error_metrics(_topic_name, _reason, _deps), do: :ok

  defp publish_domain_event(message, %{event_publisher: publisher}) when not is_nil(publisher) do
    event =
      {:message_published,
       %{
         message_id: message.id,
         topic: message.topic,
         timestamp: message.timestamp,
         size_bytes: Message.size_bytes(message)
       }}

    publisher.publish_event(event, %{source: __MODULE__})
    :ok
  rescue
    # Don't fail publishing due to event errors
    _ -> :ok
  end

  defp publish_domain_event(_message, _deps), do: :ok
end
