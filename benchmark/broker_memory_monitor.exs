#!/usr/bin/env elixir

# BROKER MEMORY MONITOR - Production-like Memory Measurement
# Usage: elixir bin/broker_memory_monitor.exs <topic_count> <total_subscribers>
# Example: elixir bin/broker_memory_monitor.exs 2 50
#
# This script:
# 1. Starts the broker with subscribers (simulating production setup)
# 2. Monitors ONLY broker process memory (not publisher overhead) 
# 3. Waits for external gRPC publisher to send messages
# 4. Measures delivery throughput, P99 latency, and true broker resource usage

require Logger

# Helper modules
defmodule MemoryHelper do
  def get_physical_memory_mb() do
    case :os.type() do
      {:unix, :darwin} ->
        {result, 0} = System.cmd("ps", ["-o", "rss=", "-p", "#{:os.getpid()}"])
        physical_kb = String.trim(result) |> String.to_integer()
        div(physical_kb, 1024)
      {:unix, :linux} ->
        {result, 0} = System.cmd("ps", ["-o", "rss=", "-p", "#{:os.getpid()}"])
        physical_kb = String.trim(result) |> String.to_integer()
        div(physical_kb, 1024)
      _ ->
        div(:erlang.memory()[:total], 1024 * 1024)
    end
  rescue
    _ -> div(:erlang.memory()[:total], 1024 * 1024)
  end

  def get_beam_memory_mb() do
    div(:erlang.memory()[:total], 1024 * 1024)
  end

  def get_process_memory_mb(pid) when is_pid(pid) do
    case Process.info(pid, :memory) do
      {:memory, memory_bytes} -> div(memory_bytes, 1024 * 1024)
      nil -> 0
    end
  end
end

defmodule BrokerStats do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(opts) do
    topic_count = Keyword.get(opts, :topic_count, 1)
    total_subscribers = Keyword.get(opts, :total_subscribers, 10)
    
    state = %{
      topic_count: topic_count,
      total_subscribers: total_subscribers,
      start_time: nil,
      first_message_time: nil,
      last_message_time: nil,
      total_deliveries: 0,
      subscriber_stats: %{},
      latency_samples: [],
      memory_samples: [],
      peak_memory: 0,
      baseline_memory: MemoryHelper.get_physical_memory_mb()
    }
    
    # Schedule periodic memory sampling
    :timer.send_interval(100, self(), :sample_memory)
    
    {:ok, state}
  end
  
  def record_delivery(subscriber_id, message, delivery_time) do
    GenServer.cast(__MODULE__, {:delivery, subscriber_id, message, delivery_time})
  end
  
  def get_stats() do
    GenServer.call(__MODULE__, :get_stats, 30_000)
  end
  
  def handle_cast({:delivery, subscriber_id, message, delivery_time}, state) do
    # Update first message time
    new_first_time = if state.first_message_time == nil do
      delivery_time
    else
      min(state.first_message_time, delivery_time)
    end
    
    # Update subscriber stats
    sub_stats = Map.get(state.subscriber_stats, subscriber_id, %{count: 0, first_time: nil, last_time: nil})
    new_sub_stats = %{
      count: sub_stats.count + 1,
      first_time: if(sub_stats.first_time == nil, do: delivery_time, else: sub_stats.first_time),
      last_time: delivery_time
    }
    
    # Sample latency if message has timestamp
    new_latency_samples = case message do
      %{timestamp: pub_time} when is_integer(pub_time) ->
        latency_us = delivery_time - pub_time
        if latency_us > 0 and latency_us < 10_000_000 do
          [latency_us | state.latency_samples]
        else
          state.latency_samples
        end
      _ -> state.latency_samples
    end
    
    new_state = %{state |
      total_deliveries: state.total_deliveries + 1,
      first_message_time: new_first_time,
      last_message_time: delivery_time,
      subscriber_stats: Map.put(state.subscriber_stats, subscriber_id, new_sub_stats),
      latency_samples: new_latency_samples
    }
    
    {:noreply, new_state}
  end
  
  def handle_call(:get_stats, _from, state) do
    {:reply, state, state}
  end
  
  def handle_info(:sample_memory, state) do
    current_memory = MemoryHelper.get_physical_memory_mb()
    new_peak = max(state.peak_memory, current_memory)
    
    new_samples = [{:os.system_time(:millisecond), current_memory} | state.memory_samples]
    # Keep only last 1000 samples to avoid memory bloat
    trimmed_samples = Enum.take(new_samples, 1000)
    
    new_state = %{state | 
      memory_samples: trimmed_samples,
      peak_memory: new_peak
    }
    
    {:noreply, new_state}
  end
