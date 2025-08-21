# CI/CD Workflows

This directory contains GitHub Actions workflows for continuous integration and deployment.

## ci.yml

Comprehensive CI pipeline that runs on every push to `main` and `benchmarking` branches, and on all pull requests to `main`.

### Jobs

#### 1. Test Job
- **Elixir version**: 1.17.3 (latest stable)
- **OTP version**: 27.3.4.2 (latest stable)
- Tests compilation, formatting, and code quality
- Runs unit and integration tests
- Generates test coverage reports

#### 2. Performance Tests
- Runs performance benchmarks to validate throughput targets
- Ensures 1000+ msg/s performance is maintained
- Tests latency and memory usage

#### 3. Stress Tests
- Validates concurrency (100+ subscribers)
- Tests multi-topic scenarios
- Resource management under load

#### 4. Recovery Tests
- Crash recovery scenarios
- Supervisor tree resilience
- Graceful degradation testing

#### 5. Security Scan
- Dependency audit for vulnerabilities
- Unused dependency detection

#### 6. Documentation
- Documentation coverage check
- Generates and uploads docs

### Tools Used
- **Credo**: Static code analysis
- **ExCoveralls**: Test coverage reporting
- **ExDoc**: Documentation generation
- **mix_audit**: Security auditing

### Local Testing

Run the same checks locally:

```bash
# Install dependencies
mix deps.get

# Compile with warnings as errors
mix compile --warnings-as-errors

# Format check
mix format --check-formatted

# Static analysis
mix credo --strict

# Unit/integration tests
mix test

# Performance tests
mix test --include performance

# Stress tests  
mix test --include stress

# Recovery tests
mix test --include recovery

# All benchmarks
mix test --include performance --include stress --include recovery

# Test coverage
mix test --cover

# Security audit
mix deps.audit

# Documentation
mix docs
```

### Configuration

The CI is configured through:
- `config/config.exs` - General configuration
- `config/test.exs` - Test environment settings
- `.credo.exs` - Code quality rules
- `mix.exs` - Dependencies and coverage settings