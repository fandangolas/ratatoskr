defmodule Ratatoskr.UseCases.ManageTopics do
  @moduledoc """
  Use case for topic lifecycle management.

  Handles topic creation, deletion, listing, and configuration updates.
  """

  alias Ratatoskr.Core.{Topic}

  @type deps :: %{
          registry: module(),
          storage: module() | nil,
          metrics: module() | nil,
          event_publisher: module() | nil
        }

  @type result :: {:ok, term()} | {:error, reason :: atom()}

  @doc """
  Creates a new topic.
  """
  @spec create(String.t(), keyword(), deps()) :: {:ok, pid()} | {:error, reason :: atom()}
  def create(topic_name, opts \\ [], deps) do
    with {:ok, topic} <- Topic.new(topic_name, opts),
         :ok <- validate_topic_not_exists(topic_name, deps),
         {:ok, topic_pid} <- start_topic_server(topic),
         :ok <- register_topic(topic_name, topic_pid, deps),
         :ok <- initialize_storage(topic, deps),
         :ok <- emit_creation_metrics(topic, deps),
         :ok <- publish_creation_event(topic, deps) do
      {:ok, topic_pid}
    else
      {:error, reason} = error ->
        emit_error_metrics(:create_topic, topic_name, reason, deps)
        error
    end
  end

  @doc """
  Deletes an existing topic.
  """
  @spec delete(String.t(), deps()) :: :ok | {:error, reason :: atom()}
  def delete(topic_name, deps) do
    with {:ok, topic_pid} <- find_topic(topic_name, deps),
         :ok <- stop_topic_server(topic_pid),
         :ok <- unregister_topic(topic_name, deps),
         :ok <- cleanup_storage(topic_name, deps),
         :ok <- emit_deletion_metrics(topic_name, deps),
         :ok <- publish_deletion_event(topic_name, deps) do
      :ok
    else
      {:error, reason} = error ->
        emit_error_metrics(:delete_topic, topic_name, reason, deps)
        error
    end
  end

  @doc """
  Lists all existing topics.
  """
  @spec list(deps()) :: {:ok, [String.t()]} | {:error, reason :: atom()}
  def list(%{registry: registry}) do
    registry.list_topics()
  end

  @doc """
  Checks if a topic exists.
  """
  @spec exists?(String.t(), deps()) :: boolean()
  def exists?(topic_name, %{registry: registry}) do
    case registry.lookup_topic(topic_name) do
      {:ok, _pid} -> true
      {:error, :not_found} -> false
    end
  end

  @doc """
  Gets statistics for a topic.
  """
  @spec stats(String.t(), deps()) :: {:ok, map()} | {:error, reason :: atom()}
  def stats(topic_name, deps) do
    with {:ok, topic_pid} <- find_topic(topic_name, deps) do
      try do
        case GenServer.call(topic_pid, :stats) do
          {:ok, stats} -> {:ok, stats}
          {:error, reason} -> {:error, reason}
        end
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, {:noproc, _} -> {:error, :topic_not_found}
      end
    end
  end

  @doc """
  Updates topic configuration.
  """
  @spec update_config(String.t(), map(), deps()) :: :ok | {:error, reason :: atom()}
  def update_config(topic_name, new_config, deps) do
    with {:ok, topic_pid} <- find_topic(topic_name, deps),
         :ok <- apply_config_update(topic_pid, new_config),
         :ok <- emit_config_update_metrics(topic_name, deps) do
      :ok
    else
      {:error, reason} = error ->
        emit_error_metrics(:update_config, topic_name, reason, deps)
        error
    end
  end

  # Private functions

  defp validate_topic_not_exists(topic_name, %{registry: registry}) do
    case registry.lookup_topic(topic_name) do
      {:ok, _pid} -> {:error, :topic_already_exists}
      {:error, :not_found} -> :ok
    end
  end

  defp start_topic_server(topic) do
    # Delegate to the servers layer
    case DynamicSupervisor.start_child(
           Ratatoskr.Servers.TopicSupervisor,
           {Ratatoskr.Servers.TopicServer, topic}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  defp register_topic(topic_name, topic_pid, %{registry: registry}) do
    registry.register_topic(topic_name, topic_pid)
  end

  defp find_topic(topic_name, %{registry: registry}) do
    registry.lookup_topic(topic_name)
  end

  defp stop_topic_server(topic_pid) do
    try do
      DynamicSupervisor.terminate_child(Ratatoskr.Servers.TopicSupervisor, topic_pid)
      :ok
    catch
      _, _ -> {:error, :stop_failed}
    end
  end

  defp unregister_topic(topic_name, %{registry: registry}) do
    registry.unregister_topic(topic_name)
  end

  defp initialize_storage(topic, %{storage: storage}) when not is_nil(storage) do
    # Initialize storage for the topic if persistence is enabled
    case storage.get_topic_stats(topic.name) do
      # Already exists
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        # Create storage structures for topic
        :ok

      {:error, reason} ->
        {:error, {:storage_init_failed, reason}}
    end
  end

  defp initialize_storage(_topic, _deps), do: :ok

  defp cleanup_storage(topic_name, %{storage: storage}) when not is_nil(storage) do
    case storage.delete_messages(topic_name, :all) do
      :ok -> :ok
      {:error, reason} -> {:error, {:storage_cleanup_failed, reason}}
    end
  end

  defp cleanup_storage(_topic_name, _deps), do: :ok

  defp apply_config_update(topic_pid, new_config) do
    try do
      case GenServer.call(topic_pid, {:update_config, new_config}) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, {:noproc, _} -> {:error, :topic_not_found}
    end
  end

  defp emit_creation_metrics(_topic, %{metrics: metrics}) when not is_nil(metrics) do
    metrics.increment_counter(:topics_created_total, 1, %{})
    metrics.set_gauge(:active_topics, 1, %{})

    :ok
  rescue
    _ -> :ok
  end

  defp emit_creation_metrics(_topic, _deps), do: :ok

  defp emit_deletion_metrics(_topic_name, %{metrics: metrics}) when not is_nil(metrics) do
    metrics.increment_counter(:topics_deleted_total, 1, %{})
    metrics.set_gauge(:active_topics, -1, %{})

    :ok
  rescue
    _ -> :ok
  end

  defp emit_deletion_metrics(_topic_name, _deps), do: :ok

  defp emit_config_update_metrics(topic_name, %{metrics: metrics}) when not is_nil(metrics) do
    metrics.increment_counter(:topic_config_updates_total, 1, %{topic: topic_name})

    :ok
  rescue
    _ -> :ok
  end

  defp emit_config_update_metrics(_topic_name, _deps), do: :ok

  defp emit_error_metrics(operation, topic_name, reason, %{metrics: metrics})
       when not is_nil(metrics) do
    metrics.increment_counter(:topic_operation_errors_total, 1, %{
      operation: to_string(operation),
      topic: topic_name,
      reason: to_string(reason)
    })

    :ok
  rescue
    _ -> :ok
  end

  defp emit_error_metrics(_operation, _topic_name, _reason, _deps), do: :ok

  defp publish_creation_event(topic, %{event_publisher: publisher}) when not is_nil(publisher) do
    event =
      {:topic_created,
       %{
         topic_name: topic.name,
         partition_count: topic.partition_count,
         timestamp: topic.created_at
       }}

    publisher.publish_event(event, %{source: __MODULE__})
    :ok
  rescue
    _ -> :ok
  end

  defp publish_creation_event(_topic, _deps), do: :ok

  defp publish_deletion_event(topic_name, %{event_publisher: publisher})
       when not is_nil(publisher) do
    event =
      {:topic_deleted,
       %{
         topic_name: topic_name,
         timestamp: DateTime.utc_now()
       }}

    publisher.publish_event(event, %{source: __MODULE__})
    :ok
  rescue
    _ -> :ok
  end

  defp publish_deletion_event(_topic_name, _deps), do: :ok
end
