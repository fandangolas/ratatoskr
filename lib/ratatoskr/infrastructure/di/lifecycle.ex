defmodule Ratatoskr.Infrastructure.DI.Lifecycle do
  @moduledoc """
  Lifecycle management for dependency injection.

  Handles different dependency scopes and initialization patterns:
  - Singleton: One instance per application
  - Transient: New instance every time  
  - Process-scoped: One instance per process
  - Request-scoped: One instance per request/operation

  ## Usage

      # Register a singleton
      Lifecycle.register_singleton(:metrics, MyMetrics, [])
      
      # Get singleton instance
      metrics = Lifecycle.get_singleton(:metrics)
      
      # Register process-scoped dependency
      Lifecycle.register_process_scoped(:cache, MyCache, [])
  """

  use GenServer
  require Logger

  @type scope :: :singleton | :transient | :process_scoped | :request_scoped
  @type dependency_key :: atom()
  @type module_or_fun :: module() | (-> term()) | {module(), atom(), list()}

  @type dependency_config :: %{
          key: dependency_key(),
          scope: scope(),
          implementation: module_or_fun(),
          args: list(),
          lazy: boolean(),
          health_check: (-> boolean()) | nil
        }

  defstruct [
    # %{key => instance}
    :singletons,
    # %{pid => %{key => instance}}
    :process_scoped,
    # %{key => dependency_config}
    :configs,
    # %{key => last_check_result}
    :health_checks
  ]

  # Public API

  @doc """
  Starts the lifecycle manager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a singleton dependency.
  """
  @spec register_singleton(dependency_key(), module_or_fun(), list(), keyword()) :: :ok
  def register_singleton(key, implementation, args \\ [], opts \\ []) do
    config = %{
      key: key,
      scope: :singleton,
      implementation: implementation,
      args: args,
      lazy: Keyword.get(opts, :lazy, true),
      health_check: Keyword.get(opts, :health_check)
    }

    GenServer.call(__MODULE__, {:register, config})
  end

  @doc """
  Registers a process-scoped dependency.
  """
  @spec register_process_scoped(dependency_key(), module_or_fun(), list(), keyword()) :: :ok
  def register_process_scoped(key, implementation, args \\ [], opts \\ []) do
    config = %{
      key: key,
      scope: :process_scoped,
      implementation: implementation,
      args: args,
      lazy: Keyword.get(opts, :lazy, true),
      health_check: Keyword.get(opts, :health_check)
    }

    GenServer.call(__MODULE__, {:register, config})
  end

  @doc """
  Registers a transient dependency.
  """
  @spec register_transient(dependency_key(), module_or_fun(), list(), keyword()) :: :ok
  def register_transient(key, implementation, args \\ [], opts \\ []) do
    config = %{
      key: key,
      scope: :transient,
      implementation: implementation,
      args: args,
      # Transients are always lazy
      lazy: true,
      health_check: Keyword.get(opts, :health_check)
    }

    GenServer.call(__MODULE__, {:register, config})
  end

  @doc """
  Gets a singleton instance, creating it if needed.
  """
  @spec get_singleton(dependency_key()) :: term() | {:error, term()}
  def get_singleton(key) do
    case GenServer.call(__MODULE__, {:get_singleton, key}) do
      {:ok, instance} -> instance
      {:error, reason} -> {:error, reason}
      # Direct return for compatibility
      instance -> instance
    end
  end

  @doc """
  Gets a process-scoped instance for the calling process.
  """
  @spec get_process_scoped(dependency_key()) :: term() | {:error, term()}
  def get_process_scoped(key) do
    case GenServer.call(__MODULE__, {:get_process_scoped, key, self()}) do
      {:ok, instance} -> instance
      {:error, reason} -> {:error, reason}
      # Direct return for compatibility
      instance -> instance
    end
  end

  @doc """
  Creates a new transient instance.
  """
  @spec get_transient(dependency_key()) :: term() | {:error, term()}
  def get_transient(key) do
    case GenServer.call(__MODULE__, {:get_transient, key}) do
      {:ok, instance} -> instance
      {:error, reason} -> {:error, reason}
      # Direct return for compatibility
      instance -> instance
    end
  end

  @doc """
  Performs health checks on all registered dependencies.
  """
  @spec health_check() :: %{dependency_key() => boolean()}
  def health_check do
    GenServer.call(__MODULE__, :health_check)
  end

  @doc """
  Clears process-scoped dependencies for a specific process.
  """
  @spec cleanup_process(pid()) :: :ok
  def cleanup_process(pid) do
    GenServer.cast(__MODULE__, {:cleanup_process, pid})
  end

  @doc """
  Shuts down all singletons gracefully.
  """
  @spec shutdown() :: :ok
  def shutdown do
    GenServer.call(__MODULE__, :shutdown)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Monitor process exits to cleanup process-scoped dependencies
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      singletons: %{},
      process_scoped: %{},
      configs: %{},
      health_checks: %{}
    }

    Logger.info("DI Lifecycle manager started")
    {:ok, state}
  end

  @impl true
  def handle_call({:register, config}, _from, state) do
    new_configs = Map.put(state.configs, config.key, config)
    new_state = %{state | configs: new_configs}

    Logger.debug("Registered dependency: #{config.key} (#{config.scope})")

    # If not lazy, create singleton immediately
    if config.scope == :singleton and not config.lazy do
      case create_instance(config) do
        {:ok, instance} ->
          new_singletons = Map.put(state.singletons, config.key, instance)
          {:reply, :ok, %{new_state | singletons: new_singletons}}

        {:error, reason} ->
          Logger.error("Failed to create eager singleton #{config.key}: #{inspect(reason)}")
          {:reply, {:error, reason}, new_state}
      end
    else
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:get_singleton, key}, _from, state) do
    case Map.get(state.singletons, key) do
      nil ->
        # Create singleton if it doesn't exist
        create_singleton_instance(key, state)

      instance ->
        # Check if cached instance is still alive (for pid instances)
        if is_pid(instance) and not Process.alive?(instance) do
          # Instance died, remove from cache and create new one
          new_singletons = Map.delete(state.singletons, key)
          new_state = %{state | singletons: new_singletons}
          create_singleton_instance(key, new_state)
        else
          {:reply, {:ok, instance}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_process_scoped, key, pid}, _from, state) do
    process_deps = Map.get(state.process_scoped, pid, %{})

    case Map.get(process_deps, key) do
      nil ->
        case Map.get(state.configs, key) do
          nil ->
            {:reply, {:error, :not_registered}, state}

          config when config.scope != :process_scoped ->
            {:reply, {:error, :wrong_scope}, state}

          config ->
            case create_instance(config) do
              {:ok, instance} ->
                # Monitor the process for cleanup
                Process.monitor(pid)

                new_process_deps = Map.put(process_deps, key, instance)
                new_process_scoped = Map.put(state.process_scoped, pid, new_process_deps)
                new_state = %{state | process_scoped: new_process_scoped}

                {:reply, {:ok, instance}, new_state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end
        end

      instance ->
        {:reply, {:ok, instance}, state}
    end
  end

  @impl true
  def handle_call({:get_transient, key}, _from, state) do
    case Map.get(state.configs, key) do
      nil ->
        {:reply, {:error, :not_registered}, state}

      config ->
        case create_instance(config) do
          {:ok, instance} ->
            {:reply, {:ok, instance}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    health_results =
      state.configs
      |> Enum.map(fn {key, config} ->
        result = perform_health_check(key, config, state)
        {key, result}
      end)
      |> Map.new()

    new_state = %{state | health_checks: health_results}
    {:reply, health_results, new_state}
  end

  @impl true
  def handle_call(:shutdown, _from, state) do
    # Shutdown all singletons that support it
    Enum.each(state.singletons, fn {key, instance} ->
      shutdown_instance(key, instance)
    end)

    {:reply, :ok, state}
  end

  defp create_singleton_instance(key, state) do
    case Map.get(state.configs, key) do
      nil ->
        {:reply, {:error, :not_registered}, state}

      config when config.scope != :singleton ->
        {:reply, {:error, :wrong_scope}, state}

      config ->
        case create_instance(config) do
          {:ok, instance} ->
            new_singletons = Map.put(state.singletons, key, instance)
            new_state = %{state | singletons: new_singletons}
            {:reply, {:ok, instance}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_cast({:cleanup_process, pid}, state) do
    new_process_scoped = Map.delete(state.process_scoped, pid)
    new_state = %{state | process_scoped: new_process_scoped}

    Logger.debug("Cleaned up process-scoped dependencies for #{inspect(pid)}")
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Automatically cleanup when monitored process dies
    new_process_scoped = Map.delete(state.process_scoped, pid)
    new_state = %{state | process_scoped: new_process_scoped}

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    # Handle EXIT messages from linked processes (trap_exit is enabled)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    # Ignore unknown messages
    {:noreply, state}
  end

  # Private Functions

  defp create_instance(%{implementation: module, args: args}) when is_atom(module) do
    try do
      case module.start_link(args) do
        {:ok, pid} -> {:ok, pid}
        {:ok, pid, _info} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
        result -> {:ok, result}
      end
    rescue
      error -> {:error, error}
    end
  end

  defp create_instance(%{implementation: {module, function, base_args}, args: extra_args}) do
    try do
      case apply(module, function, base_args ++ extra_args) do
        {:ok, instance} -> {:ok, instance}
        {:ok, instance, _info} -> {:ok, instance}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
        result -> {:ok, result}
      end
    rescue
      error -> {:error, error}
    end
  end

  defp create_instance(%{implementation: fun, args: args}) when is_function(fun) do
    try do
      result = apply(fun, args)
      {:ok, result}
    rescue
      error -> {:error, error}
    end
  end

  defp perform_health_check(_key, %{health_check: nil}, _state) do
    # No health check defined, assume healthy
    true
  end

  defp perform_health_check(key, %{health_check: health_fun}, state)
       when is_function(health_fun) do
    try do
      # Get the instance to check
      instance =
        case Map.get(state.singletons, key) do
          nil -> nil
          inst -> inst
        end

      health_fun.(instance)
    rescue
      _ -> false
    end
  end

  defp shutdown_instance(key, instance) when is_pid(instance) do
    if Process.alive?(instance) do
      Logger.debug("Shutting down singleton #{key}")

      try do
        # Use Process.exit for more reliable shutdown
        Process.exit(instance, :shutdown)
      rescue
        _ -> :ok
      end
    end
  end

  defp shutdown_instance(_key, _instance), do: :ok
end
