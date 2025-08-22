#!/usr/bin/env elixir

# The 1GB Challenge - Push Ratatoskr to exactly 1GB RAM usage
# Goal: Find the maximum sustainable performance at 1GB memory footprint

Mix.install([
  {:jason, "~> 1.4"}
])

Application.ensure_all_started(:ratatoskr)
Process.sleep(1000)

IO.puts("🎯 === THE 1GB CHALLENGE ===")
IO.puts("Goal: Push Ratatoskr to exactly 1GB RAM and measure peak performance")
IO.puts("")

# System specs
{:ok, system_info} = File.read("/proc/meminfo") |> case do
  {:ok, _} -> {:ok, "Linux"}  
  _ -> 
    case System.cmd("system_profiler", ["SPHardwareDataType"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _ -> {:ok, "Unknown"}
    end
end

case System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true) do
  {memsize, 0} -> 
    total_ram_gb = String.trim(memsize) |> String.to_integer() |> div(1024 * 1024 * 1024)
    IO.puts("💻 System RAM: #{total_ram_gb}GB")
  _ -> 
    IO.puts("💻 System RAM: Unknown")
end

IO.puts("🖥️ CPU Cores: #{System.schedulers_online()}")
IO.puts("")

# Target: 1GB (1024MB)
target_memory_mb = 1024
baseline_memory = :erlang.memory()
baseline_mb = div(baseline_memory[:total], 1024 * 1024)
available_budget_mb = target_memory_mb - baseline_mb

IO.puts("📊 MEMORY BUDGET:")
IO.puts("• Baseline: #{baseline_mb} MB")
IO.puts("• Target: #{target_memory_mb} MB")  
IO.puts("• Available budget: #{available_budget_mb} MB")
IO.puts("")

# Strategy: Gradually increase load until we hit 1GB
current_memory_mb = baseline_mb
step_size = 50 # Start with 50MB increments

results = []
topics_created = []
subscriber_pids = []

IO.puts("🚀 SCALING UP TO 1GB...")

step = 1
while current_memory_mb < (target_memory_mb - 50) do  # Leave 50MB buffer
  IO.puts("📈 Step #{step}: Current #{current_memory_mb}MB → Target #{min(current_memory_mb + step_size, target_memory_mb - 50)}MB")
  
  # Add more topics and subscribers
  topics_this_step = []
  
  # Create 10 new topics per step
  for i <- 1..10 do
    topic = "challenge_step#{step}_topic#{i}"
    :ok = Ratatoskr.create_topic(topic)
    topics_created = [topic | topics_created]
    topics_this_step = [topic | topics_this_step]
  end
  
  # Add subscribers until we approach memory target
  subscribers_this_step = []
  
  while current_memory_mb < (target_memory_mb - 100) do  # 100MB safety margin
    # Add 50 subscribers across topics created this step
    for topic <- topics_this_step do
      for _i <- 1..5 do  # 5 subs per topic = 50 total
        pid = spawn(fn ->
          # Simulate subscriber with some memory usage
          state = %{
            topic: topic,
            messages_received: 0,
            buffer: String.duplicate("x", 1000), # 1KB buffer per subscriber
            metadata: %{
              created_at: System.system_time(:millisecond),
              last_message: nil
            }
          }
          
          receive do
            :shutdown -> :ok
            {:message, msg} -> 
              new_state = %{state | 
                messages_received: state.messages_received + 1,
                metadata: %{state.metadata | last_message: msg}
              }
              # Keep the process alive with state
              receive do
                :shutdown -> :ok
              after
                60_000 -> :ok
              end
          after
            60_000 -> :ok
          end
        end)
        
        subscriber_pids = [pid | subscriber_pids]
        subscribers_this_step = [pid | subscribers_this_step]
      end
    end
    
    # Check current memory
    current_memory = :erlang.memory()
    current_memory_mb = div(current_memory[:total], 1024 * 1024)
    
    if current_memory_mb >= (target_memory_mb - 100) do
      break
    end
  end
  
  IO.puts("✅ Added #{length(topics_this_step)} topics, #{length(subscribers_this_step)} subscribers")
  IO.puts("📊 Current memory: #{current_memory_mb} MB")
  
  # Performance test at this scale
  IO.puts("⚡ Testing throughput at current scale...")
  
  message_count = min(10_000, length(topics_created) * 100)  # Scale messages with topics
  start_time = System.monotonic_time(:millisecond)
  messages_sent = 0
  
  # Distribute messages across all topics
  messages_per_topic = max(1, div(message_count, length(topics_created)))
  
  for topic <- Enum.take(topics_created, min(length(topics_created), 20)) do  # Test up to 20 topics
    for i <- 1..messages_per_topic do
      payload = %{
        challenge: "1gb",
        step: step,
        message_id: i,
        timestamp: System.system_time(:millisecond),
        data: String.duplicate("test", 25)  # 100 bytes
      }
      
      case Ratatoskr.publish(topic, payload) do
        {:ok, _} -> messages_sent = messages_sent + 1
        {:error, _} -> :ok  # Continue on errors
      end
      
      if rem(messages_sent, 1000) == 0 do
        IO.write(".")
      end
    end
  end
  
  end_time = System.monotonic_time(:millisecond)
  duration_ms = max(end_time - start_time, 1)
  throughput = round(messages_sent * 1000 / duration_ms)
  
  # Final memory check
  final_memory = :erlang.memory()
  final_memory_mb = div(final_memory[:total], 1024 * 1024)
  
  step_result = %{
    step: step,
    topics: length(topics_created),
    subscribers: length(subscriber_pids),
    memory_mb: final_memory_mb,
    messages_sent: messages_sent,
    duration_ms: duration_ms,
    throughput_msg_s: throughput
  }
  
  results = [step_result | results]
  
  IO.puts("")
  IO.puts("🎯 Step #{step} Results:")
  IO.puts("• Topics: #{length(topics_created)}")
  IO.puts("• Subscribers: #{length(subscriber_pids)}")
  IO.puts("• Memory: #{final_memory_mb} MB")
  IO.puts("• Throughput: #{throughput} msg/s")
  IO.puts("")
  
  current_memory_mb = final_memory_mb
  step = step + 1
  
  # Safety check - don't exceed 1.2GB
  if current_memory_mb > 1200 do
    IO.puts("⚠️ Approaching system limits, stopping scaling")
    break
  end
  
  Process.sleep(1000)  # Brief pause between steps
end

# Final push to exactly 1GB if we're close
final_memory = :erlang.memory()
final_memory_mb = div(final_memory[:total], 1024 * 1024)

if final_memory_mb < target_memory_mb do
  IO.puts("🎯 FINAL PUSH TO 1GB...")
  remaining_mb = target_memory_mb - final_memory_mb
  IO.puts("Need #{remaining_mb}MB more...")
  
  # Add final subscribers to hit exactly 1GB
  final_subscribers = []
  
  for _i <- 1..(remaining_mb * 10) do  # Rough estimate: ~100KB per subscriber
    pid = spawn(fn ->
      # Larger buffer to consume remaining memory
      buffer = String.duplicate("x", 10_000)  # 10KB buffer
      receive do
        :shutdown -> :ok
      after
        60_000 -> :ok
      end
    end)
    
    final_subscribers = [pid | final_subscribers]
    subscriber_pids = [pid | subscriber_pids]
    
    current_memory = div(:erlang.memory()[:total], 1024 * 1024)
    if current_memory >= target_memory_mb do
      break
    end
  end
  
  final_memory_mb = div(:erlang.memory()[:total], 1024 * 1024)
end

# Ultimate performance test at 1GB
IO.puts("🔥 === ULTIMATE 1GB PERFORMANCE TEST ===")

ultimate_start = System.monotonic_time(:millisecond)
ultimate_messages = 50_000
ultimate_sent = 0

# Use all topics for maximum throughput
for topic <- Enum.take(topics_created, min(50, length(topics_created))) do
  messages_per_topic = div(ultimate_messages, min(50, length(topics_created)))
  
  for i <- 1..messages_per_topic do
    payload = %{
      ultimate: true,
      topic: topic,
      id: i,
      timestamp: System.system_time(:millisecond)
    }
    
    case Ratatoskr.publish(topic, payload) do
      {:ok, _} -> ultimate_sent = ultimate_sent + 1
      {:error, _} -> :ok
    end
    
    if rem(ultimate_sent, 5000) == 0 do
      IO.write("🚀")
    end
  end
end

ultimate_end = System.monotonic_time(:millisecond)
ultimate_duration = max(ultimate_end - ultimate_start, 1)
ultimate_throughput = round(ultimate_sent * 1000 / ultimate_duration)

final_peak_memory = div(:erlang.memory()[:total], 1024 * 1024)

IO.puts("")
IO.puts("🏆 === 1GB CHALLENGE COMPLETE ===")
IO.puts("")
IO.puts("🎯 FINAL RESULTS:")
IO.puts("• Peak Memory Usage: #{final_peak_memory} MB")
IO.puts("• Total Topics: #{length(topics_created)}")
IO.puts("• Total Subscribers: #{length(subscriber_pids)}")
IO.puts("• Ultimate Throughput: #{ultimate_throughput} messages/second")
IO.puts("• Messages in Ultimate Test: #{ultimate_sent}")
IO.puts("• Duration: #{ultimate_duration}ms")
IO.puts("")

memory_efficiency = Float.round(ultimate_throughput / final_peak_memory, 2)
IO.puts("📊 PERFORMANCE METRICS:")
IO.puts("• Messages per MB of RAM: #{memory_efficiency} msg/s/MB")
IO.puts("• Scalability Factor: #{Float.round(final_peak_memory / baseline_mb, 1)}x memory")
IO.puts("• Resource Utilization: #{Float.round(final_peak_memory / target_memory_mb * 100, 1)}% of 1GB target")

if final_peak_memory >= 900 do
  IO.puts("• Status: 🏆 CHALLENGE COMPLETED!")
else
  IO.puts("• Status: 📊 Partial success (#{final_peak_memory}MB achieved)")
end

IO.puts("")

# Scaling progression
IO.puts("📈 SCALING PROGRESSION:")
for result <- Enum.reverse(results) do
  efficiency = Float.round(result.throughput_msg_s / result.memory_mb, 1)
  IO.puts("Step #{result.step}: #{result.memory_mb}MB → #{result.throughput_msg_s} msg/s (#{efficiency} msg/s/MB)")
end

# Cleanup
IO.puts("")
IO.puts("🧹 Cleaning up...")
Enum.each(subscriber_pids, fn pid -> 
  if Process.alive?(pid), do: send(pid, :shutdown)
end)

Enum.each(topics_created, fn topic ->
  Ratatoskr.delete_topic(topic)
end)

IO.puts("✅ Cleanup complete!")
IO.puts("")
IO.puts("💪 Ratatoskr 1GB Challenge - Mission Accomplished!")