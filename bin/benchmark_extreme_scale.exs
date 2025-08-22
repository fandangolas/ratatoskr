#!/usr/bin/env elixir

# Extreme Scale Performance Benchmark
# Target: Push Ratatoskr to use ~1GB RAM and demonstrate massive throughput

Mix.install([
  {:jason, "~> 1.4"}
])

Application.ensure_all_started(:ratatoskr)
Process.sleep(1000) # Startup time

IO.puts("🚀 === RATATOSKR EXTREME SCALE BENCHMARK ===")
IO.puts("")

# System baseline
memory_before = :erlang.memory()
process_count_before = :erlang.system_info(:process_count)

IO.puts("📊 SYSTEM BASELINE:")
IO.puts("• Memory before: #{div(memory_before[:total], 1024 * 1024)} MB")
IO.puts("• Process count: #{process_count_before}")
IO.puts("• Available schedulers: #{System.schedulers_online()}")
IO.puts("")

# Test configurations
test_configs = [
  %{
    name: "🔥 MASSIVE SUBSCRIBER SWARM",
    description: "10,000 concurrent subscribers across 50 topics",
    topics: 50,
    subscribers_per_topic: 200,
    messages: 5000,
    target_ram_mb: 200
  },
  %{
    name: "⚡ ULTRA HIGH THROUGHPUT", 
    description: "100,000 messages/second burst test",
    topics: 10,
    subscribers_per_topic: 100,
    messages: 100_000,
    target_ram_mb: 400
  },
  %{
    name: "🏢 ENTERPRISE SIMULATION",
    description: "Multi-tenant with 100 topics, varied load",
    topics: 100,
    subscribers_per_topic: 50,
    messages: 50_000,
    target_ram_mb: 600
  },
  %{
    name: "🌊 SUSTAINED TSUNAMI",
    description: "1GB RAM target - maximum sustainable load",
    topics: 200,
    subscribers_per_topic: 100,
    messages: 200_000,
    target_ram_mb: 1000
  }
]

results = []

for config <- test_configs do
  IO.puts("#{config.name}")
  IO.puts("#{config.description}")
  IO.puts("Target: #{config.topics} topics × #{config.subscribers_per_topic} subs = #{config.topics * config.subscribers_per_topic} total subscribers")
  IO.puts("Expected RAM usage: ~#{config.target_ram_mb}MB")
  IO.puts("")

  # Create topics
  topic_names = for i <- 1..config.topics do
    topic = "extreme_#{config.name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "_")}_#{i}"
    :ok = Ratatoskr.create_topic(topic)
    topic
  end

  IO.puts("✅ Created #{length(topic_names)} topics")

  # Memory checkpoint after topic creation
  memory_after_topics = :erlang.memory()
  topic_overhead_mb = div(memory_after_topics[:total] - memory_before[:total], 1024 * 1024)
  IO.puts("📈 Memory after topics: #{div(memory_after_topics[:total], 1024 * 1024)} MB (+#{topic_overhead_mb}MB)")

  # Create subscribers (simulate with simple processes)
  subscriber_pids = []
  subscriber_count = 0

  for topic <- topic_names do
    for i <- 1..config.subscribers_per_topic do
      # Simple subscriber simulation
      pid = spawn(fn ->
        ref = make_ref()
        # Register as subscriber (simplified)
        receive do
          :shutdown -> :ok
        after
          30_000 -> :ok # 30 second timeout
        end
      end)
      
      subscriber_pids = [pid | subscriber_pids]
      subscriber_count = subscriber_count + 1
      
      # Progress indicator for large numbers
      if rem(subscriber_count, 1000) == 0 do
        IO.write("📊 Subscribers created: #{subscriber_count}...")
        current_memory = div(:erlang.memory()[:total], 1024 * 1024)
        IO.puts(" RAM: #{current_memory}MB")
      end
    end
  end

  total_subscribers = length(subscriber_pids)
  IO.puts("🎯 Total subscribers spawned: #{total_subscribers}")

  # Memory checkpoint after subscriber creation  
  memory_after_subs = :erlang.memory()
  sub_overhead_mb = div(memory_after_subs[:total] - memory_after_topics[:total], 1024 * 1024)
  current_total_mb = div(memory_after_subs[:total], 1024 * 1024)
  
  IO.puts("📈 Memory after subscribers: #{current_total_mb}MB (+#{sub_overhead_mb}MB for subscribers)")
  
  # Publishing load test
  IO.puts("🚀 Starting message publishing test...")
  
  start_time = System.monotonic_time(:millisecond)
  messages_sent = 0
  
  # Distribute messages across topics
  messages_per_topic = div(config.messages, config.topics)
  
  for topic <- topic_names do
    for i <- 1..messages_per_topic do
      payload = %{
        test: "extreme_scale",
        topic: topic,
        message_id: i,
        timestamp: System.system_time(:millisecond),
        data: String.duplicate("x", 100) # 100 bytes payload
      }
      
      case Ratatoskr.publish(topic, payload) do
        {:ok, _} -> messages_sent = messages_sent + 1
        {:error, reason} -> 
          IO.puts("❌ Publish failed: #{inspect(reason)}")
      end
      
      # Progress for high message counts
      if rem(messages_sent, 10_000) == 0 do
        elapsed = System.monotonic_time(:millisecond) - start_time
        rate = round(messages_sent * 1000 / max(elapsed, 1))
        current_memory = div(:erlang.memory()[:total], 1024 * 1024)
        IO.puts("📊 Messages: #{messages_sent}, Rate: #{rate} msg/s, RAM: #{current_memory}MB")
      end
    end
  end
  
  end_time = System.monotonic_time(:millisecond)
  duration_ms = end_time - start_time
  throughput = round(messages_sent * 1000 / max(duration_ms, 1))
  
  # Final memory measurement
  memory_final = :erlang.memory()
  final_memory_mb = div(memory_final[:total], 1024 * 1024)
  total_overhead_mb = final_memory_mb - div(memory_before[:total], 1024 * 1024)
  
  # Cleanup subscribers
  Enum.each(subscriber_pids, fn pid -> 
    if Process.alive?(pid), do: send(pid, :shutdown)
  end)
  
  # Cleanup topics
  Enum.each(topic_names, fn topic ->
    Ratatoskr.delete_topic(topic)
  end)
  
  result = %{
    config: config.name,
    topics: config.topics,
    subscribers: total_subscribers,
    messages_sent: messages_sent,
    duration_ms: duration_ms,
    throughput_msg_s: throughput,
    peak_memory_mb: final_memory_mb,
    memory_overhead_mb: total_overhead_mb,
    avg_latency_ms: duration_ms / max(messages_sent, 1)
  }
  
  results = [result | results]
  
  IO.puts("")
  IO.puts("🎯 #{config.name} RESULTS:")
  IO.puts("• Topics: #{config.topics}")
  IO.puts("• Subscribers: #{total_subscribers}")
  IO.puts("• Messages: #{messages_sent}")
  IO.puts("• Duration: #{duration_ms}ms")
  IO.puts("• Throughput: #{throughput} msg/s")
  IO.puts("• Peak Memory: #{final_memory_mb}MB")
  IO.puts("• Memory Overhead: #{total_overhead_mb}MB")
  IO.puts("• Avg Latency: #{Float.round(result.avg_latency_ms, 3)}ms")
  IO.puts("")
  
  # Brief pause between tests
  Process.sleep(2000)
  
  # Force garbage collection
  :erlang.garbage_collect()
  Process.sleep(1000)
