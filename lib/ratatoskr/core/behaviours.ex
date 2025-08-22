defmodule Ratatoskr.Core.Behaviours do
  @moduledoc """
  Core domain behaviors and interfaces for Ratatoskr.

  These define the contracts that infrastructure implementations must follow,
  enabling dependency inversion and testability.
  """

  defmodule Storage do
    @moduledoc """
    Storage behavior for message persistence.
    """
    @callback persist_message(topic :: binary(), message :: Ratatoskr.Core.Logic.Message.t()) ::
                {:ok, offset :: integer()} | {:error, reason :: term()}

    @callback load_messages(topic :: binary(), offset :: integer(), limit :: integer()) ::
                {:ok, [Ratatoskr.Core.Logic.Message.t()]} | {:error, reason :: term()}

    @callback delete_messages(topic :: binary(), before_offset :: integer()) ::
                :ok | {:error, reason :: term()}

    @callback get_topic_stats(topic :: binary()) ::
                {:ok, %{message_count: integer(), size_bytes: integer()}}
                | {:error, reason :: term()}
  end

  defmodule Registry do
    @moduledoc """
    Registry behavior for process discovery and routing.
    """
    @callback register_topic(topic :: binary(), pid :: pid()) :: :ok | {:error, reason :: term()}
    @callback unregister_topic(topic :: binary()) :: :ok
    @callback lookup_topic(topic :: binary()) :: {:ok, pid()} | {:error, :not_found}
    @callback list_topics() :: {:ok, [binary()]}
  end

  defmodule Metrics do
    @moduledoc """
    Metrics behavior for observability.
    """
    @callback increment_counter(name :: atom(), value :: number(), labels :: map()) :: :ok
    @callback observe_histogram(name :: atom(), value :: number(), labels :: map()) :: :ok
    @callback set_gauge(name :: atom(), value :: number(), labels :: map()) :: :ok
  end

  defmodule EventPublisher do
    @moduledoc """
    Event publisher behavior for domain events.
    """
    @callback publish_event(event :: term(), metadata :: map()) :: :ok
  end
end
