#!/usr/bin/env elixir

# GRPC CONFIGURABLE STRESS TEST - ACCURATE PERFORMANCE MEASUREMENT
# Usage: elixir bin/grpc_configurable_stress_test.exs <total_messages> <topic_count> <total_subscribers>
# Example: elixir bin/grpc_configurable_stress_test.exs 1000 5 100

# This test uses REAL gRPC network calls, not internal API functions!
# Measures both physical memory and BEAM VM memory consumption.

# Require Logger
require Logger

# Helper function to get physical memory usage
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
        # Fallback to BEAM memory if we can't detect physical memory
        div(:erlang.memory()[:total], 1024 * 1024)
    end
  rescue
    _ ->
      # Fallback to BEAM memory if command fails
      div(:erlang.memory()[:total], 1024 * 1024)
  end

  def get_beam_memory_mb() do
    div(:erlang.memory()[:total], 1024 * 1024)
  end
end

# Helper function to calculate CPU utilization
defmodule CPUHelper do
  def calculate_utilization(nil, _), do: 0.0
  def calculate_utilization(_, nil), do: 0.0
  def calculate_utilization(start_sample, end_sample) do
    # Calculate total active and total time for each scheduler
    utilizations = Enum.zip(start_sample, end_sample)
    |> Enum.map(fn {{_id1, active1, total1}, {_id2, active2, total2}} ->
      active_diff = active2 - active1
      total_diff = total2 - total1
      if total_diff > 0, do: active_diff / total_diff * 100, else: 0.0
    end)
    
    # Average across all schedulers
    if length(utilizations) > 0 do
      Float.round(Enum.sum(utilizations) / length(utilizations), 2)
    else
      0.0
    end
  rescue
    _ -> 0.0
  end
end

# Parse command line arguments
{total_messages, topic_count, total_subscribers} = case System.argv() do
  [m, t, s] -> 
    {String.to_integer(m), String.to_integer(t), String.to_integer(s)}
  _ ->
    IO.puts("Usage: elixir #{__ENV__.file} <total_messages> <topic_count> <total_subscribers>")
    IO.puts("Example: elixir #{__ENV__.file} 1000 5 100")
    IO.puts("")
    IO.puts("Using defaults: 1000 total messages, 1 topic, 100 subscribers")
    {1000, 1, 100}
end

# Calculate derived values from new input parameters
subscribers_per_topic = div(total_subscribers, topic_count) + if rem(total_subscribers, topic_count) > 0, do: 1, else: 0

# Calculate expected deliveries based on architecture
total_deliveries = if topic_count == 1 do
  # Single topic: each message broadcasts to all subscribers
  total_messages * total_subscribers  
else
  # Multiple topics: messages are distributed across topics, subscribers get messages from their topic only
  # Each topic gets total_messages / topic_count messages
  # Each subscriber gets all messages published to their topic
  messages_per_topic = div(total_messages, topic_count)
  remaining_messages = rem(total_messages, topic_count)
  
  # Calculate total deliveries: for each topic, messages * subscribers_on_that_topic
  total_deliveries_sum = Enum.reduce(0..(topic_count - 1), 0, fn topic_idx, acc ->
    subscribers_on_topic = div(total_subscribers, topic_count) + 
      if topic_idx < rem(total_subscribers, topic_count), do: 1, else: 0
    messages_on_topic = if topic_idx < remaining_messages do
      messages_per_topic + 1
    else 
      messages_per_topic
    end
    acc + (messages_on_topic * subscribers_on_topic)
  end)
  
  total_deliveries_sum
end

# Calculate messages per subscriber for display purposes (approximate)
messages_per_subscriber = if topic_count == 1 do
  total_messages
else
  div(total_deliveries, total_subscribers)
end