end

# Final system state
memory_after = :erlang.memory()
process_count_after = :erlang.system_info(:process_count)

IO.puts("🏁 === BENCHMARK COMPLETE ===")
IO.puts("")
IO.puts("📊 FINAL SYSTEM STATE:")
IO.puts("• Memory after: #{div(memory_after[:total], 1024 * 1024)} MB")
IO.puts("• Process count: #{process_count_after}")
IO.puts("")

# Summary table
IO.puts("📈 PERFORMANCE SUMMARY:")
IO.puts("")
IO.puts(String.pad_trailing("Test", 25) <> String.pad_trailing("Subs", 8) <> String.pad_trailing("Msg/s", 10) <> String.pad_trailing("RAM (MB)", 10) <> "Status")
IO.puts(String.duplicate("-", 60))

for result <- Enum.reverse(results) do
  status = cond do
    result.throughput_msg_s > 50_000 -> "🔥 Extreme"
    result.throughput_msg_s > 20_000 -> "⚡ High"  
    result.throughput_msg_s > 10_000 -> "✅ Good"
    true -> "📊 Baseline"
  end
  
  subs_str = result.subscribers |> Integer.to_string() |> String.pad_trailing(8)
  throughput_str = result.throughput_msg_s |> Integer.to_string() |> String.pad_trailing(10)  
  memory_str = result.peak_memory_mb |> Integer.to_string() |> String.pad_trailing(10)
  
  IO.puts(String.pad_trailing(result.config, 25) <> subs_str <> throughput_str <> memory_str <> status)
end

IO.puts("")
IO.puts("🎯 Peak Performance Achieved!")
max_throughput = results |> Enum.map(& &1.throughput_msg_s) |> Enum.max()
max_memory = results |> Enum.map(& &1.peak_memory_mb) |> Enum.max()
max_subscribers = results |> Enum.map(& &1.subscribers) |> Enum.max()

IO.puts("• Maximum Throughput: #{max_throughput} messages/second")
IO.puts("• Peak Memory Usage: #{max_memory} MB")
IO.puts("• Maximum Concurrent Load: #{max_subscribers} subscribers")
IO.puts("")
IO.puts("💪 Ratatoskr - Built for Scale!")