#!/usr/bin/env elixir

# Real Baseline Performance Benchmark
# Get actual performance numbers to replace theoretical ones in README

Application.ensure_all_started(:ratatoskr)
Process.sleep(1000) # Give time to start

IO.puts("=== REAL RATATOSKR BASELINE BENCHMARK ===")
IO.puts("Testing actual performance on your system...")
IO.puts("")

# Get system info
case System.cmd("system_profiler", ["SPHardwareDataType"], stderr_to_stdout: true) do
  {output, 0} ->
    model = output |> String.split("\n") |> Enum.find(&String.contains?(&1, "Model Name")) |> 
           case do
             nil -> "Unknown Mac"
             line -> line |> String.split(":") |> List.last() |> String.trim()
           end
    
    chip = output |> String.split("\n") |> Enum.find(&String.contains?(&1, "Chip")) |> 
           case do
             nil -> "Unknown"
             line -> line |> String.split(":") |> List.last() |> String.trim()
           end
           
    memory = output |> String.split("\n") |> Enum.find(&String.contains?(&1, "Memory")) |> 
             case do
               nil -> "Unknown"
               line -> line |> String.split(":") |> List.last() |> String.trim()
             end
    
    IO.puts("💻 SYSTEM SPECIFICATIONS:")
    IO.puts("• Model: #{model}")
    IO.puts("• Chip: #{chip}")
    IO.puts("• RAM: #{memory}")
  _ ->
    IO.puts("💻 System: Unknown (non-Mac or system_profiler unavailable)")
end

IO.puts("")

# Baseline memory before any test
baseline_memory = :erlang.memory()
baseline_mb = div(baseline_memory[:total], 1024 * 1024)
baseline_processes = :erlang.system_info(:process_count)

IO.puts("📊 BASELINE MEASUREMENTS:")
IO.puts("• Baseline memory: #{baseline_mb}MB")
IO.puts("• Baseline processes: #{baseline_processes}")
IO.puts("")

# Test 1: Basic API Performance
IO.puts("🚀 TEST 1: Basic API Performance")

# Create test topic
{:ok, topic} = Ratatoskr.create_topic("real_perf_test")

# Simple publishing test
messages_to_send = 1000
start_time = System.monotonic_time(:millisecond)

for i <- 1..messages_to_send do
  {:ok, _message_id} = Ratatoskr.publish("real_perf_test", %{
    id: i,
    data: "test message #{i}",
    timestamp: System.system_time(:millisecond)
  })
end

end_time = System.monotonic_time(:millisecond)
duration_ms = end_time - start_time
throughput = round(messages_to_send * 1000 / max(duration_ms, 1))

after_basic_memory = :erlang.memory()
after_basic_mb = div(after_basic_memory[:total], 1024 * 1024)

IO.puts("✅ Basic API Results:")
IO.puts("• Messages: #{messages_to_send}")
IO.puts("• Duration: #{duration_ms}ms")
IO.puts("• Throughput: #{throughput} msg/s")
IO.puts("• Memory: #{after_basic_mb}MB")
IO.puts("")

# Test 2: With Subscribers
IO.puts("🎯 TEST 2: With Subscribers")

# Create some subscriber processes
subscriber_count = 50
subscriber_pids = for i <- 1..subscriber_count do
  spawn(fn ->
    {:ok, _ref} = Ratatoskr.subscribe("real_perf_test")
    
    # Simple message receiver loop
    receive_loop = fn loop_fn ->
      receive do
        {:message, _msg} -> loop_fn.(loop_fn)
        :shutdown -> :ok
      after
        30_000 -> :ok  # 30 second timeout
      end
    end
    
    receive_loop.(receive_loop)
  end)
end

# Give subscribers time to register
Process.sleep(500)

# Memory after subscribers
after_subs_memory = :erlang.memory()
after_subs_mb = div(after_subs_memory[:total], 1024 * 1024)

# Publishing test with subscribers
messages_with_subs = 1000
start_time_subs = System.monotonic_time(:millisecond)

for i <- 1..messages_with_subs do
  {:ok, _message_id} = Ratatoskr.publish("real_perf_test", %{
    id: i,
    data: "subscriber test #{i}",
    timestamp: System.system_time(:millisecond),
    subscriber_count: subscriber_count
  })
end

end_time_subs = System.monotonic_time(:millisecond)
duration_subs_ms = end_time_subs - start_time_subs
throughput_subs = round(messages_with_subs * 1000 / max(duration_subs_ms, 1))

# Final memory
final_memory = :erlang.memory()
final_mb = div(final_memory[:total], 1024 * 1024)
overhead_mb = final_mb - baseline_mb

# Get topic stats
{:ok, stats} = Ratatoskr.stats("real_perf_test")

IO.puts("✅ With Subscribers Results:")
IO.puts("• Messages: #{messages_with_subs}")
IO.puts("• Duration: #{duration_subs_ms}ms")
IO.puts("• Throughput: #{throughput_subs} msg/s")
IO.puts("• Subscribers: #{subscriber_count}")
IO.puts("• Memory with subs: #{after_subs_mb}MB")
IO.puts("• Final memory: #{final_mb}MB")
IO.puts("• Total overhead: #{overhead_mb}MB")
IO.puts("")

# Cleanup
Enum.each(subscriber_pids, fn pid -> 
  if Process.alive?(pid), do: send(pid, :shutdown)
end)

Ratatoskr.delete_topic("real_perf_test")

# Brief cleanup pause
Process.sleep(1000)
:erlang.garbage_collect()

cleanup_memory = :erlang.memory()
cleanup_mb = div(cleanup_memory[:total], 1024 * 1024)

IO.puts("🏁 === REAL PERFORMANCE SUMMARY ===")
IO.puts("")
IO.puts("📊 MEASURED PERFORMANCE:")
IO.puts("• Basic throughput: #{throughput} msg/s")
IO.puts("• With subscribers: #{throughput_subs} msg/s (#{subscriber_count} subs)")
IO.puts("• Memory baseline: #{baseline_mb}MB")
IO.puts("• Memory peak: #{final_mb}MB")
IO.puts("• Memory overhead: #{overhead_mb}MB")
IO.puts("• After cleanup: #{cleanup_mb}MB")
IO.puts("")

IO.puts("🎯 REALISTIC PERFORMANCE CLAIM:")
IO.puts("\"Testing on MacBook Air M4 16GB, Ratatoskr achieved #{throughput_subs} msg/s")
IO.puts("with #{subscriber_count} subscribers using only #{overhead_mb}MB RAM overhead\"")
IO.puts("")

efficiency = if overhead_mb > 0, do: Float.round(throughput_subs / overhead_mb, 1), else: "N/A"
IO.puts("⚡ EFFICIENCY: #{efficiency} msg/s per MB")