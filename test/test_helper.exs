ExUnit.start()

# Exclude performance and stress tests by default
# Run them explicitly with: mix test --include performance
# or: mix test --include stress --include recovery
ExUnit.configure(exclude: [:performance, :stress, :recovery])
