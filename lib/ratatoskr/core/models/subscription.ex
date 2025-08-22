defmodule Ratatoskr.Core.Models.Subscription do
  @moduledoc """
  Type definitions and struct for Subscription domain entity.

  Defines the core data structure for subscriptions in the Ratatoskr message broker.
  """

  @type t :: %__MODULE__{
          id: reference(),
          topic: String.t(),
          subscriber_pid: pid(),
          subscriber_id: String.t() | nil,
          partition: non_neg_integer() | nil,
          filter: (term() -> boolean()) | nil,
          created_at: DateTime.t(),
          last_message_at: DateTime.t() | nil,
          message_count: non_neg_integer(),
          metadata: map(),
          status: :active | :paused | :cancelled,
          options: keyword()
        }

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
end
