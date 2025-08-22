defmodule Ratatoskr.Servers.Supervisor do
  @moduledoc """
  Main supervisor for Ratatoskr servers.

  Manages the broker server and topic supervisor processes.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Broker server for coordinating topics
      {Ratatoskr.Servers.BrokerServer, []},

      # Dynamic supervisor for topic servers
      {DynamicSupervisor, name: Ratatoskr.Servers.TopicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