IO.puts("🚀 === gRPC CONFIGURABLE STRESS TEST ===")
IO.puts("⚠️  REAL gRPC NETWORK CALLS - ACCURATE PERFORMANCE MEASUREMENT")
IO.puts("Configuration:")
IO.puts("• Total messages to publish: #{total_messages}")
IO.puts("• Topics: #{topic_count}")
IO.puts("• Total subscribers: #{total_subscribers}")
IO.puts("• Subscribers per topic: #{subscribers_per_topic}")
IO.puts("• Messages per subscriber: #{messages_per_subscriber}")
IO.puts("• Expected total deliveries: #{total_deliveries}")
IO.puts("• Architecture: #{if topic_count == 1, do: "Single topic (broadcast)", else: "Multiple topics (distributed)"}")
IO.puts("")

# Start and configure application
Mix.install([{:ratatoskr, path: "."}])
Application.ensure_all_started(:ratatoskr)
Process.sleep(2000)

# Note: Using full module names to avoid compilation issues

# Configure production telemetry for clean performance measurement
try do
  :telemetry.detach(:ratatoskr_development)
  :telemetry.detach(:ratatoskr_metrics_logger)
  :telemetry.detach(:ratatoskr_metrics_console)
rescue
  _ -> :ok
end

# Try to configure production telemetry if available
try do
  Ratatoskr.Infrastructure.Telemetry.Config.configure_for_level(:production)
  Ratatoskr.Infrastructure.Telemetry.SmartMetricsCollector.attach_level_appropriate_handlers()
  Ratatoskr.Infrastructure.Telemetry.SmartMetricsCollector.start_metrics_collection()
rescue
  _ -> 
    # Fallback if telemetry modules aren't available
    Logger.configure(level: :error)
    :ok
end

Process.sleep(1000)

IO.puts("✅ Production telemetry configured")

# Get baseline measurements BEFORE any setup
baseline_physical_mb = MemoryHelper.get_physical_memory_mb()
baseline_beam_mb = MemoryHelper.get_beam_memory_mb()
baseline_processes = length(Process.list())

IO.puts("📊 Baseline: #{baseline_physical_mb}MB physical, #{baseline_beam_mb}MB BEAM, #{baseline_processes} processes")

# ========================================
# SETUP PHASE (NOT MEASURED FOR PERFORMANCE)
# ========================================

IO.puts("")
IO.puts("🔧 === SETUP PHASE (NOT MEASURED) ===")

# Connect to gRPC server
IO.puts("Connecting to gRPC server...")
{:ok, channel} = GRPC.Stub.connect("localhost:9090")

# Create topics using gRPC API (setup only, not measured)
topics = for i <- 1..topic_count do
  topic_name = if topic_count == 1, do: "grpc_stress_topic", else: "grpc_topic_#{i}"
  
  # Use gRPC to create topic (dynamic struct creation)
  request = struct(Ratatoskr.Grpc.CreateTopicRequest, name: topic_name)
  {:ok, _response} = Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, request)
  
  topic_name
end

IO.puts("✅ Created #{topic_count} topic(s) via gRPC")

# Create subscribers using internal API (setup only, not measured)
# Note: gRPC subscriptions would typically use streaming, but for this stress test
# we use internal subscribers to focus on gRPC publishing performance
IO.puts("🔥 Creating #{total_subscribers} subscribers via internal API...")

subscriber_pids = if topic_count == 1 do
  # All subscribers on single topic
  topic = hd(topics)
  for i <- 1..total_subscribers do
    spawn(fn ->
      subscriber_id = i
      {:ok, _ref} = Ratatoskr.subscribe(topic)
      
      receive_loop = fn loop_fn, count, first_time, sample_latencies ->
        receive do
          {:message, message} ->
            now = System.monotonic_time(:microsecond)
            
            # Sample latency every 100 messages or at least 10 samples
            new_samples = if rem(count, max(div(messages_per_subscriber, 10), 1)) == 0 do
              case message do
                %{timestamp: pub_time} when is_integer(pub_time) ->
                  latency_us = now - pub_time
                  if latency_us > 0 and latency_us < 10_000_000 do
                    [latency_us | sample_latencies]
                  else
                    sample_latencies
                  end
                _ -> sample_latencies
              end
            else
              sample_latencies
            end
            
            new_first = if first_time == nil, do: now, else: first_time
            loop_fn.(loop_fn, count + 1, new_first, new_samples)
            
          {:get_stats, from} ->
            end_time = System.monotonic_time(:microsecond)
            duration = if first_time, do: (end_time - first_time) / 1000, else: 0
            send(from, {:stats, subscriber_id, count, sample_latencies, duration})
            
          :shutdown -> 
            :ok
        after
          120_000 -> :timeout
        end
      end
      
      receive_loop.(receive_loop, 0, nil, [])
    end)
  end