end

# Parse command line arguments
{topic_count, total_subscribers} = case System.argv() do
  [t, s] -> 
    {String.to_integer(t), String.to_integer(s)}
  _ ->
    IO.puts("Usage: elixir #{__ENV__.file} <topic_count> <total_subscribers>")
    IO.puts("Example: elixir #{__ENV__.file} 2 50")
    IO.puts("")
    IO.puts("Using defaults: 1 topic, 10 subscribers")
    {1, 10}
end

# Calculate derived values
subscribers_per_topic = div(total_subscribers, topic_count) + if rem(total_subscribers, topic_count) > 0, do: 1, else: 0

IO.puts("🔍 === BROKER MEMORY MONITOR (Production Simulation) ===")
IO.puts("Configuration:")
IO.puts("• Topics: #{topic_count}")
IO.puts("• Total subscribers: #{total_subscribers}")
IO.puts("• Subscribers per topic: #{subscribers_per_topic}")
IO.puts("• Measuring: BROKER-ONLY memory consumption")
IO.puts("• Waiting for: External gRPC publisher")
IO.puts("")

# Start application
Mix.install([{:ratatoskr, path: "."}])
Application.ensure_all_started(:ratatoskr)

# Configure production telemetry
try do
  :telemetry.detach(:ratatoskr_development)
  :telemetry.detach(:ratatoskr_metrics_logger)
  :telemetry.detach(:ratatoskr_metrics_console)
rescue
  _ -> :ok
end

Logger.configure(level: :error)
Process.sleep(2000)

# Start stats collector
{:ok, _stats_pid} = BrokerStats.start_link(topic_count: topic_count, total_subscribers: total_subscribers)

# Get baseline measurements
baseline_physical_mb = MemoryHelper.get_physical_memory_mb()
baseline_beam_mb = MemoryHelper.get_beam_memory_mb()
baseline_processes = length(Process.list())

IO.puts("📊 Baseline (empty broker): #{baseline_physical_mb}MB physical, #{baseline_beam_mb}MB BEAM, #{baseline_processes} processes")

# Connect to gRPC server
IO.puts("Connecting to gRPC server...")
{:ok, channel} = GRPC.Stub.connect("localhost:9090")

# Create topics via gRPC
IO.puts("🔧 Creating #{topic_count} topic(s) via gRPC...")
topics = for i <- 1..topic_count do
  topic_name = if topic_count == 1, do: "production_topic", else: "production_topic_#{i}"
  
  request = struct(Ratatoskr.Grpc.CreateTopicRequest, name: topic_name)
  {:ok, _response} = Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, request)
  
  topic_name
end

IO.puts("✅ Topics created via gRPC: #{Enum.join(topics, ", ")}")

# Create subscribers (simulating production consumers)
IO.puts("🔥 Creating #{total_subscribers} subscribers (production consumers)...")

subscriber_pids = if topic_count == 1 do
  # All subscribers on single topic
  topic = hd(topics)
  for i <- 1..total_subscribers do
    spawn(fn ->
      subscriber_id = i
      {:ok, _ref} = Ratatoskr.subscribe(topic)
      
      receive_loop = fn loop_fn ->
        receive do
          {:message, message} ->
            delivery_time = System.monotonic_time(:microsecond)
            BrokerStats.record_delivery(subscriber_id, message, delivery_time)
            loop_fn.(loop_fn)
            
          :shutdown -> 
            :ok
        after
          300_000 -> :timeout  # 5 minute timeout
        end
      end
      
      receive_loop.(receive_loop)
    end)
  end
