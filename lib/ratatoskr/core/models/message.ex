defmodule Ratatoskr.Core.Models.Message do
  @moduledoc """
  Type definitions and struct for Message domain entity.
  
  Defines the core data structure for messages in the Ratatoskr message broker.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          topic: String.t(),
          payload: term(),
          timestamp: DateTime.t(),
          metadata: map(),
          partition_key: String.t() | nil
        }

  defstruct [
    :id,
    :topic,
    :payload,
    :timestamp,
    :partition_key,
    metadata: %{}
  ]
end