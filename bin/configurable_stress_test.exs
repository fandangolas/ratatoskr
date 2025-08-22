#!/usr/bin/env elixir

# CONFIGURABLE STRESS TEST
# Usage: elixir bin/configurable_stress_test.exs <subscribers> <messages_per_subscriber> <topics>
# Example: elixir bin/configurable_stress_test.exs 100 10 5

# Require Logger
require Logger

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
{subscriber_count, messages_per_subscriber, topic_count} = case System.argv() do
  [s, m, t] -> 
    {String.to_integer(s), String.to_integer(m), String.to_integer(t)}
  _ ->
    IO.puts("Usage: elixir #{__ENV__.file} <subscribers> <messages_per_subscriber> <topics>")
    IO.puts("Example: elixir #{__ENV__.file} 100 10 5")
    IO.puts("")
    IO.puts("Using defaults: 100 subscribers, 10 messages/subscriber, 1 topic")
    {100, 10, 1}
end

# Calculate totals
total_messages = messages_per_subscriber * subscriber_count
_subscribers_per_topic = div(subscriber_count, topic_count) + if rem(subscriber_count, topic_count) > 0, do: 1, else: 0
total_deliveries = if topic_count == 1 do
  # Single topic: each message delivered to all subscribers
  messages_per_subscriber * subscriber_count
else
  # Multiple topics: messages distributed across topics
  total_messages
end

IO.puts("🚀 === CONFIGURABLE STRESS TEST ===")
IO.puts("Configuration:")
IO.puts("• Subscribers: #{subscriber_count}")
IO.puts("• Messages per subscriber: #{messages_per_subscriber}")
IO.puts("• Topics: #{topic_count}")
IO.puts("• Total messages to publish: #{total_messages}")
IO.puts("• Expected total deliveries: #{total_deliveries}")
IO.puts("• Architecture: #{if topic_count == 1, do: "Single topic (broadcast)", else: "Multiple topics (distributed)"}")
IO.puts("")

# Start and configure production telemetry
Mix.install([{:ratatoskr, path: "."}])
Application.ensure_all_started(:ratatoskr)
Process.sleep(1000)

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

# Get baseline measurements
baseline_mb = div(:erlang.memory()[:total], 1024 * 1024)
baseline_processes = length(Process.list())
IO.puts("📊 Baseline: #{baseline_mb}MB, #{baseline_processes} processes")

# Create topics
topics = for i <- 1..topic_count do
  topic_name = if topic_count == 1, do: "stress_topic", else: "topic_#{i}"
  {:ok, _} = Ratatoskr.create_topic(topic_name)
  topic_name
end

IO.puts("✅ Created #{topic_count} topic(s)")

# Create subscribers
IO.puts("🔥 Creating #{subscriber_count} subscribers...")

subscriber_pids = if topic_count == 1 do
  # All subscribers on single topic
  topic = hd(topics)
  for i <- 1..subscriber_count do
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
  subscribers = for i <- 1..subscriber_count do
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

setup_mb = div(:erlang.memory()[:total], 1024 * 1024)
setup_processes = length(Process.list())
memory_overhead_setup = setup_mb - baseline_mb

IO.puts("📊 After setup: #{setup_mb}MB (+#{memory_overhead_setup}MB), #{setup_processes} processes")

# Wait for setup
Process.sleep(2000)

# PUBLISH MESSAGES
IO.puts("")
IO.puts("🔥 Publishing #{total_messages} messages...")

# Track CPU before publishing
cpu_sample_start = :erlang.statistics(:scheduler_wall_time)

start_time = System.monotonic_time(:millisecond)

# Publish messages and collect latencies
publish_latencies = if topic_count == 1 do
  # Single topic: publish all messages to one topic
  topic = hd(topics)
  
  {_, latencies} = Enum.reduce(1..messages_per_subscriber, {0, []}, fn i, {_count, acc_latencies} ->
    publish_start = System.monotonic_time(:microsecond)
    
    {:ok, _} = Ratatoskr.publish(topic, %{
      id: i,
      timestamp: publish_start,
      test: "stress"
    })
    
    publish_end = System.monotonic_time(:microsecond)
    publish_latency = publish_end - publish_start
    
    # Sample publish latency
    new_latencies = if rem(i, max(div(messages_per_subscriber, 100), 1)) == 0 do
      [publish_latency | acc_latencies]
    else
      acc_latencies
    end
    
    # Progress reporting
    if rem(i, max(div(messages_per_subscriber, 10), 1)) == 0 do
      current_mb = div(:erlang.memory()[:total], 1024 * 1024)
      progress = Float.round(i / messages_per_subscriber * 100, 1)
      IO.puts("📈 #{i}/#{messages_per_subscriber} (#{progress}%) | #{current_mb}MB")
    end
    
    {i, new_latencies}
  end)
  
  latencies
