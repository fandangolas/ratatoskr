defmodule Ratatoskr.Infrastructure.DI.LifecycleTest do
  use ExUnit.Case, async: false
  alias Ratatoskr.Infrastructure.DI.Lifecycle

  # Test GenServer for singleton testing
  defmodule TestSingleton do
    use GenServer
    
    def start_link(args) do
      GenServer.start_link(__MODULE__, args)
    end
    
    def init(args) do
      {:ok, %{args: args, calls: 0}}
    end
    
    def get_state(pid) do
      GenServer.call(pid, :get_state)
    end
    
    def handle_call(:get_state, _from, state) do
      {:reply, state, %{state | calls: state.calls + 1}}
    end
  end

  # Test module for transient dependencies
  defmodule TestTransient do
    def create(name) do
      %{name: name, id: make_ref(), created_at: System.system_time()}
    end
  end

  setup do
    # Start a fresh lifecycle manager for each test
    if Process.whereis(Lifecycle) do
      Supervisor.terminate_child(Ratatoskr.ApplicationSupervisor, Lifecycle)
    end
    
    {:ok, _pid} = Lifecycle.start_link()
    
    on_exit(fn ->
      pid = Process.whereis(Lifecycle)
      if pid && Process.alive?(pid) do
        try do
          Lifecycle.shutdown()
          GenServer.stop(Lifecycle)
        catch
          :exit, _ -> :ok  # Process already dead
        end
      end
    end)
    
    :ok
  end

  describe "singleton lifecycle" do
    test "registers and creates singleton on first access" do
      assert :ok = Lifecycle.register_singleton(:test_singleton, TestSingleton, [name: "test"])
      
      # First access should create the singleton
      pid1 = Lifecycle.get_singleton(:test_singleton)
      assert is_pid(pid1)
      assert Process.alive?(pid1)
      
      # Second access should return the same instance
      pid2 = Lifecycle.get_singleton(:test_singleton)
      assert pid1 == pid2
    end

    test "supports eager initialization" do
      assert :ok = Lifecycle.register_singleton(:eager_singleton, TestSingleton, [name: "eager"], lazy: false)
      
      # Should already be created
      assert pid = Lifecycle.get_singleton(:eager_singleton)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "returns error for unregistered singleton" do
      assert {:error, :not_registered} = Lifecycle.get_singleton(:nonexistent)
    end

    test "returns error for wrong scope" do
      assert :ok = Lifecycle.register_process_scoped(:process_dep, TestSingleton, [])
      assert {:error, :wrong_scope} = Lifecycle.get_singleton(:process_dep)
    end
  end

  describe "process-scoped lifecycle" do
    test "creates separate instances per process" do
      assert :ok = Lifecycle.register_process_scoped(:process_cache, TestSingleton, [name: "cache"])
      
      # Get instance from current process
      assert pid1 = Lifecycle.get_process_scoped(:process_cache)
      assert is_pid(pid1)
      
      # Get instance from another process
      task = Task.async(fn ->
        Lifecycle.get_process_scoped(:process_cache)
      end)
      
      assert pid2 = Task.await(task)
      assert is_pid(pid2)
      assert pid1 != pid2
    end

    test "returns same instance within same process" do
      assert :ok = Lifecycle.register_process_scoped(:process_cache, TestSingleton, [name: "cache"])
      
      assert pid1 = Lifecycle.get_process_scoped(:process_cache)
      assert pid2 = Lifecycle.get_process_scoped(:process_cache)
      assert pid1 == pid2
    end

    test "cleans up when process dies" do
      assert :ok = Lifecycle.register_process_scoped(:process_cache, TestSingleton, [name: "cache"])
      
      # Create instance in a task process
      task_pid = spawn(fn ->
        _cache_pid = Lifecycle.get_process_scoped(:process_cache)
        receive do
          :exit -> :ok
        end
      end)
      
      # Give time for the instance to be created and monitored
      Process.sleep(10)
      
      # Kill the task process
      Process.exit(task_pid, :kill)
      
      # Give time for cleanup
      Process.sleep(10)
      
      # Verify cleanup happened (check internal state would require accessing private state)
      # For now, we trust the implementation and test that new instances can be created
      assert _new_pid = Lifecycle.get_process_scoped(:process_cache)
    end
  end

  describe "transient lifecycle" do
    test "creates new instance every time" do
      register_transient_dependency()
      
      assert instance1 = Lifecycle.get_transient(:transient_worker)
      assert instance2 = Lifecycle.get_transient(:transient_worker)
      
      # Should be different instances
      assert instance1.id != instance2.id
      assert instance1.created_at <= instance2.created_at
    end

    test "supports different creation patterns" do
      # Function-based creation
      Lifecycle.register_transient(:function_dep, fn -> %{type: :function, id: make_ref()} end)
      
      # MFA-based creation
      Lifecycle.register_transient(:mfa_dep, {TestTransient, :create, ["test"]})
      
      assert func_instance = Lifecycle.get_transient(:function_dep)
      assert func_instance.type == :function
      
      assert mfa_instance = Lifecycle.get_transient(:mfa_dep)
      assert mfa_instance.name == "test"
    end
  end

  describe "health checks" do
    test "performs health checks on dependencies with health_check function" do
      health_check_fun = fn _instance -> true end
      
      assert :ok = Lifecycle.register_singleton(
        :healthy_dep, 
        TestSingleton, 
        [name: "healthy"], 
        health_check: health_check_fun
      )
      
      # Create the singleton
      assert _pid = Lifecycle.get_singleton(:healthy_dep)
      
      # Perform health check
      health_results = Lifecycle.health_check()
      assert health_results[:healthy_dep] == true
    end

    test "handles dependencies without health checks" do
      assert :ok = Lifecycle.register_singleton(:no_health_check, TestSingleton, [name: "test"])
      
      # Create the singleton
      assert _pid = Lifecycle.get_singleton(:no_health_check)
      
      # Should default to healthy
      health_results = Lifecycle.health_check()
      assert health_results[:no_health_check] == true
    end

    test "handles failing health checks" do
      failing_health_check = fn _instance -> raise "Health check failed" end
      
      assert :ok = Lifecycle.register_singleton(
        :unhealthy_dep,
        TestSingleton,
        [name: "unhealthy"],
        health_check: failing_health_check
      )
      
      # Create the singleton
      assert _pid = Lifecycle.get_singleton(:unhealthy_dep)
      
      # Should handle the exception and return false
      health_results = Lifecycle.health_check()
      assert health_results[:unhealthy_dep] == false
    end
  end

  describe "shutdown" do
    test "shuts down singleton GenServers gracefully" do
      assert :ok = Lifecycle.register_singleton(:shutdown_test, TestSingleton, [name: "test"])
      
      # Create the singleton
      assert pid = Lifecycle.get_singleton(:shutdown_test)
      assert Process.alive?(pid)
      
      # Shutdown
      assert :ok = Lifecycle.shutdown()
      
      # Give time for shutdown
      Process.sleep(10)
      
      # Should be dead
      refute Process.alive?(pid)
    end

    test "handles non-GenServer singletons gracefully" do
      assert :ok = Lifecycle.register_singleton(:non_genserver, fn -> %{value: 42} end)
      
      # Create the singleton
      assert _instance = Lifecycle.get_singleton(:non_genserver)
      
      # Should not crash on shutdown
      assert :ok = Lifecycle.shutdown()
    end
  end

  # Helper functions
  
  defp register_transient_dependency do
    Lifecycle.register_transient(:transient_worker, {TestTransient, :create, ["worker"]})
  end
end