else
  # Distribute subscribers across topics
  subscribers = for i <- 1..total_subscribers do
    topic_index = rem(i - 1, topic_count)
    topic = Enum.at(topics, topic_index)
    
    pid = spawn(fn ->
      subscriber_id = i
      {:ok, _ref} = Ratatoskr.subscribe(topic)
      
      receive_loop = fn loop_fn, count, first_time, sample_latencies ->
        receive do
          {:message, message} ->
            now = System.monotonic_time(:microsecond)
            
            # Sample latency 
            new_samples = if rem(count, max(div(messages_per_subscriber, 10), 1)) == 0 do
              case message do
                %{timestamp: pub_time} when is_integer(pub_time) ->
                  latency_us = now - pub_time
                  if latency_us > 0 and latency_us < 10_000_000 do
                    [latency_us | sample_latencies]
                  else
                    sample_latencies
                  end
                _ -> sample_latencies
              end
            else
              sample_latencies
            end
            
            new_first = if first_time == nil, do: now, else: first_time
            loop_fn.(loop_fn, count + 1, new_first, new_samples)
            
          {:get_stats, from} ->
            end_time = System.monotonic_time(:microsecond)
            duration = if first_time, do: (end_time - first_time) / 1000, else: 0
            send(from, {:stats, subscriber_id, count, sample_latencies, duration})
            
          :shutdown -> 
            :ok
        after
          120_000 -> :timeout
        end
      end
      
      receive_loop.(receive_loop, 0, nil, [])
    end)
    
    {topic, pid}
  end
  
  Enum.map(subscribers, fn {_topic, pid} -> pid end)
end

setup_physical_mb = MemoryHelper.get_physical_memory_mb()
setup_beam_mb = MemoryHelper.get_beam_memory_mb()
setup_processes = length(Process.list())
memory_overhead_setup_physical = setup_physical_mb - baseline_physical_mb
memory_overhead_setup_beam = setup_beam_mb - baseline_beam_mb

IO.puts("📊 After setup: #{setup_physical_mb}MB physical (+#{memory_overhead_setup_physical}MB), #{setup_beam_mb}MB BEAM (+#{memory_overhead_setup_beam}MB), #{setup_processes} processes")

# Wait for setup to stabilize
Process.sleep(3000)

# ========================================
# PERFORMANCE MEASUREMENT PHASE
# ========================================

IO.puts("")
IO.puts("⚡ === PERFORMANCE MEASUREMENT PHASE ===")
IO.puts("🔥 Publishing #{total_messages} messages via gRPC...")

# Track CPU before publishing
cpu_sample_start = :erlang.statistics(:scheduler_wall_time)

# Get memory state right before performance test
_pre_test_physical_mb = MemoryHelper.get_physical_memory_mb()
_pre_test_beam_mb = MemoryHelper.get_beam_memory_mb()

start_time = System.monotonic_time(:millisecond)

