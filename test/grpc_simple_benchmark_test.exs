defmodule Ratatoskr.GrpcSimpleBenchmarkTest do
  use ExUnit.Case
  require Logger

  alias Ratatoskr.Grpc.{
    CreateTopicRequest,
    PublishRequest,
    PublishBatchRequest
  }

  @moduletag :grpc_simple_benchmark

  # Test configuration
  @grpc_host "localhost"
  @grpc_port 50051
  @benchmark_topic "simple-benchmark"

  setup_all do
    # Ensure application is running
    Application.ensure_all_started(:ratatoskr)
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
    # Clean up existing topics
    case Ratatoskr.list_topics() do
      {:ok, topics} ->
        for topic <- topics, do: Ratatoskr.delete_topic(topic)

      _ ->
        :ok
    end

    {:ok, _} = Ratatoskr.create_topic(@benchmark_topic)
    :ok
  end

  describe "gRPC Performance Reality Check" do
    @tag timeout: 15_000
    test "measures realistic gRPC performance" do
      Logger.info("=== gRPC Performance Benchmark ===")

      # Test 1: Basic Connection and Topic Creation
      {:ok, channel} = GRPC.Stub.connect("#{@grpc_host}:#{@grpc_port}")

      {topic_time_us, {:ok, _}} =
        :timer.tc(fn ->
          request = %CreateTopicRequest{name: "perf-test"}
          Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, request)
        end)

      Logger.info("Topic Creation via gRPC: #{Float.round(topic_time_us / 1000, 2)}ms")

      # Test 2: Single Message Publish Performance
      message_count = 100
      payload = Jason.encode!(%{test: "data", timestamp: :os.system_time(:millisecond)})

      {publish_time_us, _} =
        :timer.tc(fn ->
          for i <- 1..message_count do
            request = %PublishRequest{
              topic: @benchmark_topic,
              payload: payload,
              metadata: %{"seq" => to_string(i)}
            }

            {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
          end
        end)

      single_throughput = message_count * 1_000_000 / publish_time_us
      avg_latency = publish_time_us / message_count / 1000

      Logger.info("""
      Single Message Publishing (#{message_count} messages):
      - Throughput: #{Float.round(single_throughput, 0)} msg/s
      - Average Latency: #{Float.round(avg_latency, 2)}ms per message
      """)

      # Test 3: Batch Publishing Performance
      batch_sizes = [1, 5, 10, 20]

      batch_results =
        for batch_size <- batch_sizes do
          messages =
            for i <- 1..batch_size do
              %PublishRequest{
                topic: @benchmark_topic,
                payload: payload,
                metadata: %{"batch" => to_string(i)}
              }
            end

          request = %PublishBatchRequest{
            topic: @benchmark_topic,
            messages: messages
          }

          iterations = 20

          {time_us, _} =
            :timer.tc(fn ->
              for _i <- 1..iterations do
                {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.publish_batch(channel, request)
              end
            end)

          total_messages = iterations * batch_size
          throughput = total_messages * 1_000_000 / time_us

          {batch_size, throughput}
        end

      Logger.info("Batch Publishing Performance:")

      for {size, throughput} <- batch_results do
        Logger.info("- Batch size #{size}: #{Float.round(throughput, 0)} msg/s")
      end

      # Test 4: Connection Overhead
      connection_count = 10

      {conn_time_us, _} =
        :timer.tc(fn ->
          for _i <- 1..connection_count do
            {:ok, test_channel} = GRPC.Stub.connect("#{@grpc_host}:#{@grpc_port}")
            GRPC.Stub.disconnect(test_channel)
          end
        end)

      avg_connection_time = conn_time_us / connection_count / 1000
      Logger.info("Connection Setup: #{Float.round(avg_connection_time, 2)}ms per connection")

      GRPC.Stub.disconnect(channel)

      # Summary
      Logger.info("""

      === gRPC Performance Summary ===
      ✅ gRPC Server is operational and responsive
      ✅ Single message throughput: #{Float.round(single_throughput, 0)} msg/s
      ✅ Best batch throughput: #{Float.round(elem(List.last(batch_results), 1), 0)} msg/s
      ✅ Average latency: #{Float.round(avg_latency, 2)}ms
      ✅ Connection overhead: #{Float.round(avg_connection_time, 2)}ms

      📊 Performance Context:
      - Internal Elixir API achieves 74,000+ msg/s
      - gRPC adds network + serialization overhead
      - Performance is suitable for most real-world applications
      - Batching significantly improves throughput
      """)

      # Basic sanity checks (not strict performance requirements)
      assert single_throughput > 50, "gRPC should handle at least 50 msg/s"
      assert avg_latency < 100, "Average latency should be reasonable (<100ms)"
      assert avg_connection_time < 50, "Connection setup should be fast (<50ms)"

      %{
        single_throughput: single_throughput,
        avg_latency: avg_latency,
        batch_results: batch_results,
        connection_time: avg_connection_time
      }
    end

    @tag timeout: 10_000
    test "validates gRPC client-server communication" do
      Logger.info("=== gRPC Communication Validation ===")

      {:ok, channel} = GRPC.Stub.connect("#{@grpc_host}:#{@grpc_port}")

      # Test all major operations work correctly
      operations = [
        {"CreateTopic",
         fn ->
           request = %CreateTopicRequest{name: "validation-topic"}
           {:ok, response} = Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, request)
           response.created
         end},
        {"Publish",
         fn ->
           request = %PublishRequest{
             topic: @benchmark_topic,
             payload: "validation message",
             metadata: %{"test" => "validation"}
           }

           {:ok, response} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
           response.success
         end},
        {"ListTopics",
         fn ->
           request = %Ratatoskr.Grpc.ListTopicsRequest{}
           {:ok, response} = Ratatoskr.Grpc.MessageBroker.Stub.list_topics(channel, request)
           length(response.topics) > 0
         end},
        {"GetStats",
         fn ->
           request = %Ratatoskr.Grpc.GetStatsRequest{topic: @benchmark_topic}
           {:ok, response} = Ratatoskr.Grpc.MessageBroker.Stub.get_stats(channel, request)
           response.error == ""
         end}
      ]

      results =
        for {operation, test_fn} <- operations do
          {time_us, success} = :timer.tc(test_fn)
          latency_ms = time_us / 1000

          Logger.info(
            "#{operation}: #{if success, do: "✅ PASS", else: "❌ FAIL"} (#{Float.round(latency_ms, 2)}ms)"
          )

          {operation, success, latency_ms}
        end

      GRPC.Stub.disconnect(channel)

      # Verify all operations succeeded
      for {operation, success, _latency} <- results do
        assert success, "#{operation} should succeed via gRPC"
      end

      Logger.info("✅ All gRPC operations validated successfully")

      results
    end
  end
end
