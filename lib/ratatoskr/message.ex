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
