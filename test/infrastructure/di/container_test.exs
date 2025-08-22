defmodule Ratatoskr.Infrastructure.DI.ContainerTest do
  use ExUnit.Case, async: true
  alias Ratatoskr.Infrastructure.DI.Container

  describe "Container.deps/0" do
    test "returns all required dependencies" do
      deps = Container.deps()

      assert is_map(deps)
      assert Map.has_key?(deps, :registry)
      assert Map.has_key?(deps, :storage)
      assert Map.has_key?(deps, :metrics)
      assert Map.has_key?(deps, :event_publisher)
    end

    test "returns proper dependency types" do
      deps = Container.deps()

      # Registry should always be a module
      assert is_atom(deps.registry)
      assert Code.ensure_loaded?(deps.registry)

      # Storage can be nil or a module
      assert is_nil(deps.storage) or (is_atom(deps.storage) and Code.ensure_loaded?(deps.storage))

      # Metrics can be nil or a module in test environment
      assert is_nil(deps.metrics) or (is_atom(deps.metrics) and Code.ensure_loaded?(deps.metrics))

      # Event publisher can be nil or a module
      assert is_nil(deps.event_publisher) or
               (is_atom(deps.event_publisher) and Code.ensure_loaded?(deps.event_publisher))
    end
  end

  describe "Container.test_deps/1" do
    test "returns test dependencies with defaults" do
      deps = Container.test_deps()

      assert is_map(deps)
      assert deps.registry == Ratatoskr.Infrastructure.Registry.ProcessRegistry
      assert is_nil(deps.storage)
      assert is_nil(deps.metrics)
      assert is_nil(deps.event_publisher)
    end

    test "allows overriding specific dependencies" do
      custom_registry = CustomTestRegistry
      custom_storage = CustomTestStorage

      deps =
        Container.test_deps(
          registry: custom_registry,
          storage: custom_storage
        )

      assert deps.registry == custom_registry
      assert deps.storage == custom_storage
      assert is_nil(deps.metrics)
      assert is_nil(deps.event_publisher)
    end
  end

  describe "Container.get/1" do
    test "returns specific dependency by key" do
      deps_map = Container.deps()

      assert Container.get(:registry) == deps_map.registry
      assert Container.get(:storage) == deps_map.storage
      assert Container.get(:metrics) == deps_map.metrics
      assert Container.get(:event_publisher) == deps_map.event_publisher
    end

    test "returns nil for invalid keys" do
      # This should actually raise a FunctionClauseError due to the guard
      assert_raise FunctionClauseError, fn ->
        Container.get(:invalid_key)
      end
    end
  end

  describe "environment handling" do
    test "uses appropriate dependencies for test environment" do
      # In test environment, we should get test-specific defaults
      deps = Container.deps()

      # Should have ProcessRegistry in test
      assert deps.registry == Ratatoskr.Infrastructure.Registry.ProcessRegistry
      # Should have nil metrics in test by default
      assert is_nil(deps.metrics)
    end
  end
end
