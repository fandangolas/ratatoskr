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

  describe "lifecycle management" do
    setup do
      # Ensure lifecycle manager is running
      unless Process.whereis(Ratatoskr.Infrastructure.DI.Lifecycle) do
        {:ok, _pid} = Ratatoskr.Infrastructure.DI.Lifecycle.start_link()
      end

      :ok
    end

    test "get_singleton delegates to lifecycle manager" do
      # Mock a singleton registration (would normally be done in config)
      alias Ratatoskr.Infrastructure.DI.Lifecycle

      defmodule TestSingleton do
        def start_link(_args), do: {:ok, spawn(fn -> :timer.sleep(1000) end)}
      end

      Lifecycle.register_singleton(:test_singleton, TestSingleton, [])

      # Should delegate to lifecycle manager
      result = Container.get_singleton(:test_singleton)
      assert is_pid(result)
    end

    test "get_process_scoped delegates to lifecycle manager" do
      alias Ratatoskr.Infrastructure.DI.Lifecycle

      defmodule TestProcessScoped do
        def start_link(_args), do: {:ok, spawn(fn -> :timer.sleep(1000) end)}
      end

      Lifecycle.register_process_scoped(:test_process_scoped, TestProcessScoped, [])

      # Should delegate to lifecycle manager
      result = Container.get_process_scoped(:test_process_scoped)
      assert is_pid(result)
    end

    test "get_transient delegates to lifecycle manager" do
      alias Ratatoskr.Infrastructure.DI.Lifecycle

      defmodule TestTransient do
        def create(name), do: %{name: name, id: make_ref()}
      end

      Lifecycle.register_transient(:test_transient, {TestTransient, :create, ["test"]})

      # Should delegate to lifecycle manager
      result1 = Container.get_transient(:test_transient)
      result2 = Container.get_transient(:test_transient)

      assert result1.name == "test"
      assert result2.name == "test"
      assert result1.id != result2.id
    end

    test "health_check delegates to lifecycle manager" do
      result = Container.health_check()
      assert is_map(result)
    end

    test "configure_lifecycle processes application configuration" do
      # This would normally read from application config
      # For testing, we verify it doesn't crash
      assert :ok = Container.configure_lifecycle()
    end

    test "shutdown delegates to lifecycle manager" do
      # Should not crash even if no dependencies are registered
      assert :ok = Container.shutdown()
    end
  end

  describe "error handling" do
    test "gracefully handles lifecycle manager not running" do
      # Stop lifecycle manager
      pid = Process.whereis(Ratatoskr.Infrastructure.DI.Lifecycle)

      if pid && Process.alive?(pid) do
        GenServer.stop(pid)
      end

      # Calls should return errors instead of crashing
      assert {:error, _} = Container.get_singleton(:nonexistent)
      assert {:error, _} = Container.get_process_scoped(:nonexistent)
      assert {:error, _} = Container.get_transient(:nonexistent)
    end

    test "handles invalid dependency keys" do
      # Restart lifecycle manager if needed
      unless Process.whereis(Ratatoskr.Infrastructure.DI.Lifecycle) do
        {:ok, _} = Ratatoskr.Infrastructure.DI.Lifecycle.start_link()
      end

      assert {:error, :not_registered} = Container.get_singleton(:invalid_key)
      assert {:error, :not_registered} = Container.get_process_scoped(:invalid_key)
      assert {:error, :not_registered} = Container.get_transient(:invalid_key)
    end
  end

  describe "lifecycle configuration edge cases" do
    test "handles empty configuration" do
      original_config = Application.get_env(:ratatoskr, :lifecycle, [])

      # Set empty config
      Application.put_env(:ratatoskr, :lifecycle, [])

      try do
        assert :ok = Container.configure_lifecycle()
      after
        Application.put_env(:ratatoskr, :lifecycle, original_config)
      end
    end

    test "handles malformed configuration gracefully" do
      original_config = Application.get_env(:ratatoskr, :lifecycle, [])

      # Set malformed config
      malformed_config = [
        singletons: [
          # Should have at least {key, module}
          :invalid_tuple,
          {:valid_key, ValidModule, []}
        ],
        process_scoped: "not_a_list"
      ]

      Application.put_env(:ratatoskr, :lifecycle, malformed_config)

      try do
        # Should not crash, might log warnings
        assert :ok = Container.configure_lifecycle()
      after
        Application.put_env(:ratatoskr, :lifecycle, original_config)
      end
    end
  end
end
