defmodule Ratatoskr.Servers.GrpcEndpoint do
  @moduledoc """
  gRPC endpoint server for Ratatoskr.

  Manages the gRPC server process and configures the service handlers.
  """

  use GenServer
  require Logger

  @default_port 50051

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Get port from runtime configuration or opts
    config_port = Application.get_env(:ratatoskr, :grpc_port, @default_port)
    port = Keyword.get(opts, :port, config_port)

    Logger.info("Starting gRPC endpoint on port #{port}")

    # Enable gRPC server for real testing
    case start_grpc_server(port) do
      {:ok, server_pid} ->
        Logger.info("gRPC server started successfully on port #{port}")
        {:ok, %{port: port, server_pid: server_pid}}

      {:error, reason} ->
        Logger.error("Failed to start gRPC server: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  defp start_grpc_server(port) do
    # Get host from runtime configuration
    host = Application.get_env(:ratatoskr, :grpc_host, "0.0.0.0")
    
    # Parse host to IP tuple format
    ip = case host do
      "0.0.0.0" -> {0, 0, 0, 0}
      "127.0.0.1" -> {127, 0, 0, 1}
      _ -> parse_ip_string(host)
    end
    
    # Start the gRPC server supervisor with our service
    GRPC.Server.Supervisor.start_link(
      port: port,
      start_server: true,
      adapter_opts: [ip: ip],
      servers: [Ratatoskr.Interfaces.Grpc.Server]
    )
  end
  
  defp parse_ip_string(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, ip_tuple} -> ip_tuple
      _ -> {0, 0, 0, 0}  # Default fallback
    end
  end

  @impl true
  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.error("gRPC server exited: #{inspect(reason)}")
    {:stop, reason, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("gRPC endpoint received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end
