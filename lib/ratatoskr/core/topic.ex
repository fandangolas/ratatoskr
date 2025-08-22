defmodule Ratatoskr.Core.Topic do
  @moduledoc """
  Core domain entity representing a topic in the message broker.

  Contains business rules for topic management, subscription handling,
  and message routing logic.
  """

  alias Ratatoskr.Core.{Message}

  @type t :: %__MODULE__{
          name: String.t(),
          partition_count: pos_integer(),
          retention_ms: pos_integer(),
          max_subscribers: pos_integer(),
          config: map(),
          created_at: DateTime.t()
        }

  defstruct [
    :name,
    :created_at,
    partition_count: 1,
    # 1 hour default
    retention_ms: 3_600_000,
    # Default limit
    max_subscribers: 10_000,
    config: %{}
  ]

  @doc """
  Creates a new topic with validation.
  """
  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, reason :: atom()}
  def new(name, opts \\ []) do
    with :ok <- validate_name(name),
         :ok <- validate_config(opts) do
      topic = %__MODULE__{
        name: name,
        partition_count: Keyword.get(opts, :partition_count, 1),
        retention_ms: Keyword.get(opts, :retention_ms, 3_600_000),
        max_subscribers: Keyword.get(opts, :max_subscribers, 10_000),
        config: Keyword.get(opts, :config, %{}),
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
    :erlang.phash2(key, topic.partition_count)
  end

  @doc """
  Checks if topic can accept a new subscriber.
  """
  @spec can_add_subscriber?(t(), current_count :: non_neg_integer()) :: boolean()
  def can_add_subscriber?(%__MODULE__{} = topic, current_count) do
    current_count < topic.max_subscribers
  end

  @doc """
  Checks if a message should be retained based on topic retention policy.
  """
  @spec should_retain_message?(t(), Message.t()) :: boolean()
  def should_retain_message?(%__MODULE__{} = topic, %Message{} = message) do
    age_ms = DateTime.diff(DateTime.utc_now(), message.timestamp, :millisecond)
    age_ms < topic.retention_ms
  end

  @doc """
  Updates topic configuration with validation.
  """
  @spec update_config(t(), map()) :: {:ok, t()} | {:error, reason :: atom()}
  def update_config(%__MODULE__{} = topic, new_config) do
    merged_config = Map.merge(topic.config, new_config)

    case validate_config_map(merged_config) do
      :ok -> {:ok, %{topic | config: merged_config}}
      error -> error
    end
  end

  @doc """
  Gets topic statistics structure.
  """
  @spec stats_template(t()) :: map()
  def stats_template(%__MODULE__{} = topic) do
    %{
      topic: topic.name,
      partition_count: topic.partition_count,
      retention_ms: topic.retention_ms,
      max_subscribers: topic.max_subscribers,
      created_at: topic.created_at,
      message_count: 0,
      subscriber_count: 0,
      size_bytes: 0,
      last_message_at: nil
    }
  end

  # Private functions

  defp validate_name(name) when is_binary(name) do
    cond do
      String.length(name) == 0 ->
        {:error, :empty_name}

      String.length(name) > 255 ->
        {:error, :name_too_long}

      not Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name) ->
        {:error, :invalid_name_format}

      String.starts_with?(name, "_") ->
        {:error, :reserved_name_prefix}

      true ->
        :ok
    end
  end

  defp validate_name(_), do: {:error, :name_must_be_string}

  defp validate_config(opts) do
    with :ok <- validate_partition_count(Keyword.get(opts, :partition_count, 1)),
         :ok <- validate_retention_ms(Keyword.get(opts, :retention_ms, 3_600_000)),
         :ok <- validate_max_subscribers(Keyword.get(opts, :max_subscribers, 10_000)),
         :ok <- validate_config_map(Keyword.get(opts, :config, %{})) do
      :ok
    end
  end

  defp validate_partition_count(count) when is_integer(count) and count > 0 and count <= 1000,
    do: :ok

  defp validate_partition_count(_), do: {:error, :invalid_partition_count}

  defp validate_retention_ms(ms) when is_integer(ms) and ms > 0, do: :ok
  defp validate_retention_ms(_), do: {:error, :invalid_retention_ms}

  defp validate_max_subscribers(max) when is_integer(max) and max > 0 and max <= 100_000, do: :ok
  defp validate_max_subscribers(_), do: {:error, :invalid_max_subscribers}

  defp validate_config_map(config) when is_map(config) do
    # Add specific config validation rules here as needed
    :ok
  end

  defp validate_config_map(_), do: {:error, :config_must_be_map}
end
