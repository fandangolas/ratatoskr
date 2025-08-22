defmodule Ratatoskr.Core.Logic.Subscription do
  @moduledoc """
  Core domain entity representing a subscription to a topic.

  Manages subscriber lifecycle, delivery tracking, and subscription metadata.
  """

  alias Ratatoskr.Core.Models.Subscription, as: SubscriptionModel

  @type t :: SubscriptionModel.t()

  defstruct [
    :id,
    :topic,
    :subscriber_pid,
    :subscriber_id,
    :partition,
    :filter,
    :created_at,
    :last_message_at,
    message_count: 0,
    metadata: %{},
    status: :active,
    options: []
  ]

  @doc """
  Creates a new subscription with validation.
  """
  @spec new(String.t(), pid(), keyword()) :: {:ok, t()} | {:error, reason :: atom()}
  def new(topic, subscriber_pid, opts \\ []) do
    with :ok <- validate_topic(topic),
         :ok <- validate_subscriber_pid(subscriber_pid),
         :ok <- validate_options(opts) do
      subscription = %__MODULE__{
        id: make_ref(),
        topic: topic,
        subscriber_pid: subscriber_pid,
        subscriber_id: Keyword.get(opts, :subscriber_id),
        partition: Keyword.get(opts, :partition),
        filter: Keyword.get(opts, :filter),
        created_at: DateTime.utc_now(),
        metadata: Keyword.get(opts, :metadata, %{}),
        status: :active,
        options: opts
      }

      {:ok, subscription}
    end
  end

  @doc """
  Creates a new subscription, raising on validation errors.
  """
  @spec new!(String.t(), pid(), keyword()) :: t()
  def new!(topic, subscriber_pid, opts \\ []) do
    case new(topic, subscriber_pid, opts) do
      {:ok, subscription} -> subscription
      {:error, reason} -> raise ArgumentError, "Invalid subscription: #{reason}"
    end
  end

  @doc """
  Checks if subscription is still active.
  """
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{} = subscription) do
    subscription.status == :active and Process.alive?(subscription.subscriber_pid)
  end

  @doc """
  Cancels a subscription.
  """
  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = subscription) do
    %{subscription | status: :cancelled}
  end

  @doc """
  Pauses a subscription.
  """
  @spec pause(t()) :: t()
  def pause(%__MODULE__{} = subscription) do
    %{subscription | status: :paused}
  end

  @doc """
  Resumes a paused subscription.
  """
  @spec resume(t()) :: t()
  def resume(%__MODULE__{} = subscription) do
    %{subscription | status: :active}
  end

  @doc """
  Checks if a message should be delivered to this subscription.
  """
  @spec should_deliver?(t(), Ratatoskr.Core.Logic.Message.t()) :: boolean()
  def should_deliver?(%__MODULE__{} = subscription, %Ratatoskr.Core.Logic.Message{} = message) do
    active?(subscription) and
      partition_match?(subscription, message) and
      filter_match?(subscription, message)
  end

  @doc """
  Records that a message was delivered to this subscription.
  """
  @spec record_delivery(t()) :: t()
  def record_delivery(%__MODULE__{} = subscription) do
    %{
      subscription
      | last_message_at: DateTime.utc_now(),
        message_count: subscription.message_count + 1
    }
  end

  @doc """
  Updates subscription metadata.
  """
  @spec update_metadata(t(), map()) :: t()
  def update_metadata(%__MODULE__{} = subscription, new_metadata) do
    merged_metadata = Map.merge(subscription.metadata, new_metadata)
    %{subscription | metadata: merged_metadata}
  end

  @doc """
  Gets subscription statistics.
  """
  @spec stats(t()) :: map()
  def stats(%__MODULE__{} = subscription) do
    uptime_seconds =
      case subscription.created_at do
        nil -> 0
        created -> DateTime.diff(DateTime.utc_now(), created, :second)
      end

    %{
      id: subscription.id,
      topic: subscription.topic,
      subscriber_id: subscription.subscriber_id,
      active: active?(subscription),
      created_at: subscription.created_at,
      last_message_at: subscription.last_message_at,
      message_count: subscription.message_count,
      uptime_seconds: uptime_seconds,
      partition: subscription.partition
    }
  end

  @doc """
  Serializes subscription reference for transport (e.g., gRPC).
  """
  @spec serialize_reference(reference()) :: String.t()
  def serialize_reference(ref) when is_reference(ref) do
    ref
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end

  @doc """
  Deserializes subscription reference from transport format.
  """
  @spec deserialize_reference(String.t()) :: reference()
  def deserialize_reference(ref_string) when is_binary(ref_string) do
    try do
      decoded = Base.decode64!(ref_string)
      ref = :erlang.binary_to_term(decoded)

      if is_reference(ref) do
        ref
      else
        raise ArgumentError, "Decoded value is not a reference"
      end
    rescue
      e ->
        reraise ArgumentError, "Invalid reference format: #{Exception.message(e)}", __STACKTRACE__
    end
  end

  @doc """
  Validates if a subscription is well-formed according to business rules.
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = subscription) do
    is_reference(subscription.id) and
      is_binary(subscription.topic) and
      subscription.topic != "" and
      is_pid(subscription.subscriber_pid) and
      subscription.status in [:active, :paused, :cancelled] and
      match?(%DateTime{}, subscription.created_at)
  end

  # Private functions

  defp validate_topic(topic) when is_binary(topic) and byte_size(topic) > 0, do: :ok
  defp validate_topic(_), do: {:error, :invalid_topic}

  defp validate_subscriber_pid(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      :ok
    else
      {:error, :subscriber_not_alive}
    end
  end

  defp validate_subscriber_pid(_), do: {:error, :invalid_subscriber}

  defp validate_options(opts) do
    # Validate filter function if provided
    case Keyword.get(opts, :filter) do
      nil -> :ok
      fun when is_function(fun, 1) -> :ok
      filter_map when is_map(filter_map) -> :ok
      _ -> {:error, :invalid_filter}
    end
  end

  defp partition_match?(%{partition: nil}, _message), do: true

  defp partition_match?(%{partition: _partition}, %{topic: _topic}) do
    # This would need access to topic configuration to calculate actual partition
    # For now, assume match - this will be resolved in the use case layer
    true
  end

  defp filter_match?(%{filter: nil, options: options}, message) do
    case Keyword.get(options, :filter) do
      nil ->
        true

      filter_map when is_map(filter_map) ->
        payload = message.payload

        Enum.all?(filter_map, fn {key, expected_value} ->
          Map.get(payload, key) == expected_value
        end)

      filter_fun when is_function(filter_fun, 1) ->
        try do
          filter_fun.(message.payload)
        rescue
          _ -> false
        end

      _ ->
        true
    end
  end

  defp filter_match?(%{filter: filter}, message) when is_function(filter, 1) do
    filter.(message.payload)
  rescue
    _ -> false
  end

  defp filter_match?(_subscription, _message), do: true
end
