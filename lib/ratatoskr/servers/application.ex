defmodule Ratatoskr.Servers.Application do
  @moduledoc """
  OTP Application entry point for Ratatoskr.

  Sets up the supervision tree and configures dependency injection
  for the clean architecture layers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Infrastructure layer
      {Ratatoskr.Infrastructure.Registry.ProcessRegistry, []},
      {Ratatoskr.Infrastructure.Storage.EtsAdapter, []},

      # Process management layer
      {Ratatoskr.Servers.Supervisor, []},

      # Interface layer
      {Ratatoskr.Servers.GrpcEndpoint, []}
    ]

    opts = [strategy: :one_for_one, name: Ratatoskr.ApplicationSupervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Initialize telemetry
        setup_telemetry()

        {:ok, pid}

      error ->
        error
    end
  end

  @impl true
  def stop(_state) do
    # Cleanup telemetry handlers
    Ratatoskr.Infrastructure.Telemetry.MetricsCollector.detach_handlers()
    :ok
  end

  defp setup_telemetry do
    # Attach telemetry handlers
    Ratatoskr.Infrastructure.Telemetry.MetricsCollector.attach_default_handlers()

    # Emit startup metrics
    Ratatoskr.Infrastructure.Telemetry.MetricsCollector.emit_startup_metrics()

    # Start periodic metrics collection
    Ratatoskr.Infrastructure.Telemetry.MetricsCollector.start_periodic_metrics()
  end
end
