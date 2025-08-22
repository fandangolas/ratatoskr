defmodule Ratatoskr.UseCases.SubscribeToTopic do
  @moduledoc """
  Use case for subscribing to topics.

  Orchestrates the business workflow of topic subscription, including
  validation, topic discovery, subscriber registration, and delivery setup.
  """

  alias Ratatoskr.Core.{Subscription}

  @type deps :: %{
          registry: module(),
          metrics: module() | nil,
          event_publisher: module() | nil
        }

  @type result :: {:ok, reference()} | {:error, reason :: atom()}

  @doc """
  Subscribes a process to a topic.

  ## Parameters
  - topic_name: The name of the topic to subscribe to
  - subscriber_pid: The process that will receive messages
  - opts: Subscription options
    - :subscriber_id - Unique identifier for the subscriber
    - :partition - Specific partition to subscribe to (nil for all)
    - :filter - Function to filter messages
    - :metadata - Additional subscription metadata
  - deps: Dependency injection map

  ## Returns
  - {:ok, subscription_reference} on success
  - {:error, reason} on failure
  """
  @spec execute(String.t(), pid(), keyword(), deps()) :: result()
  def execute(topic_name, subscriber_pid, opts \\ [], deps) do
    with {:ok, subscription} <- create_subscription(topic_name, subscriber_pid, opts),
         {:ok, topic_pid} <- ensure_topic_exists(topic_name, deps),
         :ok <- validate_subscription_limits(topic_pid, subscription),
         :ok <- register_subscriber(topic_pid, subscription),
         :ok <- setup_monitoring(subscription),
         :ok <- emit_metrics(subscription, deps),
         :ok <- publish_domain_event(subscription, deps) do
      {:ok, subscription.id}
    else
      {:error, reason} = error ->
        emit_error_metrics(topic_name, reason, deps)
        error
    end
  end

  @doc """
  Unsubscribes from a topic.
  """
  @spec unsubscribe(String.t(), reference(), deps()) :: :ok | {:error, reason :: atom()}
  def unsubscribe(topic_name, subscription_ref, deps) do
    with {:ok, topic_pid} <- find_topic(topic_name, deps),
         :ok <- unregister_subscriber(topic_pid, subscription_ref),
         :ok <- emit_unsubscribe_metrics(topic_name, deps) do
      :ok
    end
  end

  # Private functions

  defp create_subscription(topic_name, subscriber_pid, opts) do
    Subscription.new(topic_name, subscriber_pid, opts)
  end

  defp ensure_topic_exists(topic_name, %{registry: registry}) do
    case registry.lookup_topic(topic_name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        {:error, :topic_not_found}
    end
  end

  defp find_topic(topic_name, %{registry: registry}) do
    registry.lookup_topic(topic_name)
  end

  defp validate_subscription_limits(topic_pid, subscription) do
    try do
      case GenServer.call(topic_pid, {:can_add_subscriber, subscription}) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, {:timeout, _} -> {:error, :topic_timeout}
      :exit, {:noproc, _} -> {:error, :topic_not_found}
    end
  end

  defp register_subscriber(topic_pid, subscription) do
    try do
      case GenServer.call(topic_pid, {:subscribe, subscription}) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, {:timeout, _} -> {:error, :subscription_timeout}
      :exit, {:noproc, _} -> {:error, :topic_not_found}
    end
  end

  defp unregister_subscriber(topic_pid, subscription_ref) do
    try do
      case GenServer.call(topic_pid, {:unsubscribe, subscription_ref}) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, {:timeout, _} -> {:error, :unsubscribe_timeout}
      :exit, {:noproc, _} -> {:error, :topic_not_found}
    end
  end

  defp setup_monitoring(subscription) do
    # Monitor the subscriber process to clean up on exit
    case Process.monitor(subscription.subscriber_pid) do
      ref when is_reference(ref) -> :ok
      _ -> {:error, :monitor_failed}
    end
  end

  defp emit_metrics(subscription, %{metrics: metrics}) when not is_nil(metrics) do
    metrics.increment_counter(:subscriptions_created_total, 1, %{topic: subscription.topic})
    metrics.set_gauge(:active_subscriptions, 1, %{topic: subscription.topic})

    :ok
  rescue
    _ -> :ok
  end

  defp emit_metrics(_subscription, _deps), do: :ok

  defp emit_error_metrics(topic_name, reason, %{metrics: metrics}) when not is_nil(metrics) do
    metrics.increment_counter(:subscription_errors_total, 1, %{
      topic: topic_name,
      reason: to_string(reason)
    })

    :ok
  rescue
    _ -> :ok
  end

  defp emit_error_metrics(_topic_name, _reason, _deps), do: :ok

  defp emit_unsubscribe_metrics(topic_name, %{metrics: metrics}) when not is_nil(metrics) do
    metrics.increment_counter(:subscriptions_removed_total, 1, %{topic: topic_name})
    metrics.set_gauge(:active_subscriptions, -1, %{topic: topic_name})

    :ok
  rescue
    _ -> :ok
  end

  defp emit_unsubscribe_metrics(_topic_name, _deps), do: :ok

  defp publish_domain_event(subscription, %{event_publisher: publisher})
       when not is_nil(publisher) do
    event =
      {:subscription_created,
       %{
         subscription_id: subscription.id,
         topic: subscription.topic,
         subscriber_id: subscription.subscriber_id,
         timestamp: subscription.created_at
       }}

    publisher.publish_event(event, %{source: __MODULE__})
    :ok
  rescue
    _ -> :ok
  end

  defp publish_domain_event(_subscription, _deps), do: :ok
end
