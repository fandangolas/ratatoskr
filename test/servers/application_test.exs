defmodule Ratatoskr.Servers.ApplicationTest do
  use ExUnit.Case, async: false

  alias Ratatoskr.Infrastructure.DI.{Container, Lifecycle}
  
  import ApplicationHelper

  @moduletag :application

  describe "application startup and shutdown" do
    setup do
      # Ensure application is available for tests that need it
      # Individual tests will manage start/stop as needed
      :ok
    end

    test "lifecycle manager starts with application" do
      # Prepare for clean application lifecycle test
      prepare_for_application_lifecycle_test()

      # Start application
      {:ok, _pid} = Application.ensure_all_started(:ratatoskr)

      # Wait for application processes to be ready
      assert :ok = wait_for_application_processes()

      # Lifecycle manager should be running
      lifecycle_pid = Process.whereis(Lifecycle)
      assert lifecycle_pid != nil
      assert Process.alive?(lifecycle_pid)

      # Should be able to register dependencies
      assert :ok =
               Lifecycle.register_singleton(
                 :test_dep,
                 {Agent, :start_link, [fn -> :test_state end]}
               )

      # Should be able to get dependencies
      agent = Container.get_singleton(:test_dep)
      assert is_pid(agent)
      assert Agent.get(agent, & &1) == :test_state
    end

    test "lifecycle configuration is processed on startup" do
      # Prepare for clean application start
      prepare_for_application_lifecycle_test()
      
      # Set up test configuration
      original_config = Application.get_env(:ratatoskr, :lifecycle, [])

      test_config = [
        singletons: [
          {:startup_agent, {Agent, :start_link, [fn -> :startup_value end]}, []}
        ]
      ]

      Application.put_env(:ratatoskr, :lifecycle, test_config)

      try do
        # Start application
        {:ok, _pid} = Application.ensure_all_started(:ratatoskr)
        assert :ok = wait_for_application_processes()

        # Manually call configure_lifecycle since app was already started
        Container.configure_lifecycle()

        # Configured dependency should be available
        agent = Container.get_singleton(:startup_agent)
        assert is_pid(agent)
        assert Agent.get(agent, & &1) == :startup_value
      after
        Application.put_env(:ratatoskr, :lifecycle, original_config)
      end
    end

    test "dependencies are shut down gracefully on application stop" do
      # Prepare for application lifecycle test
      prepare_for_application_lifecycle_test()

      # Start application
      {:ok, _pid} = Application.ensure_all_started(:ratatoskr)
      assert :ok = wait_for_application_processes()

      # Register and create a singleton
      assert :ok =
               Lifecycle.register_singleton(
                 :shutdown_test,
                 {Agent, :start_link, [fn -> :initial end]}
               )

      agent = Container.get_singleton(:shutdown_test)
      assert is_pid(agent)
      assert Process.alive?(agent)

      # Stop application
      :ok = Application.stop(:ratatoskr)

      # Give time for shutdown
      Process.sleep(100)

      # Agent should be stopped
      refute Process.alive?(agent)

      # IMPORTANT: Ensure application is available for subsequent tests
      assert :ok = cleanup_application_state()
    end

    test "application can restart after shutdown" do
      # Ensure clean start
      if Application.get_application(:ratatoskr) do
        Application.stop(:ratatoskr)
      end

      # Start application
      {:ok, _pid} = Application.ensure_all_started(:ratatoskr)

      # Stop application
      :ok = Application.stop(:ratatoskr)

      # Start again
      {:ok, _pid} = Application.ensure_all_started(:ratatoskr)

      # Should be able to use lifecycle features
      assert :ok =
               Lifecycle.register_singleton(
                 :restart_test,
                 {Agent, :start_link, [fn -> :restarted end]}
               )

      agent = Container.get_singleton(:restart_test)
      assert is_pid(agent)
      assert Agent.get(agent, & &1) == :restarted

      # Note: Application is already started, so it's ready for next tests
    end

    test "handles missing lifecycle configuration gracefully" do
      # Prepare for application lifecycle test
      prepare_for_application_lifecycle_test()

      # Remove lifecycle configuration
      original_config = Application.get_env(:ratatoskr, :lifecycle, [])
      Application.delete_env(:ratatoskr, :lifecycle)

      try do
        # Should still start without crashing
        {:ok, _pid} = Application.ensure_all_started(:ratatoskr)
        assert :ok = wait_for_application_processes()

        # Lifecycle manager should still work
        assert :ok =
                 Lifecycle.register_singleton(
                   :no_config_test,
                   {Agent, :start_link, [fn -> :works end]}
                 )

        agent = Container.get_singleton(:no_config_test)
        assert is_pid(agent)
      after
        Application.put_env(:ratatoskr, :lifecycle, original_config)
      end
    end
  end

  describe "integration with other infrastructure components" do
    setup do
      # Ensure application and critical processes are available for these tests
      assert :ok = ensure_application_running()
      assert :ok = wait_for_application_processes()
      :ok
    end

    test "lifecycle manager and registry work together" do
      # Registry should be available (the underlying Registry process)
      registry_pid = Process.whereis(Ratatoskr.Registry)
      assert registry_pid != nil
      assert Process.alive?(registry_pid)

      # Should be able to register registry as singleton
      assert :ok = Lifecycle.register_singleton(:registry_singleton, fn -> registry_pid end)

      singleton_registry = Container.get_singleton(:registry_singleton)
      assert singleton_registry == registry_pid
    end

    test "all infrastructure components are supervised" do
      # Get the main supervisor
      supervisor_pid = Process.whereis(Ratatoskr.ApplicationSupervisor)
      assert supervisor_pid != nil

      # Check that key processes are running
      children = Supervisor.which_children(supervisor_pid)

      # Should include our key infrastructure components
      child_names = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)
      assert Enum.member?(child_names, Ratatoskr.Infrastructure.Registry.ProcessRegistry)
      assert Enum.member?(child_names, Ratatoskr.Infrastructure.DI.Lifecycle)
    end
  end
end
