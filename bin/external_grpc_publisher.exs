#!/usr/bin/env elixir

# EXTERNAL gRPC PUBLISHER - Production Client Simulation
# Usage: elixir bin/external_grpc_publisher.exs <total_messages> <topic_count>
# Example: elixir bin/external_grpc_publisher.exs 1000 2
#
# This script:
# 1. Connects as external gRPC client to running broker
# 2. Publishes messages with minimal memory footprint
# 3. Measures PUBLISHING performance (latency, throughput)
# 4. Does NOT interfere with broker memory measurements

require Logger

# Helper modules for this publisher only
defmodule PublisherMemoryHelper do
  def get_publisher_memory_mb() do
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
end

# Helper for CPU measurement
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
{total_messages, topic_count} = case System.argv() do
  [m, t] -> 
    {String.to_integer(m), String.to_integer(t)}
  [m] ->
    # Default to 1 topic if not specified
    {String.to_integer(m), 1}
  _ ->
    IO.puts("Usage: elixir #{__ENV__.file} <total_messages> [topic_count]")
    IO.puts("Example: elixir #{__ENV__.file} 1000 2")
    IO.puts("")
    IO.puts("Using defaults: 100 messages, 1 topic")
    {100, 1}
end

IO.puts("📤 === EXTERNAL gRPC PUBLISHER (Production Client) ===")
IO.puts("Configuration:")
IO.puts("• Total messages to publish: #{total_messages}")
IO.puts("• Target topics: #{topic_count}")
IO.puts("• Role: External gRPC client (minimal footprint)")
IO.puts("• Measuring: Publishing latency & throughput only")
IO.puts("")

# Install minimal dependencies for gRPC client
Mix.install([
  {:grpc, "~> 0.7"},
  {:protobuf, "~> 0.12"},
  {:jason, "~> 1.4"}
])

# Load protobuf definitions
Code.require_file("lib/ratatoskr/interfaces/grpc/ratatoskr.pb.ex")

# Get baseline publisher memory
baseline_publisher_mb = PublisherMemoryHelper.get_publisher_memory_mb()

IO.puts("📊 Publisher baseline: #{baseline_publisher_mb}MB (minimal client footprint)")
IO.puts("")

# Connect to broker
IO.puts("🔗 Connecting to gRPC broker on localhost:9090...")

{:ok, channel} = try do
  GRPC.Stub.connect("localhost:9090")
rescue
  error ->
    IO.puts("❌ Failed to connect to gRPC server on localhost:9090")
    IO.puts("Make sure the broker is running: elixir bin/broker_memory_monitor.exs")
    IO.puts("Error: #{inspect(error)}")
    exit({:shutdown, 1})
end

IO.puts("✅ Connected to gRPC broker")

# Determine topic names (must match broker setup)
topics = for i <- 1..topic_count do
  if topic_count == 1, do: "production_topic", else: "production_topic_#{i}"
end

IO.puts("🎯 Target topics: #{Enum.join(topics, ", ")}")
IO.puts("")

# Publishing performance measurement
IO.puts("⚡ === PUBLISHING PERFORMANCE MEASUREMENT ===")
IO.puts("🚀 Publishing #{total_messages} messages via gRPC...")

# Enable and track CPU before publishing
:erlang.system_flag(:scheduler_wall_time, true)
cpu_sample_start = :erlang.statistics(:scheduler_wall_time)

start_time = System.monotonic_time(:millisecond)
_publish_start_mono = System.monotonic_time(:microsecond)

# Publish messages and collect latencies
publish_latencies = if topic_count == 1 do
  # Single topic: publish all messages to one topic
  topic = hd(topics)
  
  for i <- 1..total_messages do
    publish_start = System.monotonic_time(:microsecond)
    
    # Create gRPC request with timestamp for end-to-end latency measurement
    request = struct(Ratatoskr.Grpc.PublishRequest, [
      topic: topic,
      payload: Jason.encode!(%{
        id: i,
        timestamp: publish_start,
        source: "external_publisher",
        test: "production_load"
      }),
      metadata: %{"seq" => to_string(i), "publisher" => "external"}
    ])
    
    # REAL gRPC NETWORK CALL
    {:ok, _response} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
    
    publish_end = System.monotonic_time(:microsecond)
    publish_latency = publish_end - publish_start
    
    # Progress reporting
    if rem(i, max(div(total_messages, 10), 1)) == 0 do
      progress = Float.round(i / total_messages * 100, 1)
      current_publisher_mb = PublisherMemoryHelper.get_publisher_memory_mb()
      IO.puts("📈 #{i}/#{total_messages} (#{progress}%) | Publisher: #{current_publisher_mb}MB")
    end
    
    publish_latency
  end
else
  # Multiple topics: distribute messages across topics
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
    
    topic_latencies = for _msg_idx <- 1..messages_for_this_topic do
      new_count = msg_count + 1
      publish_start = System.monotonic_time(:microsecond)
      
      # Create gRPC request
      request = struct(Ratatoskr.Grpc.PublishRequest, [
        topic: topic,
        payload: Jason.encode!(%{
          id: new_count,
          timestamp: publish_start,
          topic_idx: topic_idx,
          source: "external_publisher",
          test: "production_load"
        }),
        metadata: %{"seq" => to_string(new_count), "publisher" => "external"}
      ])
      
      # REAL gRPC NETWORK CALL
      {:ok, _response} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
      
      publish_end = System.monotonic_time(:microsecond)
      publish_latency = publish_end - publish_start
      
      # Progress reporting
      if rem(new_count, max(div(total_messages, 10), 1)) == 0 do
        progress = Float.round(new_count / total_messages * 100, 1)
        current_publisher_mb = PublisherMemoryHelper.get_publisher_memory_mb()
        IO.puts("📈 #{new_count}/#{total_messages} (#{progress}%) | Publisher: #{current_publisher_mb}MB")
      end
      
      publish_latency
    end
    
    {msg_count + messages_for_this_topic, acc_latencies ++ topic_latencies}
  end)
  
  latencies