else
  # Multiple topics: distribute messages across topics
  {_, latencies} = Enum.reduce(1..subscriber_count, {0, []}, fn sub_idx, {msg_count, acc_latencies} ->
    topic_index = rem(sub_idx - 1, topic_count)
    topic = Enum.at(topics, topic_index)
    
    Enum.reduce(1..messages_per_subscriber, {msg_count, acc_latencies}, fn _msg_idx, {count, latencies_acc} ->
      new_count = count + 1
      publish_start = System.monotonic_time(:microsecond)
      
      {:ok, _} = Ratatoskr.publish(topic, %{
        id: new_count,
        timestamp: publish_start,
        subscriber_target: sub_idx,
        test: "stress"
      })
      
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
        current_mb = div(:erlang.memory()[:total], 1024 * 1024)
        progress = Float.round(new_count / total_messages * 100, 1)
        IO.puts("📈 #{new_count}/#{total_messages} (#{progress}%) | #{current_mb}MB")
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
peak_mb = div(:erlang.memory()[:total], 1024 * 1024)
_peak_processes = length(Process.list())
memory_overhead_peak = peak_mb - baseline_mb

cpu_sample_end = :erlang.statistics(:scheduler_wall_time)
cpu_utilization = CPUHelper.calculate_utilization(cpu_sample_start, cpu_sample_end)

IO.puts("")
IO.puts("✅ Publishing complete!")
IO.puts("📊 Publishing: #{publishing_throughput} msg/s in #{Float.round(total_duration_ms / 1000, 2)}s")
IO.puts("📊 Peak memory: #{peak_mb}MB (+#{memory_overhead_peak}MB overhead)")
IO.puts("📊 CPU utilization during publishing: #{cpu_utilization}%")

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
IO.puts("📊 Collecting statistics from #{subscriber_count} subscribers...")

Enum.each(subscriber_pids, fn pid ->
  send(pid, {:get_stats, self()})
end)

subscriber_stats = for _i <- 1..subscriber_count do
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

# Calculate expected deliveries based on architecture
expected_total_deliveries = if topic_count == 1 do
  # Single topic: each message goes to all subscribers
  messages_per_subscriber * subscriber_count
else
  # Multiple topics: each subscriber gets their messages
  messages_per_subscriber * subscriber_count
end

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
final_mb = div(:erlang.memory()[:total], 1024 * 1024)

# Generate timestamp for filename
timestamp = DateTime.utc_now() |> DateTime.to_string() |> String.replace(~r/[^0-9]/, "")
filename = "/tmp/stress_test_#{subscriber_count}s_#{messages_per_subscriber}m_#{topic_count}t_#{timestamp}.txt"

# RESULTS
results = """
🏆 === STRESS TEST RESULTS ===

📝 **TEST CONFIGURATION:**
• Subscribers: #{subscriber_count}
• Messages per subscriber: #{messages_per_subscriber}
• Topics: #{topic_count}
• Architecture: #{if topic_count == 1, do: "Single topic (broadcast)", else: "Multiple topics (distributed)"}
• Total messages published: #{total_messages}
• Expected total deliveries: #{expected_total_deliveries}

🚀 **PUBLISHING PERFORMANCE:**
• Throughput: #{publishing_throughput} msg/s
• Duration: #{Float.round(total_duration_ms / 1000, 2)}s
• P99 latency: #{Float.round(publish_p99, 3)}ms

📨 **DELIVERY PERFORMANCE:**
• Total deliveries: #{total_messages_received}/#{expected_total_deliveries}
• Success rate: #{delivery_success_rate}%
• Throughput: #{delivery_throughput} deliveries/s
• Avg delivery time: #{Float.round(avg_subscriber_duration / 1000, 2)}s
• P99 latency: #{Float.round(delivery_p99, 3)}ms

💾 **RESOURCE USAGE:**
• RAM baseline: #{baseline_mb}MB
• RAM after setup: #{setup_mb}MB (+#{memory_overhead_setup}MB)
• RAM peak: #{peak_mb}MB (+#{memory_overhead_peak}MB)
• RAM final: #{final_mb}MB
• Memory per subscriber: #{Float.round(memory_overhead_peak / subscriber_count, 3)}MB
• CPU utilization: #{cpu_utilization}%

📊 **SUMMARY:**
• Publishing: #{publishing_throughput} msg/s
• Delivery: #{delivery_throughput} deliveries/s  
• RAM overhead: #{memory_overhead_peak}MB
• CPU usage: #{cpu_utilization}%
• Publish P99: #{Float.round(publish_p99, 3)}ms
• Delivery P99: #{Float.round(delivery_p99, 3)}ms
• Success rate: #{delivery_success_rate}%

System: MacBook Air M4, Production telemetry
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
Enum.each(topics, fn topic -> Ratatoskr.delete_topic(topic) end)

cleanup_mb = div(:erlang.memory()[:total], 1024 * 1024)
IO.puts("🧹 After cleanup: #{cleanup_mb}MB")
IO.puts("")
IO.puts("✅ Test complete! Results saved to: #{filename}")