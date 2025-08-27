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
    ensure_application_running_with_retry()
  end

  @doc """
  Safely restarts the application, ensuring it's available afterwards.

  Use this when you need a clean application state for testing.
  """
  def safely_restart_application do
    force_stop_application()

    # Wait for complete shutdown including Ranch processes
    wait_for_complete_shutdown()

    # Restart application with retry logic
    case ensure_application_running_with_retry() do
      :ok ->
        # Give time for full startup
        Process.sleep(50)
        :ok

      error ->
        error
    end
  end

  @doc """
  Waits for critical application processes to be available.

  Useful when tests need to ensure specific GenServers are running.
  """
  def wait_for_application_processes(timeout \\ 2000) do
    start_time = System.monotonic_time(:millisecond)

    wait_for_processes(
      [
        Ratatoskr.Infrastructure.DI.Lifecycle,
        Ratatoskr.Registry
      ],
      start_time,
      timeout
    )
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

      {:error,
       {:timeout, missing, %{elapsed: elapsed, app_supervisor_running: app_supervisor_running}}}
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
      force_stop_application()
      wait_for_complete_shutdown()
    end

    :ok
  end

  @doc """
  Performs a complete application stop with thorough cleanup.

  Use this when you need to ensure all processes are completely cleaned up.
  """
  def complete_application_stop do
    force_stop_application()
    wait_for_complete_shutdown()
  end

  @doc """
  Ensures the application is left in a running state after a test.

  Use in test cleanup to prevent affecting subsequent tests.
  """
  def cleanup_application_state do
    case ensure_application_running_with_retry() do
      :ok ->
        # Brief pause to ensure stability
        Process.sleep(25)
        :ok

      error ->
        error
    end
  end

  # Private helper functions for robust Ranch handling

  defp force_stop_application do
    # Stop application gracefully first
    Application.stop(:ratatoskr)

    # Force stop key processes that might not shutdown cleanly
    force_stop_process(Ratatoskr.ApplicationSupervisor)
    force_stop_process(Ratatoskr.Registry)
    force_stop_process(Ratatoskr.Infrastructure.DI.Lifecycle)
    force_stop_process(Ratatoskr.Servers.BrokerServer)
    force_stop_process(Ratatoskr.Infrastructure.Monitoring.MetricsEndpoint)

    # Force stop Ranch listeners that might be hanging
    try do
      :ranch.stop_listener(:"Ratatoskr.Interfaces.Grpc.Server")
    catch
      _, _ -> :ok
    end

    try do
      :ranch.stop_listener(:"Ratatoskr.Infrastructure.Monitoring.MetricsEndpoint.HTTP")
    catch
      _, _ -> :ok
    end

    # Force stop any Cowboy processes that might be lingering
    force_stop_cowboy_processes()
  end

  defp wait_for_complete_shutdown(timeout \\ 2000) do
    start_time = System.monotonic_time(:millisecond)

    wait_for_shutdown_completion(start_time, timeout)
  end

  defp wait_for_shutdown_completion(start_time, timeout) do
    current_time = System.monotonic_time(:millisecond)
    elapsed = current_time - start_time

    if elapsed > timeout do
      :timeout
    else
      check_processes_and_continue_wait(start_time, timeout)
    end
  end

  defp check_processes_and_continue_wait(start_time, timeout) do
    # Check if key processes are actually dead
    key_processes = [
      Ratatoskr.ApplicationSupervisor,
      Ratatoskr.Registry,
      Ratatoskr.Infrastructure.DI.Lifecycle
    ]

    still_running = Enum.filter(key_processes, &Process.whereis/1)

    if Enum.empty?(still_running) do
      check_ranch_and_finalize_shutdown(start_time, timeout)
    else
      sleep_and_retry_wait(start_time, timeout)
    end
  end

  defp check_ranch_and_finalize_shutdown(start_time, timeout) do
    # Also check Ranch server proxy specifically
    case :global.whereis_name(:ranch_server_proxy) do
      :undefined ->
        finalize_shutdown_check(start_time, timeout)

      _pid ->
        sleep_and_retry_wait(start_time, timeout)
    end
  end

  defp finalize_shutdown_check(start_time, timeout) do
    # Also check for any lingering MetricsEndpoint processes
    if metrics_endpoint_processes_alive?() do
      Process.sleep(50)
      wait_for_shutdown_completion(start_time, timeout)
    else
      # Give Ranch extra time to clean up
      Process.sleep(100)
      :ok
    end
  end

  defp sleep_and_retry_wait(start_time, timeout) do
    Process.sleep(50)
    wait_for_shutdown_completion(start_time, timeout)
  end

  defp ensure_application_running_with_retry(retries \\ 3) do
    # Ensure core dependencies are started first
    ensure_dependencies_started()

    case Application.ensure_all_started(:ratatoskr) do
      {:ok, _apps} ->
        :ok

      {:error, {:already_started, _app}} ->
        :ok

      {:error, reason} when retries > 0 ->
        # Check if this is a known `:already_started` issue that can be resolved
        should_log = should_log_retry_error?(reason)

        # Log the retry for debugging (but suppress common already_started issues)
        if Mix.env() == :test and should_log do
          IO.puts(
            "Application start failed (#{inspect(reason)}), retrying... (#{retries} attempts left)"
          )
        end

        # Force clean any lingering Ranch state
        force_clean_ranch_state()

        # Wait a bit longer and try again
        Process.sleep(500)
        ensure_application_running_with_retry(retries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_dependencies_started do
    # Ensure Ranch application is available
    case Application.ensure_all_started(:ranch) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      # Continue even if Ranch fails to start
      {:error, _reason} -> :ok
    end

    # Ensure GRPC dependencies are available
    case Application.ensure_all_started(:grpc) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      # Continue even if GRPC fails to start
      {:error, _reason} -> :ok
    end
  end

  defp force_clean_ranch_state do
    # Kill any lingering Ranch processes that might be causing issues
    try do
      case :global.whereis_name(:ranch_server_proxy) do
        :undefined ->
          :ok

        pid when is_pid(pid) ->
          Process.exit(pid, :kill)
          Process.sleep(100)
      end
    catch
      _, _ -> :ok
    end

    # Clean up any remaining Ranch listeners
    try do
      ranch_listeners = :ranch.info() |> Map.keys()

      Enum.each(ranch_listeners, fn listener ->
        try do
          :ranch.stop_listener(listener)
        catch
          _, _ -> :ok
        end
      end)
    catch
      # Ranch might not be available
      _, _ -> :ok
    end

    # Force stop Cowboy processes that might be lingering
    force_stop_cowboy_http_processes()

    # Also ensure no leftover processes are binding to our test ports
    System.cmd("pkill", ["-f", "4002"], stderr_to_stdout: true)
    System.cmd("pkill", ["-f", "50053"], stderr_to_stdout: true)
    Process.sleep(100)
  end

  defp force_stop_process(process_name) do
    case Process.whereis(process_name) do
      nil ->
        :ok

      pid ->
        try do
          Process.exit(pid, :kill)
        catch
          _, _ -> :ok
        end
    end
  end

  defp force_stop_cowboy_processes do
    # Find any Cowboy/Ranch processes that might be lingering
    Process.list()
    |> Enum.each(fn pid ->
      try do
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} ->
            # Look for Cowboy-related processes
            if Enum.any?(dict, fn {k, v} ->
                 is_atom(k) and (to_string(k) =~ "cowboy" or to_string(v) =~ "cowboy")
               end) do
              Process.exit(pid, :kill)
            end

          _ ->
            :ok
        end
      catch
        _, _ -> :ok
      end
    end)
  end

  defp force_stop_cowboy_http_processes do
    # Specifically target Cowboy HTTP listeners that might be lingering
    kill_registered_cowboy_processes()
    kill_cowboy_processes_by_module()
  end

  defp kill_registered_cowboy_processes do
    # Find Cowboy listeners by looking at registered processes
    Process.registered()
    |> Enum.filter(&cowboy_related_process_name?/1)
    |> Enum.each(&kill_process_by_name/1)
  catch
    _, _ -> :ok
  end

  defp kill_cowboy_processes_by_module do
    # Also target by module/initial_call patterns
    Process.list()
    |> Enum.each(&kill_if_cowboy_module/1)
  end

  defp cowboy_related_process_name?(name) do
    name_str = to_string(name)
    name_str =~ "cowboy" or name_str =~ "ranch" or name_str =~ "acceptor"
  end

  defp kill_process_by_name(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end
  end

  defp kill_if_cowboy_module(pid) do
    case Process.info(pid, :initial_call) do
      {:initial_call, {module, _fun, _arity}} ->
        if cowboy_related_module?(module) do
          Process.exit(pid, :kill)
        end

      _ ->
        :ok
    end
  catch
    _, _ -> :ok
  end

  defp cowboy_related_module?(module) do
    module_str = to_string(module)
    module_str =~ "cowboy" or module_str =~ "ranch" or
      module_str =~ "acceptor" or module_str =~ "listener"
  end

  defp metrics_endpoint_processes_alive? do
    # Check for any processes related to MetricsEndpoint/Cowboy that might be lingering
    Process.list()
    |> Enum.any?(fn pid ->
      try do
        case Process.info(pid, :initial_call) do
          {:initial_call, {module, _fun, _arity}} ->
            module_str = to_string(module)

            module_str =~ "MetricsEndpoint" or module_str =~ "Plug.Cowboy" or
              (module_str =~ "cowboy" and module_str =~ "http")

          _ ->
            false
        end
      catch
        _, _ -> false
      end
    end)
  end

  defp should_log_retry_error?(reason) do
    # Don't log retry messages for known `:already_started` issues that resolve themselves
    case reason do
      {:ratatoskr,
       {{:shutdown,
         {:failed_to_start_child, Ratatoskr.Infrastructure.Monitoring.MetricsEndpoint,
          {:already_started, _pid}}}, _}} ->
        false

      {:ratatoskr, {{:shutdown, {:failed_to_start_child, _child, {:already_started, _pid}}}, _}} ->
        false

      _ ->
        true
    end
  end
end
