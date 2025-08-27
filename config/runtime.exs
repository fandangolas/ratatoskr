import Config

# Runtime configuration for Docker deployment
# This file is evaluated at runtime and can read environment variables

# gRPC Server Configuration
config :ratatoskr,
  grpc_host: System.get_env("RATATOSKR_GRPC_HOST", "0.0.0.0"),
  grpc_port: System.get_env("RATATOSKR_GRPC_PORT", "50051") |> String.to_integer(),
  # gRPC Performance Tuning
  grpc_max_connections:
    System.get_env("RATATOSKR_GRPC_MAX_CONNECTIONS", "32768") |> String.to_integer(),
  grpc_num_acceptors:
    System.get_env("RATATOSKR_GRPC_NUM_ACCEPTORS", "100") |> String.to_integer(),
  grpc_send_buffer_size:
    System.get_env("RATATOSKR_GRPC_SEND_BUFFER", "65536") |> String.to_integer(),
  grpc_recv_buffer_size:
    System.get_env("RATATOSKR_GRPC_RECV_BUFFER", "65536") |> String.to_integer()

# Logger configuration for production
if config_env() == :prod do
  log_level = System.get_env("RATATOSKR_LOG_LEVEL", "info")

  config :logger,
    level: String.to_atom(log_level),
    format: "$time $metadata[$level] $message\n"
end

# Performance tuning (can be adjusted via environment variables)
config :ratatoskr,
  max_queue_size: System.get_env("RATATOSKR_MAX_QUEUE_SIZE", "10000") |> String.to_integer(),
  max_subscribers_per_topic:
    System.get_env("RATATOSKR_MAX_SUBSCRIBERS", "1000") |> String.to_integer(),
  message_timeout_ms:
    System.get_env("RATATOSKR_MESSAGE_TIMEOUT_MS", "30000") |> String.to_integer()