end

end_time = System.monotonic_time(:millisecond)
total_duration_ms = end_time - start_time
publishing_throughput = round(total_messages * 1000 / max(total_duration_ms, 1))

# Get CPU utilization
cpu_sample_end = :erlang.statistics(:scheduler_wall_time)
cpu_utilization = CPUHelper.calculate_utilization(cpu_sample_start, cpu_sample_end)

# Publisher memory after publishing
final_publisher_mb = PublisherMemoryHelper.get_publisher_memory_mb()
publisher_overhead = final_publisher_mb - baseline_publisher_mb

IO.puts("")
IO.puts("✅ Publishing complete!")
IO.puts("📊 Published #{total_messages} messages in #{total_duration_ms}ms")
IO.puts("📊 Publishing throughput: #{publishing_throughput} msg/s")
IO.puts("📊 CPU utilization: #{cpu_utilization}%")
IO.puts("📊 Publisher memory overhead: #{publisher_overhead}MB")

# Calculate publish latency statistics
avg_publish_latency = if length(publish_latencies) > 0 do
  Enum.sum(publish_latencies) / length(publish_latencies) / 1000  # Convert to ms
else
  0.0
end

p99_publish_latency = if length(publish_latencies) > 0 do
  sorted = Enum.sort(publish_latencies)
  p99_idx = max(0, div(length(sorted) * 99, 100) - 1)
  (Enum.at(sorted, p99_idx) || 0) / 1000  # Convert to ms
else
  0.0
end

p50_publish_latency = if length(publish_latencies) > 0 do
  sorted = Enum.sort(publish_latencies)
  p50_idx = max(0, div(length(sorted) * 50, 100) - 1)
  (Enum.at(sorted, p50_idx) || 0) / 1000  # Convert to ms
else
  0.0
end

min_latency = if length(publish_latencies) > 0 do
  Enum.min(publish_latencies) / 1000
else
  0.0
end

max_latency = if length(publish_latencies) > 0 do
  Enum.max(publish_latencies) / 1000
else
  0.0
end

# Disconnect
GRPC.Stub.disconnect(channel)

# Generate results
timestamp = DateTime.utc_now() |> DateTime.to_string() |> String.replace(~r/[^0-9]/, "")
filename = "/tmp/external_publisher_#{total_messages}m_#{topic_count}t_#{timestamp}.txt"

results = """
📤 === EXTERNAL gRPC PUBLISHER RESULTS ===

📝 **PUBLISHER CONFIGURATION:**
• Messages published: #{total_messages}
• Target topics: #{topic_count}
• Role: External gRPC client (production simulation)
• Connection: gRPC/HTTP2 to localhost:9090

🚀 **PUBLISHING PERFORMANCE:**
• Throughput: #{publishing_throughput} msg/s
• Duration: #{Float.round(total_duration_ms / 1000, 2)}s
• Average latency: #{Float.round(avg_publish_latency, 3)}ms
• P50 latency: #{Float.round(p50_publish_latency, 3)}ms
• P99 latency: #{Float.round(p99_publish_latency, 3)}ms
• Min latency: #{Float.round(min_latency, 3)}ms
• Max latency: #{Float.round(max_latency, 3)}ms

💾 **PUBLISHER RESOURCE USAGE:**
• Baseline memory: #{baseline_publisher_mb}MB
• Final memory: #{final_publisher_mb}MB
• Memory overhead: #{publisher_overhead}MB
• Memory per message: #{if total_messages > 0, do: Float.round(publisher_overhead / total_messages * 1024, 3), else: 0}KB
• CPU utilization: #{cpu_utilization}%

📊 **CLIENT EXPERIENCE:**
• Publishing Rate: #{publishing_throughput} msg/s
• Typical Latency: #{Float.round(p50_publish_latency, 3)}ms
• Tail Latency (P99): #{Float.round(p99_publish_latency, 3)}ms
• Client Overhead: #{publisher_overhead}MB for #{total_messages} messages

🎯 **PRODUCTION ASSESSMENT:**
✅ Throughput: #{if publishing_throughput > 1000, do: "Excellent (>1000 msg/s)", else: "Good"}
✅ Latency: #{if p99_publish_latency < 5.0, do: "Excellent (<5ms P99)", else: "Acceptable"}  
✅ Memory: #{if publisher_overhead < 10, do: "Lightweight (<10MB)", else: "Moderate"}

System: MacBook Air M4, External gRPC client
Protocol: gRPC/HTTP2 with Protocol Buffers
Timestamp: #{DateTime.utc_now() |> DateTime.to_iso8601()}
"""

# Write and display results
File.write!(filename, results)

IO.puts("")
IO.puts(results)
IO.puts("✅ External publisher complete! Results saved to: #{filename}")
IO.puts("")
IO.puts("📋 Next: Check the broker monitor for delivery performance and memory consumption!")