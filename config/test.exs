import Config

# Test environment configuration for Ratatoskr

# Use different ports for services in tests to avoid conflicts
config :ratatoskr,
  grpc_port: 50052,
  grpc_host: "127.0.0.1",
  metrics_port: 4001

# Disable partitioning for most tests to maintain backward compatibility
config :ratatoskr, :partitioning,
  default_partition_count: 1,
  enable_partitioning: false

# Reduce logging noise in tests
config :logger, level: :warning

# Configure ExCoveralls for test coverage
config :excoveralls,
  test_coverage: [
    minimum_coverage: 80,
    refuse_coverage_below: 75
  ],
  skip_files: [
    "test/support/"
  ]

# Configure test environment for CI
if System.get_env("CI") do
  # CI-specific configuration
  config :logger, level: :error

  # Optimize test timeouts for CI
  config :ex_unit,
    timeout: 60_000,
    capture_log: true
end