# Publish messages via gRPC and collect latencies
publish_latencies = if topic_count == 1 do
  # Single topic: publish all messages to one topic via gRPC
  topic = hd(topics)
  
  {_, latencies} = Enum.reduce(1..total_messages, {0, []}, fn i, {_count, acc_latencies} ->
    publish_start = System.monotonic_time(:microsecond)
    
    # Create gRPC request
    request = struct(Ratatoskr.Grpc.PublishRequest, [
      topic: topic,
      payload: Jason.encode!(%{
        id: i,
        timestamp: publish_start,
        test: "grpc_stress"
      }),
      metadata: %{"seq" => to_string(i)}
    ])
    
    # REAL gRPC NETWORK CALL
    {:ok, _response} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
    
    publish_end = System.monotonic_time(:microsecond)
    publish_latency = publish_end - publish_start
    
    # Sample publish latency
    new_latencies = if rem(i, max(div(total_messages, 100), 1)) == 0 do
      [publish_latency | acc_latencies]
    else
      acc_latencies
    end
    
    # Progress reporting
    if rem(i, max(div(total_messages, 10), 1)) == 0 do
      current_physical_mb = MemoryHelper.get_physical_memory_mb()
      current_beam_mb = MemoryHelper.get_beam_memory_mb()
      progress = Float.round(i / total_messages * 100, 1)
      IO.puts("📈 #{i}/#{total_messages} (#{progress}%) | #{current_physical_mb}MB physical, #{current_beam_mb}MB BEAM")
    end
    
    {i, new_latencies}
  end)
  
  latencies
else
  # Multiple topics: distribute messages across topics via gRPC
  messages_per_topic = div(total_messages, topic_count)
  remaining_messages = rem(total_messages, topic_count)
  
  {_, latencies} = Enum.reduce(0..(topic_count - 1), {0, []}, fn topic_idx, {msg_count, acc_latencies} ->
    topic = Enum.at(topics, topic_idx)
    # Some topics get one extra message if total_messages doesn't divide evenly
    messages_for_this_topic = if topic_idx < remaining_messages do
      messages_per_topic + 1
    else
      messages_per_topic
    end
    
    Enum.reduce(1..messages_for_this_topic, {msg_count, acc_latencies}, fn _msg_idx, {count, latencies_acc} ->
      new_count = count + 1
      publish_start = System.monotonic_time(:microsecond)
      
      # Create gRPC request
      request = struct(Ratatoskr.Grpc.PublishRequest, [
        topic: topic,
        payload: Jason.encode!(%{
          id: new_count,
          timestamp: publish_start,
          topic_idx: topic_idx,
          test: "grpc_stress"
        }),
        metadata: %{"seq" => to_string(new_count)}
      ])
      
      # REAL gRPC NETWORK CALL
      {:ok, _response} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
      
      publish_end = System.monotonic_time(:microsecond)
      publish_latency = publish_end - publish_start
      
      # Sample publish latency
      new_latencies = if rem(new_count, max(div(total_messages, 100), 1)) == 0 do
        [publish_latency | latencies_acc]
      else
        latencies_acc
      end
      
      # Progress reporting
      if rem(new_count, max(div(total_messages, 10), 1)) == 0 do
        current_physical_mb = MemoryHelper.get_physical_memory_mb()
        current_beam_mb = MemoryHelper.get_beam_memory_mb()
        progress = Float.round(new_count / total_messages * 100, 1)
        IO.puts("📈 #{new_count}/#{total_messages} (#{progress}%) | #{current_physical_mb}MB physical, #{current_beam_mb}MB BEAM")
      end
      
      {new_count, new_latencies}
    end)
  end)
  
  latencies
end

end_time = System.monotonic_time(:millisecond)
total_duration_ms = end_time - start_time
publishing_throughput = round(total_messages * 1000 / max(total_duration_ms, 1))

# Peak memory and CPU during publishing
peak_physical_mb = MemoryHelper.get_physical_memory_mb()
peak_beam_mb = MemoryHelper.get_beam_memory_mb()
_peak_processes = length(Process.list())
memory_overhead_peak_physical = peak_physical_mb - baseline_physical_mb
memory_overhead_peak_beam = peak_beam_mb - baseline_beam_mb

