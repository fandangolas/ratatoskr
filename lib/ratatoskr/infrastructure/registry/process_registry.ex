defmodule Ratatoskr.Infrastructure.Registry.ProcessRegistry do
  @moduledoc """
  Process registry implementation using Elixir's built-in Registry.

  Provides topic discovery and process routing functionality.
  """

  @behaviour Ratatoskr.Core.Behaviours.Registry

  @registry_name Ratatoskr.Registry

  @doc """
  Starts the registry.
  """
  def start_link(_opts \\ []) do
    Registry.start_link(keys: :unique, name: @registry_name)
  end

  @doc """
  Child specification for supervision tree.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @impl true
  def register_topic(topic_name, pid) when is_binary(topic_name) and is_pid(pid) do
    case Registry.register(@registry_name, topic_name, %{}) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, :already_registered}
    end
  end

  @impl true
  def unregister_topic(topic_name) when is_binary(topic_name) do
    Registry.unregister(@registry_name, topic_name)
    :ok
  end

  @impl true
  def lookup_topic(topic_name) when is_binary(topic_name) do
    case Registry.lookup(@registry_name, topic_name) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def list_topics do
    topics =
      Registry.select(@registry_name, [{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.sort()

    {:ok, topics}
  end

  @doc """
  Gets the count of registered topics.
  """
  def topic_count do
    Registry.count(@registry_name)
  end

  @doc """
  Gets all topic registrations with their PIDs.
  """
  def all_registrations do
    Registry.select(@registry_name, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Checks if a topic is registered.
  """
  def registered?(topic_name) when is_binary(topic_name) do
    case lookup_topic(topic_name) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  end
end
