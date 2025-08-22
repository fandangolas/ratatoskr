defmodule Ratatoskr.StressTest do
  use ExUnit.Case, async: false
  alias BenchmarkHelpers
  require Logger

  @moduletag :stress
  # 60 second timeout for stress tests
  @moduletag timeout: 60_000

  describe "Concurrency Stress Tests" do
    test "supports 100 concurrent subscribers" do
      topic_name = BenchmarkHelpers.benchmark_topic("concurrent_100")

      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)

      Logger.info("Starting concurrency test: 100 subscribers")

      assert {:ok, results} =
               BenchmarkHelpers.test_concurrent_subscribers(100, topic_name, 10_000)

      Logger.info("Concurrency results: #{inspect(results)}")

      # All 100 subscribers should receive the message
      assert results.subscribers_responded == 100,
             "Expected 100 subscribers to respond, got #{results.subscribers_responded}"

      assert results.subscribers_spawned == 100

      # Response time should be reasonable (< 5 seconds)
      assert results.response_time_ms < 5000,
             "Response time too slow: #{results.response_time_ms}ms"

      Logger.info(
        [
          "✅ Concurrent subscribers: #{results.subscribers_responded}/#{results.subscribers_spawned}",
          "⏱️  Response time: #{results.response_time_ms}ms",
          "📊 Success rate: #{Float.round(results.subscribers_responded / results.subscribers_spawned * 100, 1)}%"
        ]
        |> Enum.join(" | ")
      )
    end

    test "scales to 500 concurrent subscribers" do
      topic_name = BenchmarkHelpers.benchmark_topic("concurrent_500")

      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)

      Logger.info("Starting high concurrency test: 500 subscribers")

      assert {:ok, memory_results} =
               BenchmarkHelpers.measure_memory_usage(fn ->
                 BenchmarkHelpers.test_concurrent_subscribers(500, topic_name, 15_000)
               end)

      {:ok, results} = memory_results.result

      Logger.info(
        [
          "🚀 High concurrency: #{results.subscribers_responded}/#{results.subscribers_spawned}",
          "⏱️  Response time: #{results.response_time_ms}ms",
          "🧠 Memory used: #{Float.round(memory_results.memory_used_mb, 2)} MB",
          "⚙️  Processes: +#{memory_results.process_count_diff}"
        ]
        |> Enum.join(" | ")
      )

      # Should handle at least 90% of subscribers successfully
      success_rate = results.subscribers_responded / results.subscribers_spawned

      assert success_rate >= 0.9,
             "Success rate too low: #{Float.round(success_rate * 100, 1)}% (expected ≥90%)"

      # Memory usage should be proportional and reasonable (< 50MB for 500 subscribers)
      assert memory_results.memory_used_mb < 50.0,
             "Memory usage too high: #{Float.round(memory_results.memory_used_mb, 2)} MB"
    end

    test "concurrent publishers to single topic" do
      topic_name = BenchmarkHelpers.benchmark_topic("concurrent_publishers")

      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)

      Logger.info("Starting concurrent publishers test")

      # Create a subscriber to count messages
      {:ok, _topic} = Ratatoskr.create_topic(topic_name)
      {:ok, _ref} = Ratatoskr.subscribe(topic_name)

      publisher_count = 10
      messages_per_publisher = 100
      expected_total = publisher_count * messages_per_publisher

      # Spawn concurrent publishers
      {time_ms, _publisher_pids} =
        :timer.tc(fn ->
          for i <- 1..publisher_count do
            spawn_link(fn ->
              for j <- 1..messages_per_publisher do
                {:ok, _} =
                  Ratatoskr.publish(topic_name, %{
                    publisher: i,
                    message: j,
                    timestamp: System.monotonic_time()
                  })
              end
            end)
          end
        end)

      time_ms = div(time_ms, 1000)

      # Wait for all publishers to complete
      Process.sleep(2000)

      # Count received messages
      received_messages = collect_messages([], expected_total, 5000)

      Logger.info(
        [
          "📊 Concurrent publishers: #{publisher_count}",
          "📈 Messages per publisher: #{messages_per_publisher}",
          "📨 Expected total: #{expected_total}",
          "✅ Received: #{length(received_messages)}",
          "⏱️  Publish time: #{time_ms}ms",
          "🚀 Combined throughput: #{Float.round(expected_total / (time_ms / 1000), 2)} msg/s"
        ]
        |> Enum.join(" | ")
      )

      # Should receive most messages (allowing for some timing issues)
      assert length(received_messages) >= expected_total * 0.95,
             "Too many messages lost: #{expected_total - length(received_messages)} missing"
    end

    test "multiple topics with concurrent activity" do
      topic_count = 5
      subscribers_per_topic = 20
      messages_per_topic = 100

      topics =
        for i <- 1..topic_count do
          BenchmarkHelpers.benchmark_topic("multi_topic_#{i}")
        end

      on_exit(fn ->
        Enum.each(topics, &BenchmarkHelpers.cleanup_benchmark_topic/1)
      end)

      Logger.info(
        "Starting multi-topic stress test: #{topic_count} topics, #{subscribers_per_topic} subscribers each"
      )

      assert {:ok, memory_results} =
               BenchmarkHelpers.measure_memory_usage(fn ->
                 # Start all topics and subscribers
                 for topic <- topics do
                   {:ok, _} = Ratatoskr.create_topic(topic)

                   # Spawn subscribers for this topic
                   for _i <- 1..subscribers_per_topic do
                     spawn_link(fn ->
                       {:ok, _ref} = Ratatoskr.subscribe(topic)
                       # Receive messages
                       receive_messages_for_topic(topic, messages_per_topic)
                     end)
                   end
                 end

                 # Wait for subscriptions to register
                 Process.sleep(200)

                 # Concurrently publish to all topics
                 for topic <- topics do
                   spawn_link(fn ->
                     for i <- 1..messages_per_topic do
                       {:ok, _} = Ratatoskr.publish(topic, %{topic: topic, message: i})
                     end
                   end)
                 end

                 # Wait for completion
                 Process.sleep(3000)

                 # Return topic statistics
                 for topic <- topics do
                   {:ok, stats} = Ratatoskr.stats(topic)
                   stats
                 end
               end)

      topic_stats = memory_results.result

      Logger.info(
        [
          "📊 Multi-topic test completed",
          "📈 Topics: #{topic_count}",
          "👥 Total subscribers: #{topic_count * subscribers_per_topic}",
          "📨 Total messages: #{topic_count * messages_per_topic}",
          "🧠 Memory used: #{Float.round(memory_results.memory_used_mb, 2)} MB",
          "⚙️  Process count: +#{memory_results.process_count_diff}"
        ]
        |> Enum.join(" | ")
      )

      # Validate that all topics are functioning
      Enum.each(topic_stats, fn stats ->
        assert stats.message_count > 0, "Topic #{stats.topic} has no messages"
      end)

      # Memory usage should be reasonable for the load
      assert memory_results.memory_used_mb < 100.0,
             "Memory usage too high for multi-topic test: #{Float.round(memory_results.memory_used_mb, 2)} MB"
    end
  end

  describe "Resource Management" do
    test "handles subscriber churn (connects/disconnects)" do
      topic_name = BenchmarkHelpers.benchmark_topic("churn_test")

      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)

      Logger.info("Starting subscriber churn test")

      {:ok, _topic} = Ratatoskr.create_topic(topic_name)

      # Simulate subscriber churn over time
      churn_cycles = 10
      subscribers_per_cycle = 20

      for cycle <- 1..churn_cycles do
        # Connect subscribers
        _subscribers =
          for _i <- 1..subscribers_per_cycle do
            spawn_link(fn ->
              {:ok, ref} = Ratatoskr.subscribe(topic_name)

              # Stay subscribed for a short time
              Process.sleep(100 + :rand.uniform(100))

              # Unsubscribe
              Ratatoskr.unsubscribe(topic_name, ref)
            end)
          end

        # Send some messages during this cycle
        for i <- 1..5 do
          {:ok, _} = Ratatoskr.publish(topic_name, %{cycle: cycle, message: i})
        end

        # Wait for this cycle to complete
        Process.sleep(300)

        # Check topic stats
        {:ok, stats} = Ratatoskr.stats(topic_name)

        Logger.debug("Cycle #{cycle}: #{stats.subscriber_count} active subscribers")
      end

      # Final state should be stable
      {:ok, final_stats} = Ratatoskr.stats(topic_name)

      Logger.info(
        [
          "✅ Churn test completed",
          "🔄 Cycles: #{churn_cycles}",
          "👥 Subscribers per cycle: #{subscribers_per_cycle}",
          "📊 Final subscriber count: #{final_stats.subscriber_count}",
          "📨 Total messages: #{final_stats.message_count}"
        ]
        |> Enum.join(" | ")
      )

      # Topic should still be functional
      assert {:ok, _} = Ratatoskr.publish(topic_name, %{final: "message"})
    end
  end

  # Helper Functions

  defp collect_messages(messages, 0, _timeout), do: messages

  defp collect_messages(messages, remaining, timeout) do
    receive do
      {:message, message} ->
        collect_messages([message | messages], remaining - 1, timeout)
    after
      timeout ->
        # Return what we collected
        messages
    end
  end

  defp receive_messages_for_topic(_topic, 0), do: :done

  defp receive_messages_for_topic(topic, remaining) do
    receive do
      {:message, _message} ->
        receive_messages_for_topic(topic, remaining - 1)
    after
      5000 ->
        Logger.warning("Timeout waiting for message on #{topic}")
        :timeout
    end
  end
end