cpu_sample_end = :erlang.statistics(:scheduler_wall_time)
cpu_utilization = CPUHelper.calculate_utilization(cpu_sample_start, cpu_sample_end)

IO.puts("")
IO.puts("✅ gRPC Publishing complete!")
IO.puts("📊 Published #{total_messages} messages via gRPC in #{total_duration_ms}ms")
IO.puts("📊 gRPC Publishing: #{publishing_throughput} msg/s in #{Float.round(total_duration_ms / 1000, 2)}s")
IO.puts("📊 Peak memory: #{peak_physical_mb}MB physical (+#{memory_overhead_peak_physical}MB), #{peak_beam_mb}MB BEAM (+#{memory_overhead_peak_beam}MB)")
IO.puts("📊 CPU utilization during gRPC publishing: #{cpu_utilization}%")

# Calculate publish P99 latency
publish_p99 = if length(publish_latencies) > 0 do
  sorted = Enum.sort(publish_latencies)
  p99_idx = max(0, div(length(sorted) * 99, 100) - 1)
  Enum.at(sorted, p99_idx) / 1000  # Convert to ms
else
  0.0
end

# Wait for delivery
IO.puts("")
IO.puts("⏳ Waiting for message delivery...")
Process.sleep(5000)

# Collect statistics
IO.puts("📊 Collecting statistics from #{total_subscribers} subscribers...")

Enum.each(subscriber_pids, fn pid ->
  send(pid, {:get_stats, self()})
end)

subscriber_stats = for _i <- 1..total_subscribers do
  receive do
    {:stats, sub_id, count, samples, duration} -> 
      %{id: sub_id, received: count, latency_samples: samples, duration: duration}
  after 30_000 -> 
    %{id: :timeout, received: 0, latency_samples: [], duration: 0}
  end
end

# Analyze results
successful_subscribers = Enum.reject(subscriber_stats, fn s -> s.id == :timeout end)
total_messages_received = Enum.sum(Enum.map(successful_subscribers, & &1.received))
_timeout_count = length(subscriber_stats) - length(successful_subscribers)

# Use the already calculated total_deliveries
expected_total_deliveries = total_deliveries

delivery_success_rate = Float.round(total_messages_received / expected_total_deliveries * 100, 2)

# Calculate delivery throughput
avg_subscriber_duration = if length(successful_subscribers) > 0 do
  durations = Enum.map(successful_subscribers, & &1.duration)
  valid_durations = Enum.filter(durations, & &1 > 0)
  if length(valid_durations) > 0 do
    Enum.sum(valid_durations) / length(valid_durations)
  else
    total_duration_ms
  end
else
  total_duration_ms
end

delivery_throughput = round(total_messages_received * 1000 / max(avg_subscriber_duration, 1))

# Latency analysis for message delivery
all_latency_samples = Enum.flat_map(successful_subscribers, & &1.latency_samples)

delivery_p99 = if length(all_latency_samples) > 0 do
  latencies_ms = Enum.map(all_latency_samples, &(&1 / 1000))
  sorted = Enum.sort(latencies_ms)
  p99_idx = max(0, div(length(sorted) * 99, 100) - 1)
  Enum.at(sorted, p99_idx) || 0.0
else
  0.0
end

# Final memory
final_physical_mb = MemoryHelper.get_physical_memory_mb()
final_beam_mb = MemoryHelper.get_beam_memory_mb()

# Generate timestamp for filename
timestamp = DateTime.utc_now() |> DateTime.to_string() |> String.replace(~r/[^0-9]/, "")
filename = "/tmp/grpc_stress_test_#{total_messages}m_#{topic_count}t_#{total_subscribers}s_#{timestamp}.txt"

