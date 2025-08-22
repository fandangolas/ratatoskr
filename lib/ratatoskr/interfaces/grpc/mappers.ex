defmodule Ratatoskr.Interfaces.Grpc.Mappers do
  @moduledoc """
  Mappers for converting between domain entities and gRPC protocol types.

  Handles the translation between our clean domain models and the
  protocol buffer generated types.
  """

  alias Ratatoskr.Core.Message, as: DomainMessage
  alias Ratatoskr.Grpc.Message, as: GrpcMessage

  @doc """
  Converts a domain message to a gRPC message.
  """
  @spec domain_message_to_grpc(DomainMessage.t(), String.t()) :: GrpcMessage.t()
  def domain_message_to_grpc(%DomainMessage{} = message, topic) do
    %GrpcMessage{
      id: message.id,
      topic: topic,
      payload: get_message_payload(message.payload),
      metadata: map_to_grpc_metadata(message.metadata),
      timestamp: DateTime.to_unix(message.timestamp, :millisecond)
    }
  end

  @doc """
  Converts gRPC metadata map to Elixir map.
  """
  @spec grpc_metadata_to_map(map()) :: map()
  def grpc_metadata_to_map(metadata) when is_map(metadata) do
    metadata
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> Enum.into(%{})
  end

  def grpc_metadata_to_map(_), do: %{}

  @doc """
  Converts Elixir map to gRPC metadata format.
  """
  @spec map_to_grpc_metadata(map()) :: map()
  def map_to_grpc_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> Enum.into(%{})
  end

  def map_to_grpc_metadata(_), do: %{}

  @doc """
  Extracts payload from domain message for gRPC transport.
  """
  @spec get_message_payload(term()) :: binary()
  def get_message_payload(payload) when is_map(payload) do
    # If payload has binary data, use that; otherwise encode as JSON
    case Map.get(payload, :data) do
      data when is_binary(data) -> data
      _ -> encode_payload_as_binary(payload)
    end
  end

  def get_message_payload(payload) when is_binary(payload), do: payload

  def get_message_payload(payload) do
    # Fallback: encode as JSON then to binary
    encode_payload_as_binary(payload)
  end

  @doc """
  Converts gRPC payload to domain format.
  """
  @spec grpc_payload_to_domain(binary()) :: term()
  def grpc_payload_to_domain(payload) when is_binary(payload) do
    # Try to decode as JSON first, fallback to binary
    case Jason.decode(payload) do
      {:ok, decoded} -> decoded
      {:error, _} -> payload
    end
  end

  @doc """
  Converts domain subscription reference to gRPC format.
  """
  @spec subscription_ref_to_grpc(reference()) :: String.t()
  def subscription_ref_to_grpc(ref) when is_reference(ref) do
    ref
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end

  @doc """
  Converts gRPC subscription reference to domain format.
  """
  @spec grpc_to_subscription_ref(String.t()) :: {:ok, reference()} | {:error, atom()}
  def grpc_to_subscription_ref(ref_string) when is_binary(ref_string) do
    try do
      decoded = Base.decode64!(ref_string)
      ref = :erlang.binary_to_term(decoded)

      if is_reference(ref) do
        {:ok, ref}
      else
        {:error, :not_a_reference}
      end
    rescue
      _ -> {:error, :invalid_format}
    end
  end

  @doc """
  Converts error terms to user-friendly gRPC error messages.
  """
  @spec error_to_grpc_message(term()) :: String.t()
  def error_to_grpc_message(:topic_not_found), do: "Topic not found"
  def error_to_grpc_message(:topic_already_exists), do: "Topic already exists"
  def error_to_grpc_message(:invalid_topic), do: "Invalid topic name"
  def error_to_grpc_message(:empty_topic), do: "Topic name cannot be empty"
  def error_to_grpc_message(:topic_too_long), do: "Topic name too long"
  def error_to_grpc_message(:invalid_topic_format), do: "Invalid topic name format"
  def error_to_grpc_message(:payload_not_serializable), do: "Message payload is not serializable"
  def error_to_grpc_message(:subscriber_not_alive), do: "Subscriber process is not alive"
  def error_to_grpc_message(:subscription_timeout), do: "Subscription request timed out"
  def error_to_grpc_message(:topic_timeout), do: "Topic server timed out"
  def error_to_grpc_message(:delivery_timeout), do: "Message delivery timed out"

  def error_to_grpc_message({:persistence_failed, reason}),
    do: "Message persistence failed: #{reason}"

  def error_to_grpc_message({:start_failed, reason}), do: "Failed to start topic: #{reason}"
  def error_to_grpc_message(reason), do: to_string(reason)

  # Private functions

  defp encode_payload_as_binary(payload) do
    try do
      # Try JSON encoding first
      Jason.encode!(payload)
    rescue
      _ ->
        # Fallback to Erlang term encoding
        :erlang.term_to_binary(payload)
    end
  end
end
