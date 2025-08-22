defmodule ApplicationHelper do
  @moduledoc """
  Helper functions for managing application state in tests.
  
  Provides consistent and safe application lifecycle management
  to prevent test isolation issues.
  """

  @doc """
  Ensures the Ratatoskr application is running.
  
  Safe to call multiple times - won't restart if already running.
  """
  def ensure_application_running do
    case Application.ensure_all_started(:ratatoskr) do
      {:ok, _apps} -> :ok
      {:error, {:already_started, _app}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Safely restarts the application, ensuring it's available afterwards.
  
  Use this when you need a clean application state for testing.
  """
  def safely_restart_application do
    Application.stop(:ratatoskr)
    
    # Brief pause to ensure clean shutdown
    Process.sleep(10)
    
    # Restart application
    case ensure_application_running() do
      :ok -> 
        # Give time for full startup
        Process.sleep(10)
        :ok
      error -> error
    end
  end

  @doc """
  Waits for critical application processes to be available.
  
  Useful when tests need to ensure specific GenServers are running.
  """
  def wait_for_application_processes(timeout \\ 2000) do
    start_time = System.monotonic_time(:millisecond)
    
    wait_for_processes([
      Ratatoskr.Infrastructure.DI.Lifecycle,
      Ratatoskr.Registry
    ], start_time, timeout)
  end

  defp wait_for_processes([], _start_time, _timeout), do: :ok
  
  defp wait_for_processes(processes, start_time, timeout) do
    current_time = System.monotonic_time(:millisecond)
    elapsed = current_time - start_time
    
    if elapsed > timeout do
      # Try to provide more debug info on timeout
      available = Enum.filter(processes, &Process.whereis/1)
      missing = processes -- available
      
      # Check if the application supervisor is running
      app_supervisor_running = Process.whereis(Ratatoskr.ApplicationSupervisor) != nil
      
      {:error, {:timeout, missing, %{elapsed: elapsed, app_supervisor_running: app_supervisor_running}}}
    else
      available = Enum.filter(processes, &Process.whereis/1)
      missing = processes -- available
      
      if Enum.empty?(missing) do
        :ok
      else
        Process.sleep(10)
        wait_for_processes(missing, start_time, timeout)
      end
    end
  end

  @doc """
  Prepares application state for a test that needs to control application lifecycle.
  
  This function:
  1. Stops the application if running
  2. Gives time for clean shutdown
  3. Is ready for the test to start the application as needed
  """
  def prepare_for_application_lifecycle_test do
    if Application.get_application(:ratatoskr) do
      Application.stop(:ratatoskr)
      Process.sleep(10)
    end
    :ok
  end

  @doc """
  Ensures the application is left in a running state after a test.
  
  Use in test cleanup to prevent affecting subsequent tests.
  """
  def cleanup_application_state do
    case ensure_application_running() do
      :ok -> 
        # Brief pause to ensure stability
        Process.sleep(5)
        :ok
      error -> error
    end
  end
end