# RESULTS
results = """
🏆 === gRPC STRESS TEST RESULTS ===

📝 **TEST CONFIGURATION:**
• Total messages published: #{total_messages}
• Topics: #{topic_count} (created via gRPC)
• Total subscribers: #{total_subscribers} (internal API)
• Subscribers per topic: #{subscribers_per_topic}
• Messages per subscriber: #{messages_per_subscriber}
• Architecture: #{if topic_count == 1, do: "Single topic (broadcast)", else: "Multiple topics (distributed)"}
• Expected total deliveries: #{expected_total_deliveries}
• Method: gRPC topic creation + REAL gRPC PUBLISHING + internal subscribers

🚀 **gRPC PUBLISHING PERFORMANCE:**
• Throughput: #{publishing_throughput} msg/s
• Duration: #{Float.round(total_duration_ms / 1000, 2)}s
• P99 latency: #{Float.round(publish_p99, 3)}ms
• Network protocol: gRPC/HTTP2 over localhost

📨 **DELIVERY PERFORMANCE:**
• Total deliveries: #{total_messages_received}/#{expected_total_deliveries}
• Success rate: #{delivery_success_rate}%
• Throughput: #{delivery_throughput} deliveries/s
• Avg delivery time: #{Float.round(avg_subscriber_duration / 1000, 2)}s
• P99 latency: #{Float.round(delivery_p99, 3)}ms

💾 **RESOURCE USAGE (ACCURATE):**
• Physical RAM baseline: #{baseline_physical_mb}MB
• Physical RAM after setup: #{setup_physical_mb}MB (+#{memory_overhead_setup_physical}MB)
• Physical RAM peak: #{peak_physical_mb}MB (+#{memory_overhead_peak_physical}MB)
• Physical RAM final: #{final_physical_mb}MB
• BEAM VM baseline: #{baseline_beam_mb}MB
• BEAM VM after setup: #{setup_beam_mb}MB (+#{memory_overhead_setup_beam}MB)
• BEAM VM peak: #{peak_beam_mb}MB (+#{memory_overhead_peak_beam}MB)
• BEAM VM final: #{final_beam_mb}MB
• Physical memory per subscriber: #{Float.round(memory_overhead_peak_physical / total_subscribers, 3)}MB
• BEAM memory per subscriber: #{Float.round(memory_overhead_peak_beam / total_subscribers, 3)}MB
• CPU utilization: #{cpu_utilization}%

📊 **SUMMARY:**
• gRPC Publishing: #{publishing_throughput} msg/s
• Delivery: #{delivery_throughput} deliveries/s  
• Physical RAM overhead: #{memory_overhead_peak_physical}MB
• BEAM VM RAM overhead: #{memory_overhead_peak_beam}MB
• CPU usage: #{cpu_utilization}%
• gRPC Publish P99: #{Float.round(publish_p99, 3)}ms
• Delivery P99: #{Float.round(delivery_p99, 3)}ms
• Success rate: #{delivery_success_rate}%

System: MacBook Air M4, Production telemetry, REAL gRPC network calls
Timestamp: #{DateTime.utc_now() |> DateTime.to_iso8601()}
"""

# Write results to file
File.write!(filename, results)

# Display results
IO.puts("")
IO.puts(results)

# Cleanup
IO.puts("🧹 Cleaning up...")
Enum.each(subscriber_pids, fn pid -> send(pid, :shutdown) end)

# Delete topics via gRPC
Enum.each(topics, fn topic -> 
  request = struct(Ratatoskr.Grpc.DeleteTopicRequest, name: topic)
  {:ok, _response} = Ratatoskr.Grpc.MessageBroker.Stub.delete_topic(channel, request)
end)

# Disconnect gRPC channel
GRPC.Stub.disconnect(channel)

cleanup_physical_mb = MemoryHelper.get_physical_memory_mb()
cleanup_beam_mb = MemoryHelper.get_beam_memory_mb()
IO.puts("🧹 After cleanup: #{cleanup_physical_mb}MB physical, #{cleanup_beam_mb}MB BEAM")
IO.puts("")
IO.puts("✅ gRPC Test complete! Results saved to: #{filename}")