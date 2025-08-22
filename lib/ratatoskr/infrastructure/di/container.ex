defmodule Ratatoskr.Infrastructure.DI.Container do
  @moduledoc """
  Dependency injection container for Ratatoskr.

  Provides centralized dependency resolution with environment-specific
  configurations and easy testing support.

  ## Usage

      # Get production dependencies
      deps = Container.deps()
      
      # Get test dependencies with overrides
      deps = Container.test_deps(registry: MockRegistry)
      
  ## Configuration

  Configure dependencies in config.exs:

      config :ratatoskr,
        registry: MyCustomRegistry,
        storage: MyStorageAdapter,
        metrics: MyMetricsCollector
  """

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
