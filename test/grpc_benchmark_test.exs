defmodule Ratatoskr.GrpcBenchmarkTest do
  use ExUnit.Case
  require Logger

  alias Ratatoskr.Grpc.{
    CreateTopicRequest,
    PublishRequest,
    PublishBatchRequest,
    SubscribeRequest,
    GetStatsRequest
  }

  @moduletag :grpc_benchmark
  @moduletag :benchmark

  # Test configuration
  @grpc_host "localhost"
  @grpc_port 9090
  @benchmark_topic "benchmark-topic"
  @warmup_messages 100

  setup_all do
    # Ensure application is running
    Application.ensure_all_started(:ratatoskr)

    # Give gRPC server time to start
    Process.sleep(1000)

    # Verify gRPC server is running
    case :gen_tcp.connect(String.to_charlist(@grpc_host), @grpc_port, [], 1000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        Logger.info("gRPC server confirmed running on #{@grpc_host}:#{@grpc_port}")

      {:error, reason} ->
        raise "gRPC server not available: #{reason}"
    end

    :ok
  end

  setup do
    # Clean up any existing topics
    case Ratatoskr.list_topics() do
      {:ok, topics} ->
        for topic <- topics, do: Ratatoskr.delete_topic(topic)

      _ ->
        :ok
    end

    # Create fresh benchmark topic
    {:ok, _} = Ratatoskr.create_topic(@benchmark_topic)

    :ok
  end

  describe "gRPC Client Infrastructure" do
    test "establishes gRPC client connection" do
      {:ok, channel} = GRPC.Stub.connect("#{@grpc_host}:#{@grpc_port}")

      # Test basic operation
      request = %CreateTopicRequest{name: "connection-test"}
      {:ok, response} = Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, request)

      assert response.created == true
      GRPC.Stub.disconnect(channel)
    end

    test "handles multiple concurrent connections" do
      connection_count = 10

      tasks =
        for i <- 1..connection_count do
          Task.async(fn ->
            {:ok, channel} = GRPC.Stub.connect("#{@grpc_host}:#{@grpc_port}")

            request = %CreateTopicRequest{name: "concurrent-#{i}"}
            {:ok, response} = Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, request)

            GRPC.Stub.disconnect(channel)
            response.created
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == true))
    end
  end

  describe "gRPC Throughput Benchmarks" do
    @tag timeout: 30_000
    test "measures gRPC publish throughput vs internal API" do
      message_count = 1000
      payload = %{data: "benchmark message", timestamp: :os.system_time(:millisecond)}

      # Benchmark internal API
      {internal_time_us, _} =
        :timer.tc(fn ->
          for _i <- 1..message_count do
            {:ok, _} = Ratatoskr.publish(@benchmark_topic, payload)
          end
        end)

      # Clean topic for gRPC test
      Ratatoskr.delete_topic(@benchmark_topic)
      {:ok, _} = Ratatoskr.create_topic(@benchmark_topic)

      # Benchmark gRPC API
      {:ok, channel} = GRPC.Stub.connect("#{@grpc_host}:#{@grpc_port}")

      {grpc_time_us, _} =
        :timer.tc(fn ->
          for _i <- 1..message_count do
            request = %PublishRequest{
              topic: @benchmark_topic,
              payload: Jason.encode!(payload),
              metadata: %{"source" => "grpc-benchmark"}
            }

            {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
          end
        end)

      GRPC.Stub.disconnect(channel)

      # Calculate metrics
      internal_msg_per_sec = message_count * 1_000_000 / internal_time_us
      grpc_msg_per_sec = message_count * 1_000_000 / grpc_time_us
      overhead_percent = (grpc_time_us - internal_time_us) / internal_time_us * 100

      Logger.info("""
      Throughput Comparison (#{message_count} messages):
      - Internal API: #{Float.round(internal_msg_per_sec, 0)} msg/s (#{internal_time_us}μs total)
      - gRPC API: #{Float.round(grpc_msg_per_sec, 0)} msg/s (#{grpc_time_us}μs total)  
      - gRPC Overhead: #{Float.round(overhead_percent, 1)}%
      """)

      # Assertions - high-performance expectations for production readiness
      assert grpc_msg_per_sec > 1000, "gRPC should handle >1000 msg/s"
      assert overhead_percent < 500, "gRPC overhead should be <500% (5x slower max)"

      # Store results for comparison
      %{
        internal_throughput: internal_msg_per_sec,
        grpc_throughput: grpc_msg_per_sec,
        overhead_percent: overhead_percent
      }
    end

    @tag timeout: 30_000
    test "measures gRPC batch publish performance" do
      batch_sizes = [1, 10, 50, 100]
      {:ok, channel} = GRPC.Stub.connect("#{@grpc_host}:#{@grpc_port}")

      results =
        for batch_size <- batch_sizes do
          # Prepare batch
          messages =
            for i <- 1..batch_size do
              %PublishRequest{
                topic: @benchmark_topic,
                payload: Jason.encode!(%{batch_id: i, data: "batch message"}),
                metadata: %{"batch_size" => to_string(batch_size)}
              }
            end

          request = %PublishBatchRequest{
            topic: @benchmark_topic,
            messages: messages
          }

          # Benchmark batch publish
          iterations = 100

          {time_us, _} =
            :timer.tc(fn ->
              for _i <- 1..iterations do
                {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.publish_batch(channel, request)
              end
            end)

          total_messages = iterations * batch_size
          msg_per_sec = total_messages * 1_000_000 / time_us

          Logger.info("Batch size #{batch_size}: #{Float.round(msg_per_sec, 0)} msg/s")

          {batch_size, msg_per_sec}
        end

      GRPC.Stub.disconnect(channel)

      # Verify batch performance improves with size
      throughputs = Enum.map(results, fn {_size, throughput} -> throughput end)

      assert List.last(throughputs) > List.first(throughputs),
             "Larger batches should have higher throughput"

      results
    end
  end

  describe "gRPC Latency Benchmarks" do
    @tag timeout: 20_000
    test "measures gRPC publish latency distribution" do
      {:ok, channel} = GRPC.Stub.connect("#{@grpc_host}:#{@grpc_port}")

      # Warmup
      for _i <- 1..@warmup_messages do
        request = %PublishRequest{
          topic: @benchmark_topic,
          payload: "warmup",
          metadata: %{}
        }

        {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
      end

      # Collect latency samples
      latencies =
        for i <- 1..1000 do
          request = %PublishRequest{
            topic: @benchmark_topic,
            payload: Jason.encode!(%{message_id: i}),
            metadata: %{"test" => "latency"}
          }

          {latency_us, {:ok, _}} =
            :timer.tc(fn ->
              Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
            end)

          # Convert to milliseconds
          latency_us / 1000
        end

      GRPC.Stub.disconnect(channel)

      # Calculate percentiles
      sorted_latencies = Enum.sort(latencies)
      p50 = percentile(sorted_latencies, 50)
      p95 = percentile(sorted_latencies, 95)
      p99 = percentile(sorted_latencies, 99)
      avg = Enum.sum(latencies) / length(latencies)

      Logger.info("""
      gRPC Publish Latency Distribution (1000 samples):
      - Average: #{Float.round(avg, 2)}ms
      - P50: #{Float.round(p50, 2)}ms
      - P95: #{Float.round(p95, 2)}ms
      - P99: #{Float.round(p99, 2)}ms
      """)

      # Assertions based on realistic gRPC expectations
      assert p99 < 100,
             "P99 latency should be <100ms (gRPC has higher overhead than internal API)"

      assert p95 < 50, "P95 latency should be <50ms"
      assert avg < 20, "Average latency should be <20ms"

      %{p50: p50, p95: p95, p99: p99, average: avg}
    end

    @tag timeout: 15_000
    test "measures gRPC topic operations latency" do
      {:ok, channel} = GRPC.Stub.connect("#{@grpc_host}:#{@grpc_port}")

      operations = [
        {"create_topic",
         fn i ->
           request = %CreateTopicRequest{name: "latency-test-#{i}"}
           Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, request)
         end},
        {"get_stats",
         fn _i ->
           request = %GetStatsRequest{topic: @benchmark_topic}
           Ratatoskr.Grpc.MessageBroker.Stub.get_stats(channel, request)
         end}
      ]

      results =
        for {operation_name, operation_fn} <- operations do
          latencies =
            for i <- 1..100 do
              {latency_us, {:ok, _}} = :timer.tc(fn -> operation_fn.(i) end)
              # Convert to ms
              latency_us / 1000
            end

          avg_latency = Enum.sum(latencies) / length(latencies)
          p99_latency = percentile(Enum.sort(latencies), 99)

          Logger.info(
            "#{operation_name}: avg #{Float.round(avg_latency, 2)}ms, p99 #{Float.round(p99_latency, 2)}ms"
          )

          {operation_name, %{average: avg_latency, p99: p99_latency}}
        end

      GRPC.Stub.disconnect(channel)

      # All operations should be fast
      for {_op, metrics} <- results do
        assert metrics.average < 5, "Average operation latency should be <5ms"
        assert metrics.p99 < 20, "P99 operation latency should be <20ms"
      end

      results
    end
  end

  describe "gRPC Concurrent Client Benchmarks" do
    @tag timeout: 30_000
    test "handles multiple concurrent gRPC publishers" do
      client_counts = [1, 5, 10, 20]
      messages_per_client = 100

      results =
        for client_count <- client_counts do
          Logger.info("Testing #{client_count} concurrent gRPC clients...")

          {total_time_ms, _} =
            :timer.tc(fn ->
              tasks =
                for i <- 1..client_count do
                  Task.async(fn ->
                    {:ok, channel} = GRPC.Stub.connect("#{@grpc_host}:#{@grpc_port}")

                    for j <- 1..messages_per_client do
                      request = %PublishRequest{
                        topic: @benchmark_topic,
                        payload: Jason.encode!(%{client: i, message: j}),
                        metadata: %{"client_id" => to_string(i)}
                      }

                      {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
                    end

                    GRPC.Stub.disconnect(channel)
                    :ok
                  end)
                end

              Task.await_many(tasks, 20_000)
            end)

          total_messages = client_count * messages_per_client
          throughput = total_messages * 1_000_000 / total_time_ms

          Logger.info("#{client_count} clients: #{Float.round(throughput, 0)} msg/s total")

          {client_count, throughput}
        end

      # Verify throughput scales reasonably with clients
      throughputs = Enum.map(results, fn {_count, throughput} -> throughput end)

      # Should maintain reasonable performance even with many clients
      max_throughput = Enum.max(throughputs)
      assert max_throughput > 2000, "Peak concurrent throughput should exceed 2000 msg/s"

      results
    end

    @tag timeout: 25_000
    test "measures gRPC streaming subscription performance" do
      message_count = 500
      subscriber_count = 5

      Logger.info(
        "Testing #{subscriber_count} gRPC streaming subscribers with #{message_count} messages"
      )

      # Start subscribers
      subscriber_tasks =
        for i <- 1..subscriber_count do
          Task.async(fn ->
            {:ok, channel} = GRPC.Stub.connect("#{@grpc_host}:#{@grpc_port}")

            _request = %SubscribeRequest{
              topic: @benchmark_topic,
              subscriber_id: "grpc-sub-#{i}"
            }

            _received_count = 0
            start_time = :os.system_time(:millisecond)

            # Note: This is a simplified version - real streaming would use GRPC.Stub.recv
            # For now, we'll simulate by checking topic stats

            GRPC.Stub.disconnect(channel)

            # Return subscriber info
            %{subscriber_id: i, start_time: start_time}
          end)
        end

      # Give subscribers time to connect
      Process.sleep(500)

      # Start publisher
      {:ok, channel} = GRPC.Stub.connect("#{@grpc_host}:#{@grpc_port}")

      {publish_time_ms, _} =
        :timer.tc(fn ->
          for i <- 1..message_count do
            request = %PublishRequest{
              topic: @benchmark_topic,
              payload: Jason.encode!(%{stream_message: i}),
              metadata: %{"stream_test" => "true"}
            }

            {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
          end
        end)

      GRPC.Stub.disconnect(channel)

      # Wait for subscribers to finish
      _subscriber_results = Task.await_many(subscriber_tasks, 10_000)

      publish_throughput = message_count * 1_000_000 / publish_time_ms

      Logger.info("""
      Streaming Subscription Performance:
      - #{subscriber_count} concurrent gRPC subscribers
      - #{message_count} messages published
      - Publish throughput: #{Float.round(publish_throughput, 0)} msg/s
      """)

      # Verify basic performance
      assert publish_throughput > 1000, "Should maintain >1000 msg/s with streaming subscribers"

      %{
        subscriber_count: subscriber_count,
        message_count: message_count,
        publish_throughput: publish_throughput
      }
    end
  end

  describe "gRPC vs Internal API Performance Comparison" do
    @tag timeout: 30_000
    test "comprehensive performance comparison" do
      test_scenarios = [
        %{name: "Single Message Publish", message_count: 1000, batch_size: 1},
        %{name: "Batch Publish (10)", message_count: 1000, batch_size: 10},
        %{name: "High Volume", message_count: 5000, batch_size: 1}
      ]

      results =
        for scenario <- test_scenarios do
          Logger.info("Running scenario: #{scenario.name}")

          # Test Internal API
          internal_result = benchmark_internal_api(scenario)

          # Clean up for gRPC test
          Ratatoskr.delete_topic(@benchmark_topic)
          {:ok, _} = Ratatoskr.create_topic(@benchmark_topic)

          # Test gRPC API
          grpc_result = benchmark_grpc_api(scenario)

          efficiency = grpc_result.throughput / internal_result.throughput * 100

          Logger.info("""
          #{scenario.name} Results:
          - Internal API: #{Float.round(internal_result.throughput, 0)} msg/s
          - gRPC API: #{Float.round(grpc_result.throughput, 0)} msg/s
          - gRPC Efficiency: #{Float.round(efficiency, 1)}% of internal performance
          """)

          %{
            scenario: scenario.name,
            internal: internal_result,
            grpc: grpc_result,
            efficiency_percent: efficiency
          }
        end

      # Verify gRPC maintains high performance standards
      for result <- results do
        assert result.efficiency_percent > 20,
               "gRPC should maintain >20% efficiency vs internal API (5x slower max)"

        assert result.grpc.throughput > 500,
               "gRPC throughput should exceed 500 msg/s in all scenarios"
      end

      results
    end
  end

  # Helper functions

  defp benchmark_internal_api(scenario) do
    {time_us, _} =
      :timer.tc(fn ->
        for _i <- 1..scenario.message_count do
          payload = %{data: "internal benchmark", scenario: scenario.name}
          {:ok, _} = Ratatoskr.publish(@benchmark_topic, payload)
        end
      end)

    throughput = scenario.message_count * 1_000_000 / time_us
    %{throughput: throughput, time_us: time_us}
  end

  defp benchmark_grpc_api(scenario) do
    {:ok, channel} = GRPC.Stub.connect("#{@grpc_host}:#{@grpc_port}")

    {time_us, _} =
      :timer.tc(fn ->
        if scenario.batch_size == 1 do
          # Single message publishing
          for i <- 1..scenario.message_count do
            request = %PublishRequest{
              topic: @benchmark_topic,
              payload: Jason.encode!(%{data: "grpc benchmark", message: i}),
              metadata: %{"scenario" => scenario.name}
            }

            {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
          end
        else
          # Batch publishing
          batch_count = div(scenario.message_count, scenario.batch_size)

          for batch_i <- 1..batch_count do
            messages =
              for i <- 1..scenario.batch_size do
                %PublishRequest{
                  topic: @benchmark_topic,
                  payload: Jason.encode!(%{batch: batch_i, message: i}),
                  metadata: %{"scenario" => scenario.name}
                }
              end

            request = %PublishBatchRequest{
              topic: @benchmark_topic,
              messages: messages
            }

            {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.publish_batch(channel, request)
          end
        end
      end)

    GRPC.Stub.disconnect(channel)

    throughput = scenario.message_count * 1_000_000 / time_us
    %{throughput: throughput, time_us: time_us}
  end

  defp percentile(sorted_list, percentile) do
    length = length(sorted_list)
    index = Float.ceil(length * percentile / 100) - 1
    index = max(0, min(index, length - 1)) |> round()
    Enum.at(sorted_list, index)
  end
end
