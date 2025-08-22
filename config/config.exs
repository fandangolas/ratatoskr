import Config

# Configuration for Ratatoskr message broker

# Dependency injection configuration
# Override default implementations by configuring specific dependencies
# config :ratatoskr,
#   registry: MyCustomRegistry,
#   storage: MyStorageAdapter,
#   metrics: MyMetricsCollector,
#   event_publisher: MyEventPublisher,
#   lifecycle: [
#     singletons: [
#       # Eager singleton with health check
#       {:metrics_collector, Ratatoskr.Infrastructure.Telemetry.MetricsCollector, [], 
#        lazy: false, health_check: &Process.alive?/1},
#       # Lazy singleton
#       {:global_cache, GlobalCache, [size: 10_000]}
#     ],
#     process_scoped: [
#       # Per-process request context
#       {:request_context, RequestContext, []},
#       # Per-process cache
#       {:local_cache, LocalCache, [size: 1000]}
#     ]
#   ]

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
