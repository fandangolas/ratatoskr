defmodule Ratatoskr.Core.Models.Topic do
  @moduledoc """
  Type definitions and struct for Topic domain entity.

  Defines the core data structure for topics in the Ratatoskr message broker.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          partitions: pos_integer(),
          max_subscribers: pos_integer(),
          config: map(),
          created_at: DateTime.t()
        }

  defstruct [
    :name,
    :created_at,
    partitions: 1,
    max_subscribers: 1000,
    config: %{}
  ]
end
