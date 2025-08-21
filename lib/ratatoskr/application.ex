defmodule Ratatoskr.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Ratatoskr message broker...")

    children = [
      # Registry for topic discovery
      {Registry, keys: :unique, name: Ratatoskr.Registry},
      
      # DynamicSupervisor for topics
      {DynamicSupervisor, strategy: :one_for_one, name: Ratatoskr.Topic.Supervisor},
      
      # Broker coordinator
      Ratatoskr.Broker
    ]

    opts = [strategy: :one_for_one, name: Ratatoskr.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
