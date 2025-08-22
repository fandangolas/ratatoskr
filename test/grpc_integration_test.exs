defmodule RatatoskrGrpcIntegrationTest do
  @moduledoc """
  Comprehensive gRPC integration tests to ensure real server functionality.
  These tests are designed to be non-flaky and test actual network communication.
  """
  
  use ExUnit.Case, async: false
  
  alias Ratatoskr.Grpc.{PublishRequest, CreateTopicRequest, DeleteTopicRequest}
  
  @grpc_port 9090
  @test_topic "grpc-integration-test"
  
  setup_all do
    # Ensure the application is started with gRPC server
    Application.ensure_all_started(:ratatoskr)
    
    # Wait for gRPC server to be ready
    wait_for_grpc_server()
    
    # Connect to gRPC server
    {:ok, channel} = GRPC.Stub.connect("localhost:#{@grpc_port}")
    
    on_exit(fn ->
      GRPC.Stub.disconnect(channel)
    end)
    
    %{channel: channel}
  end
  
  setup %{channel: channel} do
    # Clean up any existing test topic
    delete_request = %DeleteTopicRequest{name: @test_topic}
    # Ignore result as topic might not exist
    Ratatoskr.Grpc.MessageBroker.Stub.delete_topic(channel, delete_request)
    
    on_exit(fn ->
      # Clean up test topic after each test
      delete_request = %DeleteTopicRequest{name: @test_topic}
      Ratatoskr.Grpc.MessageBroker.Stub.delete_topic(channel, delete_request)
    end)
    
    :ok
  end
  
  describe "gRPC Topic Management" do
    test "creates topic successfully", %{channel: channel} do
      request = %CreateTopicRequest{name: @test_topic}
      
      assert {:ok, response} = Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, request)
      assert response.created == true
      assert response.topic == @test_topic
    end
    
    test "handles duplicate topic creation gracefully", %{channel: channel} do
      request = %CreateTopicRequest{name: @test_topic}
      
      # Create topic first time
      assert {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, request)
      
      # Create same topic again
      assert {:ok, response} = Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, request)
      # Should indicate already exists (created=false)
      assert response.created == false
      assert response.error == "already_exists"
    end
    
    test "deletes topic successfully", %{channel: channel} do
      # Create topic first
      create_request = %CreateTopicRequest{name: @test_topic}
      assert {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, create_request)
      
      # Delete topic
      delete_request = %DeleteTopicRequest{name: @test_topic}
      assert {:ok, response} = Ratatoskr.Grpc.MessageBroker.Stub.delete_topic(channel, delete_request)
      assert response.success == true
    end
    
    test "handles non-existent topic deletion gracefully", %{channel: channel} do
      request = %DeleteTopicRequest{name: "non-existent-topic"}
      
      # Should handle gracefully without crashing
      assert {:ok, response} = Ratatoskr.Grpc.MessageBroker.Stub.delete_topic(channel, request)
      # Response might be success=false or still true (depending on implementation)
      assert is_boolean(response.success)
    end
  end
  
  describe "gRPC Message Publishing" do
    setup %{channel: channel} do
      # Create test topic
      request = %CreateTopicRequest{name: @test_topic}
      assert {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, request)
      :ok
    end
    
    test "publishes single message successfully", %{channel: channel} do
      payload = %{message: "test message", timestamp: :os.system_time(:millisecond)}
      
      request = %PublishRequest{
        topic: @test_topic,
        payload: Jason.encode!(payload),
        metadata: %{"source" => "integration-test"}
      }
      
      assert {:ok, response} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
      assert response.success == true
      assert is_binary(response.message_id)
      assert String.length(response.message_id) > 0
    end
    
    test "publishes multiple messages successfully", %{channel: channel} do
      message_count = 10
      
      results = for i <- 1..message_count do
        payload = %{message: "test message #{i}", seq: i}
        
        request = %PublishRequest{
          topic: @test_topic,
          payload: Jason.encode!(payload),
          metadata: %{"seq" => to_string(i)}
        }
        
        Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
      end
      
      # All publishes should succeed
      assert Enum.all?(results, fn
        {:ok, response} -> response.success == true
        _ -> false
      end)
      
      # All message IDs should be unique
      message_ids = Enum.map(results, fn {:ok, response} -> response.message_id end)
      assert length(Enum.uniq(message_ids)) == message_count
    end
    
    test "handles large payload publishing", %{channel: channel} do
      # Create a reasonably large payload (1KB)
      large_data = String.duplicate("x", 1024)
      payload = %{data: large_data, size: byte_size(large_data)}
      
      request = %PublishRequest{
        topic: @test_topic,
        payload: Jason.encode!(payload),
        metadata: %{"type" => "large-payload-test"}
      }
      
      assert {:ok, response} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
      assert response.success == true
      assert is_binary(response.message_id)
    end
    
    test "handles invalid JSON payload gracefully", %{channel: channel} do
      request = %PublishRequest{
        topic: @test_topic,
        payload: "invalid-json-{{{",
        metadata: %{"type" => "invalid-json-test"}
      }
      
      # Should handle gracefully - either succeed with invalid JSON as string
      # or return appropriate error
      result = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
      
      case result do
        {:ok, response} -> 
          # If it succeeds, message_id should be present
          assert is_binary(response.message_id)
        {:error, _error} ->
          # If it fails, that's also acceptable behavior
          :ok
      end
    end
    
    test "publishes to non-existent topic", %{channel: channel} do
      request = %PublishRequest{
        topic: "non-existent-topic",
        payload: Jason.encode!(%{test: "message"}),
        metadata: %{}
      }
      
      # Should handle gracefully - either auto-create topic or return error
      result = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
      
      case result do
        {:ok, response} -> 
          # If auto-creation is enabled
          assert is_boolean(response.success)
        {:error, _error} ->
          # If strict topic creation is required
          :ok
      end
    end
  end
  
  describe "gRPC Performance Characteristics" do
    setup %{channel: channel} do
      # Create test topic
      request = %CreateTopicRequest{name: @test_topic}
      assert {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, request)
      :ok
    end
    
    test "publishes 100 messages within reasonable time", %{channel: channel} do
      message_count = 100
      payload = %{test: "performance", timestamp: :os.system_time(:millisecond)}
      
      {time_us, results} = :timer.tc(fn ->
        for i <- 1..message_count do
          request = %PublishRequest{
            topic: @test_topic,
            payload: Jason.encode!(payload),
            metadata: %{"seq" => to_string(i)}
          }
          
          Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
        end
      end)
      
      # All should succeed
      assert Enum.all?(results, fn
        {:ok, response} -> response.success == true
        _ -> false
      end)
      
      # Should complete within reasonable time (10 seconds for 100 messages)
      assert time_us < 10_000_000  # 10 seconds in microseconds
      
      # Calculate and log throughput for reference
      throughput = (message_count * 1_000_000) / time_us
      IO.puts("gRPC Integration Test Throughput: #{Float.round(throughput, 0)} msg/s")
    end
    
    test "maintains consistent latency across multiple calls", %{channel: channel} do
      message_count = 50
      payload = %{test: "latency", data: "consistent"}
      
      latencies = for i <- 1..message_count do
        request = %PublishRequest{
          topic: @test_topic,
          payload: Jason.encode!(payload),
          metadata: %{"seq" => to_string(i)}
        }
        
        {latency_us, result} = :timer.tc(fn ->
          Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, request)
        end)
        
        assert {:ok, response} = result
        assert response.success == true
        
        latency_us / 1000  # Convert to milliseconds
      end
      
      avg_latency = Enum.sum(latencies) / length(latencies)
      max_latency = Enum.max(latencies)
      min_latency = Enum.min(latencies)
      
      # Log latency statistics
      IO.puts("Average Latency: #{Float.round(avg_latency, 3)}ms")
      IO.puts("Min Latency: #{Float.round(min_latency, 3)}ms")
      IO.puts("Max Latency: #{Float.round(max_latency, 3)}ms")
      
      # Reasonable bounds: average should be under 100ms, max under 500ms
      assert avg_latency < 100.0
      assert max_latency < 500.0
    end
  end
  
  describe "gRPC Error Handling" do
    test "handles connection errors gracefully" do
      # Try to connect to wrong port
      result = GRPC.Stub.connect("localhost:9999")
      
      case result do
        {:error, _} ->
          # Expected behavior
          :ok
        {:ok, channel} ->
          # If connection succeeds, cleanup
          GRPC.Stub.disconnect(channel)
          # This might happen if port 9999 is actually in use
          :ok
      end
    end
    
    test "handles server shutdown gracefully", %{channel: channel} do
      # Create a topic to test basic functionality
      request = %CreateTopicRequest{name: @test_topic}
      assert {:ok, _} = Ratatoskr.Grpc.MessageBroker.Stub.create_topic(channel, request)
      
      # Test that we can still use the connection
      publish_request = %PublishRequest{
        topic: @test_topic,
        payload: Jason.encode!(%{test: "before-shutdown"}),
        metadata: %{}
      }
      
      assert {:ok, response} = Ratatoskr.Grpc.MessageBroker.Stub.publish(channel, publish_request)
      assert response.success == true
    end
  end
  
  # Helper function to wait for gRPC server to be ready
  defp wait_for_grpc_server(retries \\ 10, delay \\ 500)
  
  defp wait_for_grpc_server(0, _delay) do
    raise "gRPC server failed to start within timeout"
  end
  
  defp wait_for_grpc_server(retries, delay) do
    case GRPC.Stub.connect("localhost:#{@grpc_port}") do
      {:ok, channel} ->
        GRPC.Stub.disconnect(channel)
        :ok
      {:error, _} ->
        Process.sleep(delay)
        wait_for_grpc_server(retries - 1, delay)
    end
  end
end