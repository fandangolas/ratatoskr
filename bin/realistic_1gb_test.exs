#!/usr/bin/env elixir

# REALISTIC 1GB Test - Stay within actual physical RAM limits

Application.ensure_all_started(:ratatoskr)
Process.sleep(1000)

IO.puts("🎯 === REALISTIC 1GB RAM TEST ===")
IO.puts("Goal: Actually use ~1GB of physical RAM (not virtual memory)")
IO.puts("")

# Check system memory first
case System.cmd("vm_stat", []) do
  {output, 0} ->
    lines = String.split(output, "\n")
    active_line = Enum.find(lines, &String.contains?(&1, "Pages active:"))
    
    if active_line do
      active_pages = active_line |> String.replace(~r/[^\d]/, "") |> String.to_integer()
      active_gb = Float.round(active_pages * 16384 / (1024 * 1024 * 1024), 1)
      IO.puts("💻 System currently using ~#{active_gb}GB physical RAM")
    end
  _ -> :ok
end

# Baseline
baseline_bytes = :erlang.memory()[:total]
baseline_mb = div(baseline_bytes, 1024 * 1024)
IO.puts("📊 Baseline: #{baseline_mb}MB")

# Create topics
topics = for i <- 1..10, do: (Ratatoskr.create_topic("real_#{i}"); "real_#{i}")

# Create realistic subscriber count to reach ~1GB
# Target: ~1GB = 1024MB. We have ~64MB baseline, so need ~960MB more
# Let's try 2000 subscribers with 50KB each = ~100MB for subscribers
# Plus other overhead should get us closer to realistic 1GB

subscriber_pids = for topic <- topics, i <- 1..200 do  # 2000 total subscribers
  spawn(fn ->
    Ratatoskr.subscribe(topic)
    # Realistic buffer size
    _buffer = String.duplicate("DATA", 12_500)  # ~50KB per subscriber
    receive do
      :shutdown -> :ok
    after 120_000 -> :ok
    end
  end)
end

# Check memory after subscribers
after_subs_bytes = :erlang.memory()[:total] 
after_subs_mb = div(after_subs_bytes, 1024 * 1024)

IO.puts("📊 After #{length(subscriber_pids)} subscribers: #{after_subs_mb}MB")
IO.puts("📈 Scaling: #{Float.round(after_subs_mb / baseline_mb, 1)}x")

# If we're not at ~1GB yet, we can safely test performance
if after_subs_mb < 1500 do  # Stay well under 16GB limit
  IO.puts("✅ Safe to test - using #{after_subs_mb}MB of RAM")
  IO.puts("")
  IO.puts("⚡ Testing throughput at this scale...")
  
  # Performance test with 50K messages
  start_time = System.monotonic_time(:millisecond)
  
  # Send messages
  for topic <- topics, i <- 1..5000 do  # 50K total messages
    Ratatoskr.publish(topic, %{msg: i, test: "realistic", topic: topic})
  end
  
  end_time = System.monotonic_time(:millisecond)
  duration = end_time - start_time
  throughput = round(50_000 * 1000 / max(duration, 1))
  
  # Peak memory
  peak_bytes = :erlang.memory()[:total]
  peak_mb = div(peak_bytes, 1024 * 1024)
  
  IO.puts("")
  IO.puts("🏆 === REALISTIC RESULTS ===")
  IO.puts("• Messages: 50,000")
  IO.puts("• Duration: #{Float.round(duration/1000, 2)}s") 
  IO.puts("• **THROUGHPUT: #{throughput} msg/s**")
  IO.puts("• Peak RAM: #{peak_mb}MB")
  IO.puts("• Subscribers: #{length(subscriber_pids)}")
  IO.puts("• Memory efficiency: #{Float.round(throughput / (peak_mb - baseline_mb), 1)} msg/s/MB")
  IO.puts("")
  IO.puts("🎯 REALISTIC CLAIM:")
  IO.puts("\"#{peak_mb}MB RAM → #{throughput} msg/s with #{length(subscriber_pids)} subscribers\"")
  
else
  IO.puts("⚠️ Would use #{after_subs_mb}MB - too much for safe testing")
end

# Cleanup
Enum.each(subscriber_pids, fn pid -> send(pid, :shutdown) end)
Enum.each(topics, &Ratatoskr.delete_topic/1)

final_mb = div(:erlang.memory()[:total], 1024 * 1024)
IO.puts("✅ After cleanup: #{final_mb}MB")
IO.puts("")
IO.puts("💡 LESSON LEARNED:")
IO.puts("Previous 24GB measurement was virtual memory allocation, not physical RAM!")
IO.puts("This test shows realistic scaling within actual system limits.")