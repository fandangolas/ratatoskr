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
    
    # Get configurable performance settings
    max_connections = Application.get_env(:ratatoskr, :grpc_max_connections, 32_768)
    num_acceptors = Application.get_env(:ratatoskr, :grpc_num_acceptors, 100)
    send_buffer = Application.get_env(:ratatoskr, :grpc_send_buffer_size, 65536)
    recv_buffer = Application.get_env(:ratatoskr, :grpc_recv_buffer_size, 65536)
    
    # Optimized adapter options for high performance
    adapter_opts = [
      ip: ip,
      # Connection pool optimization
      max_connections: max_connections,   # Configurable max connections
      num_acceptors: num_acceptors,       # Configurable acceptors for concurrency
      # Socket-level optimizations  
      socket_opts: [
        :binary,                        # Binary mode for efficiency
        {:packet, :raw},                # Raw packet mode
        {:active, false},               # Passive mode for backpressure
        {:reuseaddr, true},             # Allow port reuse
        {:nodelay, true},               # Disable Nagle's algorithm
        {:send_timeout, 5000},          # 5s send timeout
        {:send_timeout_close, true},    # Close on send timeout
        {:keepalive, true},             # Enable TCP keepalive
        # Configurable buffer optimizations
        {:sndbuf, send_buffer},         # Configurable send buffer
        {:recbuf, recv_buffer},         # Configurable receive buffer
        {:buffer, recv_buffer}          # Configurable driver buffer
      ]
    ]
    
    # Start the gRPC server supervisor with optimized configuration
    GRPC.Server.Supervisor.start_link(
      port: port,
      start_server: true,
      adapter_opts: adapter_opts,
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
