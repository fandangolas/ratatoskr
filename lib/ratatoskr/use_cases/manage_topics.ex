defmodule Ratatoskr.UseCases.ManageTopics do
  @moduledoc """
  Use case for managing topic lifecycle operations.

  Handles topic creation, deletion, and configuration management.
  """

  alias Ratatoskr.Core.Logic.Topic
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
  def create(topic_name, opts \\ [], %{registry: registry} = _deps) do
    allow_existing = Keyword.get(opts, :allow_existing, false)

    with {:ok, topic} <- Topic.new(topic_name, opts),
         {:ok, topic_pid} <- start_topic_server(topic),
         :ok <- register_topic(topic_name, topic_pid, registry) do
      {:ok, topic_pid}
    else
      {:error, {:already_started, pid}} ->
        if allow_existing do
          {:ok, pid}
        else
          {:error, :already_exists}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Deletes a topic.
  """
  @spec delete(String.t(), deps()) :: :ok | {:error, reason :: atom()}
  def delete(topic_name, %{registry: registry} = _deps) do
    case registry.lookup_topic(topic_name) do
      {:ok, topic_pid} ->
        :ok = stop_topic_server(topic_pid)
        registry.unregister_topic(topic_name)

      {:error, :not_found} ->
        {:error, :topic_not_found}
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
        Ratatoskr.Servers.TopicServer.get_stats(topic_pid)

      {:error, :not_found} ->
        {:error, :topic_not_found}
    end
  end

  # Private functions

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
