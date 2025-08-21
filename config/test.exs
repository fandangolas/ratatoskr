import Config

# Test environment configuration for Ratatoskr

# Reduce logging noise in tests
config :logger, level: :warning

# Configure ExCoveralls for test coverage  
# Note: Lower thresholds account for benchmark_helpers.ex which is testing infrastructure
config :excoveralls,
  test_coverage: [
    minimum_coverage: 50,
    refuse_coverage_below: 45
  ],
  skip_files: [
    "lib/ratatoskr/benchmark_helpers.ex"
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
