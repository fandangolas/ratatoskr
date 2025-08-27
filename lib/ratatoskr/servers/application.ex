defmodule Ratatoskr.Servers.Application do
  @moduledoc """
  OTP Application entry point for Ratatoskr.

  Sets up the supervision tree and configures dependency injection
  for the clean architecture layers.
  """

  use Application
  alias Ratatoskr.Infrastructure.DI.Container
  alias Ratatoskr.Infrastructure.DI.Lifecycle
  alias Ratatoskr.Infrastructure.Registry.ProcessRegistry
  alias Ratatoskr.Infrastructure.Storage.EtsAdapter
  alias Ratatoskr.Infrastructure.Telemetry.MetricsCollector

  alias Ratatoskr.Servers.GrpcEndpoint
  alias Ratatoskr.Servers.Supervisor


  @impl true
  def start(_type, _args) do
    children = [
      # Infrastructure layer
      {ProcessRegistry, []},
      {EtsAdapter, []},
      {Ratatoskr.Infrastructure.Cache.TopicCache, []},

      # Dependency injection lifecycle manager
      {Lifecycle, []},

      # Process management layer
      {Supervisor, []},

      # Interface layer
      {GrpcEndpoint, []},
      
      # Lightweight monitoring (no hot-path overhead)
      {Ratatoskr.Infrastructure.Monitoring.MetricsEndpoint, []}
    ]

    opts = [strategy: :one_for_one, name: Ratatoskr.ApplicationSupervisor]

    case Elixir.Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Configure lifecycle dependencies
        Container.configure_lifecycle()

        # Initialize telemetry
        setup_telemetry()

        {:ok, pid}

      error ->
        error
    end
  end

  @impl true
  def stop(_state) do
    # Shutdown managed dependencies
    Container.shutdown()

    # Cleanup telemetry handlers
    MetricsCollector.detach_handlers()
    :ok
  end

  defp setup_telemetry do
    # Attach telemetry handlers
    MetricsCollector.attach_default_handlers()

    # Emit startup metrics
    MetricsCollector.emit_startup_metrics()

    # Start periodic metrics collection
    MetricsCollector.start_periodic_metrics()
  end
end
