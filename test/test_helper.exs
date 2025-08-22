ExUnit.start()

# Exclude performance, stress, and benchmark tests by default
# Run them explicitly with: mix test --include performance
# or: mix test --include stress --include recovery --include benchmark
ExUnit.configure(
  exclude: [:performance, :stress, :recovery, :benchmark, :grpc_benchmark]
)
