defmodule Ratatoskr.Infrastructure.DI.Container do
  @moduledoc """
  Dependency injection container for Ratatoskr.

  Provides centralized dependency resolution with environment-specific
  configurations, lifecycle management, and scoped dependencies.

  ## Basic Usage

      # Get production dependencies
      deps = Container.deps()
      
      # Get test dependencies with overrides
      deps = Container.test_deps(registry: MockRegistry)

  ## Advanced Usage with Lifecycle Management

      # Get singleton instance
      metrics = Container.get_singleton(:metrics)
      
      # Get process-scoped instance
      cache = Container.get_process_scoped(:cache)
      
      # Create transient instance
      worker = Container.get_transient(:worker)
      
  ## Configuration

  Configure dependencies in config.exs:

      config :ratatoskr,
        registry: MyCustomRegistry,
        storage: MyStorageAdapter,
        metrics: MyMetricsCollector,
        # Lifecycle configurations
        lifecycle: [
          singletons: [
            {:metrics, MyMetrics, [], lazy: false},
            {:event_bus, EventBus, []}
          ],
          process_scoped: [
            {:cache, ProcessCache, [size: 1000]}
          ]
        ]
  """

  alias Ratatoskr.Infrastructure.DI.Lifecycle

  @type deps :: %{
          registry: module(),
          storage: module() | nil,
          metrics: module() | nil,
          event_publisher: module() | nil
        }

  @doc """
  Gets the complete dependency map for the current environment.

  Dependencies are resolved based on:
  1. Application configuration
  2. Environment defaults (test vs prod)
  3. Fallback to sensible defaults
  """
  @spec deps() :: deps()
  def deps do
    %{
      registry: registry(),
      storage: storage(),
      metrics: metrics(),
      event_publisher: event_publisher()
    }
  end

  @doc """
  Gets the dependency map for testing with optional overrides.

  ## Examples

      # Use all test defaults
      deps = Container.test_deps()
      
      # Override specific dependencies
      deps = Container.test_deps(registry: MyMockRegistry, storage: MockStorage)
  """
  @spec test_deps(keyword()) :: deps()
  def test_deps(overrides \\ []) do
    base_deps = %{
      registry: test_registry(),
      storage: test_storage(),
      metrics: test_metrics(),
      event_publisher: test_event_publisher()
    }

    Enum.reduce(overrides, base_deps, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  @doc """
  Gets a specific dependency by key.
  """
  @spec get(atom()) :: module() | nil
  def get(key) when key in [:registry, :storage, :metrics, :event_publisher] do
    deps() |> Map.get(key)
  end

  # Lifecycle Management Functions

  @doc """
  Gets a singleton instance, creating it if needed.
  
  ## Examples
  
      metrics = Container.get_singleton(:metrics)
      event_bus = Container.get_singleton(:event_bus)
  """
  @spec get_singleton(atom()) :: term() | {:error, term()}
  def get_singleton(key) do
    try do
      Lifecycle.get_singleton(key)
    catch
      :exit, _ -> {:error, :lifecycle_manager_not_available}
    end
  end

  @doc """
  Gets a process-scoped instance for the calling process.
  
  ## Examples
  
      cache = Container.get_process_scoped(:cache)
      session = Container.get_process_scoped(:user_session)
  """
  @spec get_process_scoped(atom()) :: term() | {:error, term()}
  def get_process_scoped(key) do
    try do
      Lifecycle.get_process_scoped(key)
    catch
      :exit, _ -> {:error, :lifecycle_manager_not_available}
    end
  end

  @doc """
  Creates a new transient instance every time.
  
  ## Examples
  
      worker = Container.get_transient(:worker)
      job = Container.get_transient(:background_job)
  """
  @spec get_transient(atom()) :: term() | {:error, term()}
  def get_transient(key) do
    try do
      Lifecycle.get_transient(key)
    catch
      :exit, _ -> {:error, :lifecycle_manager_not_available}
    end
  end

  @doc """
  Registers lifecycle dependencies from configuration.
  
  This is typically called during application startup.
  """
  @spec configure_lifecycle() :: :ok
  def configure_lifecycle do
    lifecycle_config = Application.get_env(:ratatoskr, :lifecycle, [])
    
    # Register singletons
    singletons = Keyword.get(lifecycle_config, :singletons, [])
    register_dependencies(singletons, &Lifecycle.register_singleton/4)
    
    # Register process-scoped dependencies
    process_scoped = Keyword.get(lifecycle_config, :process_scoped, [])
    register_dependencies(process_scoped, &Lifecycle.register_process_scoped/4)
    
    :ok
  end

  # Private helper for registering dependencies with error handling
  defp register_dependencies(deps, register_func) when is_list(deps) do
    Enum.each(deps, fn
      {key, module, args} when is_atom(key) and is_atom(module) and is_list(args) ->
        register_func.(key, module, args, [])
      
      {key, module, args, opts} when is_atom(key) and is_atom(module) and is_list(args) and is_list(opts) ->
        register_func.(key, module, args, opts)
      
      {key, {module, function, base_args}, args} when is_atom(key) and is_atom(module) and is_atom(function) and is_list(base_args) and is_list(args) ->
        register_func.(key, {module, function, base_args}, args, [])
      
      {key, {module, function, base_args}, args, opts} when is_atom(key) and is_atom(module) and is_atom(function) and is_list(base_args) and is_list(args) and is_list(opts) ->
        register_func.(key, {module, function, base_args}, args, opts)
      
      invalid ->
        require Logger
        Logger.warning("Invalid dependency configuration: #{inspect(invalid)}")
    end)
  end

  defp register_dependencies(invalid, _register_func) do
    require Logger
    Logger.warning("Invalid dependency configuration - expected list, got: #{inspect(invalid)}")
  end

  @doc """
  Performs health checks on all managed dependencies.
  """
  @spec health_check() :: %{atom() => boolean()}
  def health_check do
    Lifecycle.health_check()
  end

  @doc """
  Shuts down all managed dependencies gracefully.
  """
  @spec shutdown() :: :ok
  def shutdown do
    Lifecycle.shutdown()
  end

  # Private implementation resolvers

  defp registry do
    case Mix.env() do
      :test -> test_registry()
      _ -> Application.get_env(:ratatoskr, :registry, default_registry())
    end
  end

  defp storage do
    case Mix.env() do
      :test -> test_storage()
      _ -> Application.get_env(:ratatoskr, :storage, default_storage())
    end
  end

  defp metrics do
    case Mix.env() do
      :test -> test_metrics()
      _ -> Application.get_env(:ratatoskr, :metrics, default_metrics())
    end
  end

  defp event_publisher do
    case Mix.env() do
      :test -> test_event_publisher()
      _ -> Application.get_env(:ratatoskr, :event_publisher, default_event_publisher())
    end
  end

  # Test environment dependencies
  defp test_registry, do: Ratatoskr.Infrastructure.Registry.ProcessRegistry
  defp test_storage, do: nil
  # No metrics in tests by default
  defp test_metrics, do: nil
  defp test_event_publisher, do: nil

  # Default implementations for production
  defp default_registry, do: Ratatoskr.Infrastructure.Registry.ProcessRegistry
  # No persistence in MVP
  defp default_storage, do: nil
  defp default_metrics, do: Ratatoskr.Infrastructure.Telemetry.MetricsCollector
  defp default_event_publisher, do: nil
end
