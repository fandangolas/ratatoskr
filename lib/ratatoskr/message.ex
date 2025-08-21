defmodule Ratatoskr.Message do
  @moduledoc """
  Message struct representing a message in the Ratatoskr message broker.
  """

  @type t :: %__MODULE__{
    id: String.t(),
    topic: String.t(),
    payload: term(),
    timestamp: DateTime.t(),
    metadata: map()
  }

  defstruct [
    :id,
    :topic,
    :payload,
    :timestamp,
    metadata: %{}
  ]

  @doc """
  Creates a new message with a unique ID and timestamp.
  """
  @spec new(String.t(), term(), map()) :: t()
  def new(topic, payload, metadata \\ %{}) do
    %__MODULE__{
      id: generate_id(),
      topic: topic,
      payload: payload,
      timestamp: DateTime.utc_now(),
      metadata: metadata
    }
  end

  defp generate_id do
    UUID.uuid4()
  rescue
    UndefinedFunctionError ->
      # Fallback if UUID is not available
      :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end