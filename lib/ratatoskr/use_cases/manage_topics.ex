defmodule Ratatoskr.UseCases.ManageTopics do
  @moduledoc """
  Use case for managing topic lifecycle operations.

  Handles topic creation, deletion, and configuration management.
  """

  alias Ratatoskr.Core.Logic.Topic
  alias Ratatoskr.Infrastructure.Cache.TopicCache
  alias Ratatoskr.Infrastructure.Partitioning.PartitionedTopic
  alias Ratatoskr.Servers.TopicServer

  @type deps :: %{
          registry: module()
        }

  @doc """
  Creates a new topic.

  Options:
  - :allow_existing - If true, returns {:ok, pid} for existing topics. If false, returns {:error, :already_exists} (default: false)
  """
  @spec create(String.t(), keyword(), deps()) :: {:ok, pid()} | {:error, reason :: atom()}
  def create(topic_name, opts \\ [], %{registry: registry} = deps) do
    allow_existing = Keyword.get(opts, :allow_existing, false)

    # Check if partitioning is enabled
    partitioning_config = Application.get_env(:ratatoskr, :partitioning, [])
    partitioning_enabled = Keyword.get(partitioning_config, :enable_partitioning, false)

    if partitioning_enabled do
      create_partitioned_topic(topic_name, opts, deps, allow_existing)
    else
      create_regular_topic(topic_name, opts, registry, allow_existing)
    end
  end

  @doc """
  Deletes a topic.
  """
  @spec delete(String.t(), deps()) :: :ok | {:error, reason :: atom()}
  def delete(topic_name, %{registry: registry} = _deps) do
    # Check if this is a partitioned topic
    partitioning_enabled =
      Application.get_env(:ratatoskr, :partitioning)[:enable_partitioning] || false

    if partitioning_enabled do
      # Try to find and stop partitioned topic first
      case GenServer.whereis(
             {:via, Registry, {Ratatoskr.Registry, {:partitioned_topic, topic_name}}}
           ) do
        pid when is_pid(pid) ->
          GenServer.stop(pid, :normal, 5000)
          registry.unregister_topic(topic_name)
          TopicCache.invalidate(topic_name)
          :ok

        nil ->
          # Fall back to regular topic deletion
          delete_regular_topic(topic_name, registry)
      end
    else
      delete_regular_topic(topic_name, registry)
    end
  end

  @doc """
  Lists all topics.
  """
  @spec list(deps()) :: {:ok, [String.t()]} | {:error, reason :: atom()}
  def list(%{registry: registry} = _deps) do
    registry.list_topics()
  end

  @doc """
  Checks if a topic exists.
  """
  @spec exists?(String.t(), deps()) :: boolean()
  def exists?(topic_name, %{registry: registry} = _deps) do
    case registry.lookup_topic(topic_name) do
      {:ok, _pid} -> true
      {:error, :not_found} -> false
    end
  end

  @doc """
  Gets topic statistics.
  """
  @spec stats(String.t(), deps()) :: {:ok, map()} | {:error, reason :: atom()}
  def stats(topic_name, %{registry: registry} = _deps) do
    case registry.lookup_topic(topic_name) do
      {:ok, topic_pid} ->
        TopicServer.get_stats(topic_pid)

      {:error, :not_found} ->
        {:error, :topic_not_found}
    end
  end

  # Private functions

  defp create_partitioned_topic(topic_name, opts, deps, allow_existing) do
    partition_count = Keyword.get(opts, :partition_count, 4)

    case PartitionedTopic.start_link(topic_name: topic_name, partition_count: partition_count) do
      {:ok, partitioned_topic_pid} ->
        # Register the partitioned topic
        case deps.registry.register_topic(topic_name, partitioned_topic_pid) do
          :ok ->
            TopicCache.put_topic_pid(
              topic_name,
              partitioned_topic_pid
            )

            {:ok, partitioned_topic_pid}

          {:error, :already_registered} ->
            if allow_existing do
              TopicCache.put_topic_pid(
                topic_name,
                partitioned_topic_pid
              )

              {:ok, partitioned_topic_pid}
            else
              {:error, :already_exists}
            end

          error ->
            error
        end

      {:error, {:already_started, pid}} ->
        if allow_existing do
          TopicCache.put_topic_pid(topic_name, pid)
          {:ok, pid}
        else
          {:error, :already_exists}
        end

      error ->
        error
    end
  end

  defp create_regular_topic(topic_name, opts, registry, allow_existing) do
    with {:ok, topic} <- Topic.new(topic_name, opts),
         {:ok, topic_pid} <- start_topic_server(topic),
         :ok <- register_topic(topic_name, topic_pid, registry) do
      # Cache the topic PID for optimized lookups
      TopicCache.put_topic_pid(topic_name, topic_pid)
      {:ok, topic_pid}
    else
      {:error, {:already_started, pid}} ->
        if allow_existing do
          # Cache existing PID too
          TopicCache.put_topic_pid(topic_name, pid)
          {:ok, pid}
        else
          {:error, :already_exists}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp delete_regular_topic(topic_name, registry) do
    case registry.lookup_topic(topic_name) do
      {:ok, topic_pid} ->
        :ok = stop_topic_server(topic_pid)
        :ok = registry.unregister_topic(topic_name)
        # Invalidate cache entry
        TopicCache.invalidate(topic_name)
        :ok

      {:error, :not_found} ->
        {:error, :topic_not_found}
    end
  end

  defp start_topic_server(topic) do
    case TopicServer.start_link(topic) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:error, {:already_started, pid}}
      error -> error
    end
  end

  defp register_topic(topic_name, topic_pid, registry) do
    case registry.register_topic(topic_name, topic_pid) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
      error -> error
    end
  end

  defp stop_topic_server(topic_pid) do
    if Process.alive?(topic_pid) do
      # GenServer.stop is synchronous and waits for the process to terminate
      GenServer.stop(topic_pid, :normal, 5000)
    else
      :ok
    end
  end
end
