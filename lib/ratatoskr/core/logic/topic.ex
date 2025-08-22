defmodule Ratatoskr.Core.Logic.Topic do
  @moduledoc """
  Core domain entity representing a topic in the message broker.

  Contains business rules for topic management, subscription handling,
  and message routing logic.
  """

  alias Ratatoskr.Core.Logic.Message
  alias Ratatoskr.Core.Models.Topic, as: TopicModel

  @type t :: TopicModel.t()

  defstruct [
    :name,
    :created_at,
    partitions: 1,
    max_subscribers: 1000,
    config: %{}
  ]

  @doc """
  Creates a new topic with validation.
  """
  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, reason :: atom()}
  def new(name, opts \\ []) do
    with :ok <- validate_name(name),
         :ok <- validate_config(opts) do
      # Convert map config to keyword list for compatibility
      config_opts =
        case opts do
          %{} = map -> Map.to_list(map)
          list when is_list(list) -> list
          _ -> []
        end

      topic = %__MODULE__{
        name: name,
        partitions: Keyword.get(config_opts, :partitions, 1),
        max_subscribers: Keyword.get(config_opts, :max_subscribers, 1000),
        config: Map.merge(%{}, Map.new(config_opts)),
        created_at: DateTime.utc_now()
      }

      {:ok, topic}
    end
  end

  @doc """
  Creates a new topic, raising on validation errors.
  """
  @spec new!(String.t(), keyword()) :: t()
  def new!(name, opts \\ []) do
    case new(name, opts) do
      {:ok, topic} -> topic
      {:error, reason} -> raise ArgumentError, "Invalid topic: #{reason}"
    end
  end

  @doc """
  Validates if a topic name is acceptable according to business rules.
  """
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name) when is_binary(name) do
    validate_name(name) == :ok
  end

  def valid_name?(_), do: false

  @doc """
  Determines which partition a message should go to.
  """
  @spec route_message(t(), Message.t()) :: non_neg_integer()
  def route_message(%__MODULE__{} = topic, %Message{} = message) do
    key = message.partition_key || message.id
    :erlang.phash2(key, topic.partitions)
  end

  @doc """
  Checks if topic can accept a new subscriber.
  """
  @spec can_add_subscriber?(t(), current_count :: non_neg_integer()) :: boolean()
  def can_add_subscriber?(%__MODULE__{} = topic, current_count) do
    case topic.max_subscribers do
      :unlimited -> true
      max when is_integer(max) -> current_count < max
    end
  end

  @doc """
  Checks if a message should be retained based on topic retention policy.
  """
  @spec should_retain_message?(t(), Message.t()) :: boolean()
  def should_retain_message?(%__MODULE__{} = _topic, %Message{} = _message) do
    # For MVP, always retain messages (no retention policy yet)
    true
  end

  @doc """
  Updates topic configuration with validation.
  """
  @spec update_config(t(), map()) :: {:ok, t()} | {:error, reason :: atom()}
  def update_config(%__MODULE__{} = topic, new_config) do
    # Update actual topic fields if they are provided
    updated_topic = %{
      topic
      | partitions: Map.get(new_config, :partitions, topic.partitions),
        max_subscribers: Map.get(new_config, :max_subscribers, topic.max_subscribers),
        config: Map.merge(topic.config, new_config)
    }

    # Validate the updated topic
    with :ok <- validate_partitions(updated_topic.partitions),
         :ok <- validate_max_subscribers(updated_topic.max_subscribers) do
      {:ok, updated_topic}
    end
  end

  @doc """
  Gets topic statistics structure.
  """
  @spec stats_template(t()) :: map()
  def stats_template(%__MODULE__{} = topic) do
    %{
      topic: topic.name,
      partitions: topic.partitions,
      max_subscribers: topic.max_subscribers,
      created_at: topic.created_at,
      message_count: 0,
      subscriber_count: 0,
      size_bytes: 0,
      last_message_at: nil
    }
  end

  @doc """
  Validates if a topic is well-formed according to business rules.
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = topic) do
    validate_name(topic.name) == :ok and
      validate_partitions(topic.partitions) == :ok and
      validate_max_subscribers(topic.max_subscribers) == :ok and
      match?(%DateTime{}, topic.created_at)
  end

  # Private functions

  defp validate_name(name) when is_binary(name) do
    cond do
      String.length(name) == 0 ->
        {:error, :empty_topic_name}

      String.length(name) > 255 ->
        {:error, :topic_name_too_long}

      not Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name) ->
        {:error, :invalid_topic_name_format}

      true ->
        :ok
    end
  end

  defp validate_name(_), do: {:error, :topic_name_must_be_string}

  defp validate_config(opts) do
    # Convert map to keyword list for validation
    config_list =
      case opts do
        %{} = map -> Map.to_list(map)
        list when is_list(list) -> list
        _ -> []
      end

    with :ok <- validate_partitions(Keyword.get(config_list, :partitions, 1)) do
      validate_max_subscribers(Keyword.get(config_list, :max_subscribers, 1000))
    end
  end

  defp validate_partitions(count) when is_integer(count) and count > 0 and count <= 1000,
    do: :ok

  defp validate_partitions(_), do: {:error, :invalid_partitions}

  defp validate_max_subscribers(max) when is_integer(max) and max > 0, do: :ok
  defp validate_max_subscribers(:unlimited), do: :ok
  defp validate_max_subscribers(_), do: {:error, :invalid_max_subscribers}
end
