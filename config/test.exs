import Config

# Test environment configuration for Ratatoskr

# Reduce logging noise in tests
config :logger, level: :warning

# Configure ExCoveralls for test coverage
config :excoveralls,
  test_coverage: [
    minimum_coverage: 80,
    refuse_coverage_below: 75
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
