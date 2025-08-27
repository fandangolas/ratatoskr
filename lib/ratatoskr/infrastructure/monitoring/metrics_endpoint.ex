defmodule Ratatoskr.Infrastructure.Monitoring.MetricsEndpoint do
  @moduledoc """
  Lightweight Prometheus metrics endpoint for monitoring.
  
  Provides system-level metrics without impacting message processing performance.
  Only tracks high-level stats, not per-message overhead.
  """
  
  use Plug.Router
  require Logger
  
  plug :match
  plug :dispatch
  
  def start_link(opts \\ []) do
    port = Keyword.get(opts, :port, 4000)
    Logger.info("Starting monitoring endpoint on port #{port}")
    
    Plug.Cowboy.http(__MODULE__, [], port: port)
  end
  
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end
  
  get "/metrics" do
    metrics = [
      # System metrics only - no per-message tracking
      "# HELP ratatoskr_system_info System information",
      "# TYPE ratatoskr_system_info gauge",
      "ratatoskr_system_info{version=\"#{Application.spec(:ratatoskr, :vsn)}\"} 1",
      
      "# HELP ratatoskr_uptime_seconds System uptime in seconds", 
      "# TYPE ratatoskr_uptime_seconds counter",
      "ratatoskr_uptime_seconds #{System.monotonic_time(:second)}",
      
      "# HELP ratatoskr_memory_usage_bytes Current memory usage",
      "# TYPE ratatoskr_memory_usage_bytes gauge", 
      "ratatoskr_memory_usage_bytes #{:erlang.memory(:total)}",
      
      "# HELP ratatoskr_process_count Current process count",
      "# TYPE ratatoskr_process_count gauge",
      "ratatoskr_process_count #{:erlang.system_info(:process_count)}"
    ]
    
    send_resp(conn, 200, Enum.join(metrics, "\n"))
  end
  
  get "/health" do
    send_resp(conn, 200, "OK")
  end
  
  match _ do
    send_resp(conn, 404, "Not Found")
  end
end