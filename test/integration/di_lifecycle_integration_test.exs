defmodule Ratatoskr.Integration.DILifecycleIntegrationTest do
  use ExUnit.Case, async: false

  alias Ratatoskr.Infrastructure.DI.{Container, Lifecycle}
  alias Ratatoskr.Infrastructure.Registry.ProcessRegistry
  
  import ApplicationHelper

  @moduletag :integration

  setup do
    # Ensure the application and critical processes are available
    assert :ok = ensure_application_running()
    assert :ok = wait_for_application_processes()

    on_exit(fn ->
      try do
        # Just shutdown managed dependencies, don't stop core processes
        Container.shutdown()
        
        # Don't manually stop Lifecycle or Registry - let application manage them
        # This prevents interference with other tests
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "integration with real infrastructure dependencies" do
    test "can register and use ProcessRegistry as singleton" do
      # Register ProcessRegistry as a singleton
      assert :ok =
               Lifecycle.register_singleton(
                 :registry,
                 ProcessRegistry,
                 [],
                 health_check: &Process.alive?/1
               )

      # Get the singleton
      registry = Container.get_singleton(:registry)
      assert is_pid(registry)
      assert Process.alive?(registry)

      # Use the registry
      assert :ok = ProcessRegistry.register_topic("test_topic", self())
      assert {:ok, pid} = ProcessRegistry.lookup_topic("test_topic")
      assert pid == self()
    end

    test "can register and use a test GenServer as singleton with health check" do
      # Create a test GenServer for metrics-like functionality
      defmodule TestMetrics do
        use GenServer

        def start_link(_args), do: GenServer.start_link(__MODULE__, %{events: []})
        def record_event(pid, event, data), do: GenServer.cast(pid, {:record, event, data})
        def get_events(pid), do: GenServer.call(pid, :get_events)
        def health_check(pid), do: GenServer.call(pid, :health_check)

        def init(state), do: {:ok, state}

        def handle_cast({:record, event, data}, state) do
          events = [{event, data} | state.events]
          {:noreply, %{state | events: events}}
        end

        def handle_call(:get_events, _from, state), do: {:reply, state.events, state}
        def handle_call(:health_check, _from, state), do: {:reply, :ok, state}
      end

      # Register TestMetrics as singleton with health check
      health_check = fn pid ->
        try do
          Process.alive?(pid) && TestMetrics.health_check(pid) == :ok
        rescue
          _ -> false
        end
      end

      assert :ok =
               Lifecycle.register_singleton(
                 :metrics,
                 TestMetrics,
                 [],
                 health_check: health_check
               )

      # Get the singleton
      metrics = Container.get_singleton(:metrics)
      assert is_pid(metrics)

      # Verify it works
      TestMetrics.record_event(metrics, "test_event", %{value: 42})
      events = TestMetrics.get_events(metrics)
      assert events == [{"test_event", %{value: 42}}]

      # Health check should pass
      health_results = Container.health_check()
      assert health_results[:metrics] == true
    end

    test "process-scoped dependencies are isolated between processes" do
      # Register a process-scoped ETS table manager
      defmodule ETSManager do
        use GenServer

        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts)
        end

        def init(opts) do
          table_name = Keyword.get(opts, :table_name, :default_table)
          table = :ets.new(table_name, [:set, :private])
          {:ok, %{table: table, name: table_name}}
        end

        def put(pid, key, value) do
          GenServer.call(pid, {:put, key, value})
        end

        def get(pid, key) do
          GenServer.call(pid, {:get, key})
        end

        def handle_call({:put, key, value}, _from, state) do
          :ets.insert(state.table, {key, value})
          {:reply, :ok, state}
        end

        def handle_call({:get, key}, _from, state) do
          case :ets.lookup(state.table, key) do
            [{^key, value}] -> {:reply, {:ok, value}, state}
            [] -> {:reply, {:error, :not_found}, state}
          end
        end
      end

      # Register ETS manager as process-scoped
      assert :ok =
               Lifecycle.register_process_scoped(
                 :ets_manager,
                 ETSManager,
                 table_name: :process_table
               )

      # Get manager from current process
      manager1 = Container.get_process_scoped(:ets_manager)
      assert is_pid(manager1)

      # Store some data
      assert :ok = ETSManager.put(manager1, :key1, "value1")
      assert {:ok, "value1"} = ETSManager.get(manager1, :key1)

      # Get manager from different process
      task =
        Task.async(fn ->
          manager2 = Container.get_process_scoped(:ets_manager)

          # Should be different manager
          assert manager2 != manager1

          # Should not see data from other process
          assert {:error, :not_found} = ETSManager.get(manager2, :key1)

          # Can store its own data
          assert :ok = ETSManager.put(manager2, :key2, "value2")
          assert {:ok, "value2"} = ETSManager.get(manager2, :key2)

          manager2
        end)

      _manager2 = Task.await(task)

      # Original manager should not see data from task
      assert {:error, :not_found} = ETSManager.get(manager1, :key2)
      assert {:ok, "value1"} = ETSManager.get(manager1, :key1)
    end

    test "transient dependencies create fresh instances each time" do
      # Register a transient connection factory
      defmodule ConnectionFactory do
        def create_connection(host) do
          %{
            id: make_ref(),
            host: host,
            connected_at: System.system_time(:millisecond),
            status: :connected
          }
        end
      end

      assert :ok =
               Lifecycle.register_transient(
                 :connection,
                 {ConnectionFactory, :create_connection, ["localhost"]}
               )

      # Create multiple connections
      conn1 = Container.get_transient(:connection)
      conn2 = Container.get_transient(:connection)
      conn3 = Container.get_transient(:connection)

      # Should all be different
      assert conn1.id != conn2.id
      assert conn2.id != conn3.id
      assert conn1.id != conn3.id

      # But have same host
      assert conn1.host == conn2.host
      assert conn2.host == conn3.host

      # Created at different times
      assert conn1.connected_at <= conn2.connected_at
      assert conn2.connected_at <= conn3.connected_at
    end

    test "dependencies work together in complex scenarios" do
      # Register multiple dependencies that work together

      # Singleton event bus
      defmodule EventBus do
        use GenServer

        def start_link(_) do
          GenServer.start_link(__MODULE__, %{subscribers: []})
        end

        def subscribe(pid, subscriber) do
          GenServer.cast(pid, {:subscribe, subscriber})
        end

        def publish(pid, event) do
          GenServer.cast(pid, {:publish, event})
        end

        def init(state), do: {:ok, state}

        def handle_cast({:subscribe, subscriber}, state) do
          {:noreply, %{state | subscribers: [subscriber | state.subscribers]}}
        end

        def handle_cast({:publish, event}, state) do
          Enum.each(state.subscribers, fn subscriber ->
            send(subscriber, {:event, event})
          end)

          {:noreply, state}
        end
      end

      # Process-scoped event handler
      defmodule EventHandler do
        use GenServer

        def start_link(handler_type) do
          GenServer.start_link(__MODULE__, %{type: handler_type, events: []})
        end

        def get_events(pid) do
          GenServer.call(pid, :get_events)
        end

        def init(state), do: {:ok, state}

        def handle_info({:event, event}, state) do
          new_events = [event | state.events]
          {:noreply, %{state | events: new_events}}
        end

        def handle_call(:get_events, _from, state) do
          {:reply, Enum.reverse(state.events), state}
        end
      end

      # Register dependencies
      assert :ok = Lifecycle.register_singleton(:event_bus, EventBus, [])
      assert :ok = Lifecycle.register_process_scoped(:event_handler, EventHandler, ["main"])

      # Get instances
      bus = Container.get_singleton(:event_bus)
      handler = Container.get_process_scoped(:event_handler)

      # Subscribe handler to bus
      EventBus.subscribe(bus, handler)

      # Publish events
      EventBus.publish(bus, %{type: "user_login", user_id: 123})
      EventBus.publish(bus, %{type: "order_created", order_id: 456})

      # Give time for messages to process
      Process.sleep(10)

      # Check events were received
      events = EventHandler.get_events(handler)
      assert length(events) == 2
      assert Enum.any?(events, &(&1.type == "user_login"))
      assert Enum.any?(events, &(&1.type == "order_created"))
    end
  end

  describe "error handling and resilience" do
    test "handles dependency crashes gracefully" do
      # Register a crashy singleton
      defmodule CrashyService do
        use GenServer

        def start_link(_) do
          GenServer.start_link(__MODULE__, %{crash_count: 0})
        end

        def crash_me(pid) do
          GenServer.call(pid, :crash)
        end

        def init(state), do: {:ok, state}

        def handle_call(:crash, _from, _state) do
          # Crash the process
          raise "Intentional crash for testing"
        end
      end

      assert :ok = Lifecycle.register_singleton(:crashy, CrashyService, [])

      # Get the singleton
      crashy = Container.get_singleton(:crashy)
      assert is_pid(crashy)

      # Crash it - this will cause the GenServer to exit
      try do
        CrashyService.crash_me(crashy)
      catch
        # Expected exit from GenServer.call
        :exit, _ -> :ok
      end

      # Give some time for the process to die
      Process.sleep(10)

      # Process should be dead
      refute Process.alive?(crashy)

      # Getting singleton again should create a new instance
      crashy2 = Container.get_singleton(:crashy)
      assert is_pid(crashy2)
      assert crashy != crashy2
      assert Process.alive?(crashy2)
    end

    test "health checks detect unhealthy dependencies" do
      # Register singleton with failing health check
      failing_health_check = fn _pid -> false end

      assert :ok =
               Lifecycle.register_singleton(
                 :unhealthy,
                 ProcessRegistry,
                 [],
                 health_check: failing_health_check
               )

      # Create the singleton
      _unhealthy = Container.get_singleton(:unhealthy)

      # Health check should fail
      health_results = Container.health_check()
      assert health_results[:unhealthy] == false
    end
  end

  describe "configuration-based lifecycle" do
    test "configure_lifecycle processes application configuration" do
      # Set up some configuration
      original_config = Application.get_env(:ratatoskr, :lifecycle, [])

      test_config = [
        singletons: [
          {:test_registry, ProcessRegistry, []}
        ],
        process_scoped: [
          # Using ProcessRegistry as a dummy cache
          {:test_cache, ProcessRegistry, []}
        ]
      ]

      Application.put_env(:ratatoskr, :lifecycle, test_config)

      try do
        # Configure lifecycle from application config
        assert :ok = Container.configure_lifecycle()

        # Test that singletons are registered
        registry = Container.get_singleton(:test_registry)
        assert is_pid(registry)

        # Test that process-scoped is registered
        cache = Container.get_process_scoped(:test_cache)
        assert is_pid(cache)
      after
        # Restore original config
        Application.put_env(:ratatoskr, :lifecycle, original_config)
      end
    end
  end
end
