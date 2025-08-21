import Config

# Configuration for Ratatoskr message broker

# Logger configuration
config :logger,
  level: :info,
  format: "$time $metadata[$level] $message\n"

# Test environment specific configuration
if Mix.env() == :test do
  # Reduce log level in tests
  config :logger, level: :warning

  # Configure ExUnit for CI environments
  config :ex_unit,
    capture_log: true,
    timeout: 30_000
end

# Development environment
if Mix.env() == :dev do
  # More verbose logging in development
  config :logger, level: :debug
end

# Load environment specific configuration files
if File.exists?("config/#{Mix.env()}.exs") do
  import_config "#{Mix.env()}.exs"
end