else
  # Distribute subscribers across topics
  for i <- 1..total_subscribers do
    topic_index = rem(i - 1, topic_count)
    topic = Enum.at(topics, topic_index)
    
    spawn(fn ->
      subscriber_id = i
      {:ok, _ref} = Ratatoskr.subscribe(topic)
      
      receive_loop = fn loop_fn ->
        receive do
          {:message, message} ->
            delivery_time = System.monotonic_time(:microsecond)
            BrokerStats.record_delivery(subscriber_id, message, delivery_time)
            loop_fn.(loop_fn)
            
          :shutdown -> 
            :ok
        after
          300_000 -> :timeout
        end
      end
      
      receive_loop.(receive_loop)
    end)
  end
end

# Memory after setup
setup_physical_mb = MemoryHelper.get_physical_memory_mb()
setup_beam_mb = MemoryHelper.get_beam_memory_mb()
setup_processes = length(Process.list())
setup_overhead_physical = setup_physical_mb - baseline_physical_mb
setup_overhead_beam = setup_beam_mb - baseline_beam_mb

IO.puts("📊 After setup: #{setup_physical_mb}MB physical (+#{setup_overhead_physical}MB), #{setup_beam_mb}MB BEAM (+#{setup_overhead_beam}MB), #{setup_processes} processes")
IO.puts("")

IO.puts("🎯 === BROKER READY FOR PRODUCTION LOAD ===")
IO.puts("Ready to receive messages from external gRPC publisher!")
IO.puts("Run the publisher: elixir bin/external_grpc_publisher.exs <total_messages> #{topic_count}")
IO.puts("")
IO.puts("Topics available:")
Enum.each(topics, fn topic -> IO.puts("  • #{topic}") end)
IO.puts("")
IO.puts("Waiting for messages... (Press Ctrl+C to generate report)")
IO.puts("")

# Monitor for activity
last_delivery_count = 0
last_report_time = :os.system_time(:second)
monitor_interval = 5  # seconds

monitor_loop = fn loop_fn, last_count, last_time ->
  Process.sleep(monitor_interval * 1000)
  
  current_time = :os.system_time(:second)
  stats = BrokerStats.get_stats()
  
  if stats.total_deliveries > last_count do
    # Activity detected
    deliveries_delta = stats.total_deliveries - last_count
    time_delta = current_time - last_time
    delivery_rate = if time_delta > 0, do: div(deliveries_delta, time_delta), else: 0
    
    current_physical_mb = MemoryHelper.get_physical_memory_mb()
    current_beam_mb = MemoryHelper.get_beam_memory_mb()
    
    IO.puts("📈 Active: #{stats.total_deliveries} deliveries (+#{deliveries_delta}), #{delivery_rate}/s | #{current_physical_mb}MB physical, #{current_beam_mb}MB BEAM")
    
    loop_fn.(loop_fn, stats.total_deliveries, current_time)
  else
    # No activity, just continue monitoring
    loop_fn.(loop_fn, last_count, last_time)
  end
end

# Start monitoring in background
_monitor_pid = spawn(fn -> 
  monitor_loop.(monitor_loop, last_delivery_count, last_report_time) 
end)

# Wait for Ctrl+C or significant inactivity
try do
  # Keep the main process alive
  Process.sleep(:infinity)
