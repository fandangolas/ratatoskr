defmodule Ratatoskr.PerformanceTest do
  use ExUnit.Case, async: false
  alias Ratatoskr.BenchmarkHelpers
  require Logger

  @moduletag :performance
  @moduletag timeout: 30_000  # 30 second timeout for performance tests

  describe "Throughput Benchmarks" do
    test "achieves 1000+ messages per second throughput" do
      topic_name = BenchmarkHelpers.benchmark_topic("throughput_1000")
      
      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)
      
      Logger.info("Starting throughput benchmark: 1000 messages")
      
      assert {:ok, results} = BenchmarkHelpers.measure_throughput(1000, topic_name)
      
      Logger.info("Throughput results: #{inspect(results)}")
      
      # Assert we meet the 1000 msg/s requirement
      assert results.throughput >= 1000.0, 
        "Expected throughput ≥1000 msg/s, got #{Float.round(results.throughput, 2)} msg/s"
      
      assert results.messages_sent == 1000
      assert results.time_ms > 0
      
      # Log performance metrics
      Logger.info([
        "✅ Throughput: #{Float.round(results.throughput, 2)} msg/s",
        "⏱️  Total time: #{results.time_ms}ms", 
        "📊 Avg time per message: #{results.avg_time_per_message_us}μs"
      ] |> Enum.join(" | "))
    end

    test "high throughput benchmark: 5000 messages" do
      topic_name = BenchmarkHelpers.benchmark_topic("throughput_5000")
      
      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)
      
      Logger.info("Starting high throughput benchmark: 5000 messages")
      
      assert {:ok, results} = BenchmarkHelpers.measure_throughput(5000, topic_name)
      
      Logger.info([
        "🚀 High throughput: #{Float.round(results.throughput, 2)} msg/s",
        "⏱️  Total time: #{results.time_ms}ms",
        "📈 Messages: #{results.messages_sent}"
      ] |> Enum.join(" | "))
      
      # Should still maintain good performance at scale
      assert results.throughput >= 500.0,
        "Expected high-volume throughput ≥500 msg/s, got #{Float.round(results.throughput, 2)} msg/s"
    end

    test "throughput with memory monitoring" do
      topic_name = BenchmarkHelpers.benchmark_topic("throughput_memory")
      
      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)
      
      Logger.info("Starting throughput benchmark with memory monitoring")
      
      assert {:ok, memory_results} = BenchmarkHelpers.measure_memory_usage(fn ->
        BenchmarkHelpers.measure_throughput(2000, topic_name)
      end)
      
      {:ok, throughput_results} = memory_results.result
      
      Logger.info([
        "📊 Throughput: #{Float.round(throughput_results.throughput, 2)} msg/s",
        "🧠 Memory used: #{Float.round(memory_results.memory_used_mb, 2)} MB",
        "⚙️  Processes: +#{memory_results.process_count_diff}"
      ] |> Enum.join(" | "))
      
      # Memory should be reasonable (< 10MB for 2000 messages)
      assert memory_results.memory_used_mb < 10.0,
        "Memory usage too high: #{Float.round(memory_results.memory_used_mb, 2)} MB"
      
      assert throughput_results.throughput >= 1000.0
    end
  end

  describe "Latency Benchmarks" do  
    test "measures end-to-end latency with percentiles" do
      topic_name = BenchmarkHelpers.benchmark_topic("latency_test")
      
      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)
      
      Logger.info("Starting latency benchmark: 100 messages")
      
      assert {:ok, latency_results} = BenchmarkHelpers.measure_latencies(100, topic_name)
      
      Logger.info("Latency results: #{inspect(latency_results)}")
      
      # Validate latency measurements
      assert latency_results.count == 100
      assert latency_results.min >= 0
      assert latency_results.max > latency_results.min
      assert latency_results.p50 > 0
      assert latency_results.p95 > 0  
      assert latency_results.p99 > 0
      
      # Log detailed latency metrics
      Logger.info([
        "📊 Latencies (ms):",
        "Min: #{latency_results.min}",
        "P50: #{latency_results.p50}", 
        "P95: #{latency_results.p95}",
        "P99: #{latency_results.p99}",
        "Max: #{latency_results.max}",
        "Avg: #{latency_results.avg}"
      ] |> Enum.join(" | "))
      
      # For MVP, we expect reasonable latencies (p99 < 100ms)
      # Future target is p99 < 10ms
      assert latency_results.p99 < 100.0,
        "P99 latency too high: #{latency_results.p99}ms (expected < 100ms for MVP)"
        
      assert latency_results.p50 < 50.0,
        "P50 latency too high: #{latency_results.p50}ms (expected < 50ms)"
    end

    test "latency under load: 1000 messages" do
      topic_name = BenchmarkHelpers.benchmark_topic("latency_load")
      
      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)
      
      Logger.info("Starting latency under load: 1000 messages")
      
      assert {:ok, latency_results} = BenchmarkHelpers.measure_latencies(1000, topic_name)
      
      Logger.info([
        "📈 Load test latencies (ms):",
        "P50: #{latency_results.p50}",
        "P95: #{latency_results.p95}", 
        "P99: #{latency_results.p99}",
        "Count: #{latency_results.count}"
      ] |> Enum.join(" | "))
      
      # Under load, latencies may increase but should stay reasonable
      assert latency_results.p99 < 200.0,
        "P99 latency under load too high: #{latency_results.p99}ms"
      
      # Should process most messages successfully  
      assert latency_results.count >= 950,
        "Too many failed messages: #{1000 - latency_results.count} failures"
    end
  end
end