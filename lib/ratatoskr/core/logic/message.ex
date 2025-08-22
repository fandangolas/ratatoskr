defmodule Ratatoskr.Core.Logic.Message do
  @moduledoc """
  Core domain entity representing a message in the Ratatoskr message broker.

  This is a pure domain entity with no dependencies on external systems.
  Contains business rules and validations for messages.
  """

  alias Ratatoskr.Core.Models.Message, as: MessageModel

  @type t :: MessageModel.t()

  defstruct [
    :id,
    :topic,
    :payload,
    :timestamp,
    :partition_key,
    metadata: %{}
  ]

  @doc """
  Creates a new message with business rule validations.
  """
  @spec new(String.t(), term(), keyword()) :: {:ok, t()} | {:error, reason :: atom()}
  def new(topic, payload, opts \\ []) do
    with :ok <- validate_topic(topic),
         :ok <- validate_payload(payload) do
      message = %__MODULE__{
        id: generate_id(),
        topic: topic,
        payload: payload,
        timestamp: DateTime.utc_now(),
        metadata: Keyword.get(opts, :metadata, %{}),
        partition_key: Keyword.get(opts, :partition_key)
      }

      {:ok, message}
    end
  end

  @doc """
  Creates a new message, raising on validation errors.
  """
  @spec new!(String.t(), term(), keyword()) :: t()
  def new!(topic, payload, opts \\ []) do
    case new(topic, payload, opts) do
      {:ok, message} -> message
      {:error, reason} -> raise ArgumentError, "Invalid message: #{reason}"
    end
  end

  @doc """
  Adds metadata to an existing message.
  """
  @spec add_metadata(t(), String.t() | atom(), term()) :: t()
  def add_metadata(%__MODULE__{} = message, key, value) do
    %{message | metadata: Map.put(message.metadata, to_string(key), value)}
  end

  @doc """
  Gets metadata value from message.
  """
  @spec get_metadata(t(), String.t() | atom(), term()) :: term()
  def get_metadata(%__MODULE__{} = message, key, default \\ nil) do
    Map.get(message.metadata, to_string(key), default)
  end

  @doc """
  Validates if message is well-formed according to business rules.
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = message) do
    validate_topic(message.topic) == :ok and
      validate_payload(message.payload) == :ok and
      is_binary(message.id) and
      match?(%DateTime{}, message.timestamp)
  end

  @doc """
  Calculates the size of a message in bytes (for resource management).
  """
  @spec size_bytes(t()) :: non_neg_integer()
  def size_bytes(%__MODULE__{} = message) do
    payload_size = payload_size_bytes(message.payload)
    metadata_size = :erlang.external_size(message.metadata)
    topic_size = byte_size(message.topic)
    id_size = byte_size(message.id)

    payload_size + metadata_size + topic_size + id_size
  end

  # Private functions

  defp validate_topic(topic) when is_binary(topic) do
    cond do
      String.length(topic) == 0 -> {:error, :empty_topic}
      String.length(topic) > 255 -> {:error, :topic_too_long}
      not Regex.match?(~r/^[a-zA-Z0-9_-]+$/, topic) -> {:error, :invalid_topic_format}
      true -> :ok
    end
  end

  defp validate_topic(_), do: {:error, :topic_must_be_string}

  defp validate_payload(payload) do
    # Check if payload contains functions (not serializable)
    if contains_function?(payload) do
      {:error, :payload_not_serializable}
    else
      try do
        # Ensure payload is serializable
        _ = :erlang.term_to_binary(payload)
        :ok
      rescue
        _ -> {:error, :payload_not_serializable}
      end
    end
  end

  defp contains_function?(payload) when is_function(payload), do: true

  defp contains_function?(payload) when is_list(payload) do
    Enum.any?(payload, &contains_function?/1)
  end

  defp contains_function?(payload) when is_tuple(payload) do
    payload |> Tuple.to_list() |> Enum.any?(&contains_function?/1)
  end

  defp contains_function?(payload) when is_map(payload) do
    Enum.any?(payload, fn {k, v} -> contains_function?(k) or contains_function?(v) end)
  end

  defp contains_function?(_), do: false

  defp payload_size_bytes(payload) do
    try do
      :erlang.external_size(payload)
    rescue
      _ -> 0
    end
  end

  defp generate_id do
    # Generate a UUID-like string using crypto random bytes
    # Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx (UUID v4 format)
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    # Set version (4) and variant bits according to UUID v4 spec
    import Bitwise
    # Set version to 4
    c = c ||| 0x4000
    # Clear other version bits
    c = c &&& 0x4FFF
    # Set variant bits
    d = d ||| 0x8000
    # Clear other variant bits
    d = d &&& 0xBFFF

    # Format as UUID string
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> :erlang.iolist_to_binary()
    |> String.downcase()
  end
end