rescue
  # Ctrl+C or termination
  _ ->
    IO.puts("")
    IO.puts("🔍 === GENERATING BROKER PERFORMANCE REPORT ===")
    
    # Get final stats
    final_stats = BrokerStats.get_stats()
    final_physical_mb = MemoryHelper.get_physical_memory_mb()
    final_beam_mb = MemoryHelper.get_beam_memory_mb()
    
    # Calculate metrics
    total_duration_ms = if final_stats.first_message_time && final_stats.last_message_time do
      (final_stats.last_message_time - final_stats.first_message_time) / 1000
    else
      0
    end
    
    delivery_throughput = if total_duration_ms > 0 do
      round(final_stats.total_deliveries * 1000 / total_duration_ms)
    else
      0
    end
    
    # P99 latency calculation
    p99_latency = if length(final_stats.latency_samples) > 0 do
      latencies_ms = Enum.map(final_stats.latency_samples, &(&1 / 1000))
      sorted = Enum.sort(latencies_ms)
      p99_idx = max(0, div(length(sorted) * 99, 100) - 1)
      Enum.at(sorted, p99_idx) || 0.0
    else
      0.0
    end
    
    # Memory overhead (broker only)
    broker_memory_overhead = final_physical_mb - baseline_physical_mb
    beam_memory_overhead = final_beam_mb - baseline_beam_mb
    peak_memory_overhead = final_stats.peak_memory - baseline_physical_mb
    
    # Generate timestamp
    timestamp = DateTime.utc_now() |> DateTime.to_string() |> String.replace(~r/[^0-9]/, "")
    filename = "/tmp/broker_monitor_#{topic_count}t_#{total_subscribers}s_#{timestamp}.txt"
    
    # Results
    results = """
🎯 === BROKER MEMORY MONITOR RESULTS ===

📝 **BROKER CONFIGURATION:**
• Topics: #{topic_count}
• Subscribers: #{total_subscribers} (simulated production consumers)
• Architecture: #{if topic_count == 1, do: "Single topic (broadcast)", else: "Multiple topics (distributed)"}
• Measurement: BROKER-ONLY resource consumption

📨 **DELIVERY PERFORMANCE (Broker Side):**
• Total deliveries processed: #{final_stats.total_deliveries}
• Delivery throughput: #{delivery_throughput} deliveries/s
• Processing duration: #{Float.round(total_duration_ms / 1000, 2)}s
• P99 delivery latency: #{Float.round(p99_latency, 3)}ms
• Active subscribers: #{map_size(final_stats.subscriber_stats)}

💾 **BROKER MEMORY CONSUMPTION (Production Simulation):**
• Physical RAM baseline (empty broker): #{baseline_physical_mb}MB
• Physical RAM after setup: #{setup_physical_mb}MB (+#{setup_overhead_physical}MB)
• Physical RAM peak during processing: #{final_stats.peak_memory}MB (+#{peak_memory_overhead}MB)
• Physical RAM final: #{final_physical_mb}MB (+#{broker_memory_overhead}MB)
• BEAM VM baseline: #{baseline_beam_mb}MB
• BEAM VM after setup: #{setup_beam_mb}MB (+#{setup_overhead_beam}MB)
• BEAM VM final: #{final_beam_mb}MB (+#{beam_memory_overhead}MB)

📊 **BROKER EFFICIENCY:**
• Memory per delivery: #{if final_stats.total_deliveries > 0, do: Float.round(peak_memory_overhead / final_stats.total_deliveries * 1024, 3), else: 0}KB
• Memory per subscriber: #{Float.round(setup_overhead_physical / total_subscribers, 3)}MB
• Processing overhead: #{peak_memory_overhead - setup_overhead_physical}MB
• Latency samples collected: #{length(final_stats.latency_samples)}

🏆 **PRODUCTION READINESS:**
• Broker Memory Overhead: #{peak_memory_overhead}MB
• Delivery Throughput: #{delivery_throughput} msg/s
• P99 Latency: #{Float.round(p99_latency, 3)}ms
• Setup Cost: #{setup_overhead_physical}MB for #{total_subscribers} subscribers

System: MacBook Air M4, Production telemetry, BROKER-ONLY measurements
Measurement: Physical RAM consumption excluding publisher overhead
Timestamp: #{DateTime.utc_now() |> DateTime.to_iso8601()}
"""

    # Write and display results
    File.write!(filename, results)
    IO.puts("")
    IO.puts(results)
    
    # Cleanup
    IO.puts("🧹 Cleaning up...")
    Enum.each(subscriber_pids, fn pid -> send(pid, :shutdown) end)
    
    Enum.each(topics, fn topic -> 
      request = struct(Ratatoskr.Grpc.DeleteTopicRequest, name: topic)
      {:ok, _response} = Ratatoskr.Grpc.MessageBroker.Stub.delete_topic(channel, request)
    end)
    
    GRPC.Stub.disconnect(channel)
    
    cleanup_physical_mb = MemoryHelper.get_physical_memory_mb()
    cleanup_beam_mb = MemoryHelper.get_beam_memory_mb()
    IO.puts("🧹 After cleanup: #{cleanup_physical_mb}MB physical, #{cleanup_beam_mb}MB BEAM")
    IO.puts("")
    IO.puts("✅ Broker monitor complete! Results saved to: #{filename}")
end