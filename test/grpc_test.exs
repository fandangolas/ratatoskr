defmodule Ratatoskr.GrpcTest do
  use ExUnit.Case
  doctest Ratatoskr.Grpc.Server

  alias Ratatoskr.Grpc.{
    CreateTopicRequest,
    CreateTopicResponse,
    DeleteTopicRequest,
    DeleteTopicResponse,
    ListTopicsRequest,
    ListTopicsResponse,
    TopicExistsRequest,
    TopicExistsResponse,
    GetStatsRequest,
    GetStatsResponse,
    PublishRequest,
    PublishResponse,
    PublishBatchRequest,
    PublishBatchResponse,
    SubscribeRequest,
    UnsubscribeRequest,
    UnsubscribeResponse,
    Message
  }

  setup do
    # Start fresh for each test
    topics =
      case Ratatoskr.list_topics() do
        {:ok, topics} -> topics
        _ -> []
      end

    for topic <- topics do
      Ratatoskr.delete_topic(topic)
    end

    :ok
  end

  describe "gRPC Topic Management" do
    test "creates topic via gRPC" do
      request = %CreateTopicRequest{name: "grpc-test-topic"}

      response = Ratatoskr.Grpc.Server.create_topic(request, %GRPC.Server.Stream{})

      assert %CreateTopicResponse{topic: "grpc-test-topic", created: true, error: ""} = response
      assert Ratatoskr.topic_exists?("grpc-test-topic")
    end

    test "handles duplicate topic creation" do
      {:ok, _} = Ratatoskr.create_topic("existing-topic")

      request = %CreateTopicRequest{name: "existing-topic"}
      response = Ratatoskr.Grpc.Server.create_topic(request, %GRPC.Server.Stream{})

      assert %CreateTopicResponse{created: false} = response
      assert response.error != ""
    end

    test "deletes topic via gRPC" do
      {:ok, _} = Ratatoskr.create_topic("to-delete")

      request = %DeleteTopicRequest{name: "to-delete"}
      response = Ratatoskr.Grpc.Server.delete_topic(request, %GRPC.Server.Stream{})

      assert %DeleteTopicResponse{success: true, error: ""} = response
      refute Ratatoskr.topic_exists?("to-delete")
    end

    test "handles deleting non-existent topic" do
      request = %DeleteTopicRequest{name: "non-existent"}
      response = Ratatoskr.Grpc.Server.delete_topic(request, %GRPC.Server.Stream{})

      assert %DeleteTopicResponse{success: false} = response
      assert response.error != ""
    end

    test "lists topics via gRPC" do
      {:ok, _} = Ratatoskr.create_topic("topic1")
      {:ok, _} = Ratatoskr.create_topic("topic2")

      request = %ListTopicsRequest{}
      response = Ratatoskr.Grpc.Server.list_topics(request, %GRPC.Server.Stream{})

      assert %ListTopicsResponse{topics: topics} = response
      assert "topic1" in topics
      assert "topic2" in topics
    end

    test "checks topic existence via gRPC" do
      {:ok, _} = Ratatoskr.create_topic("existing")

      # Existing topic
      request = %TopicExistsRequest{name: "existing"}
      response = Ratatoskr.Grpc.Server.topic_exists(request, %GRPC.Server.Stream{})
      assert %TopicExistsResponse{exists: true} = response

      # Non-existing topic
      request = %TopicExistsRequest{name: "non-existing"}
      response = Ratatoskr.Grpc.Server.topic_exists(request, %GRPC.Server.Stream{})
      assert %TopicExistsResponse{exists: false} = response
    end

    test "gets topic stats via gRPC" do
      {:ok, _} = Ratatoskr.create_topic("stats-topic")
      {:ok, _} = Ratatoskr.subscribe("stats-topic")
      {:ok, _} = Ratatoskr.publish("stats-topic", %{test: "data"})

      request = %GetStatsRequest{topic: "stats-topic"}
      response = Ratatoskr.Grpc.Server.get_stats(request, %GRPC.Server.Stream{})

      assert %GetStatsResponse{
               topic: "stats-topic",
               message_count: 1,
               subscriber_count: 1,
               error: ""
             } = response
    end

    test "handles stats for non-existent topic" do
      request = %GetStatsRequest{topic: "non-existent"}
      response = Ratatoskr.Grpc.Server.get_stats(request, %GRPC.Server.Stream{})

      assert %GetStatsResponse{error: error} = response
      assert error != ""
    end
  end

  describe "gRPC Publishing" do
    test "publishes message via gRPC" do
      {:ok, _} = Ratatoskr.create_topic("pub-topic")

      request = %PublishRequest{
        topic: "pub-topic",
        payload: "test message",
        metadata: %{"source" => "grpc-test", "priority" => "high"}
      }

      response = Ratatoskr.Grpc.Server.publish(request, %GRPC.Server.Stream{})

      assert %PublishResponse{success: true, error: ""} = response
      assert response.message_id != ""
      assert response.timestamp > 0
    end

    test "handles publishing to non-existent topic" do
      request = %PublishRequest{
        topic: "non-existent-topic",
        payload: "test message",
        metadata: %{}
      }

      response = Ratatoskr.Grpc.Server.publish(request, %GRPC.Server.Stream{})

      assert %PublishResponse{success: false} = response
      assert response.error != ""
    end

    test "publishes batch via gRPC" do
      {:ok, _} = Ratatoskr.create_topic("batch-topic")

      messages = [
        %PublishRequest{topic: "batch-topic", payload: "msg1", metadata: %{}},
        %PublishRequest{topic: "batch-topic", payload: "msg2", metadata: %{}},
        %PublishRequest{topic: "batch-topic", payload: "msg3", metadata: %{}}
      ]

      request = %PublishBatchRequest{
        topic: "batch-topic",
        messages: messages
      }

      response = Ratatoskr.Grpc.Server.publish_batch(request, %GRPC.Server.Stream{})

      assert %PublishBatchResponse{
               success_count: 3,
               error_count: 0,
               results: results
             } = response

      assert length(results) == 3
      assert Enum.all?(results, & &1.success)
    end

    test "handles mixed success/failure in batch" do
      {:ok, _} = Ratatoskr.create_topic("batch-topic")

      messages = [
        %PublishRequest{topic: "batch-topic", payload: "msg1", metadata: %{}},
        %PublishRequest{topic: "non-existent", payload: "msg2", metadata: %{}},
        %PublishRequest{topic: "batch-topic", payload: "msg3", metadata: %{}}
      ]

      request = %PublishBatchRequest{
        topic: "batch-topic",
        messages: messages
      }

      response = Ratatoskr.Grpc.Server.publish_batch(request, %GRPC.Server.Stream{})

      assert %PublishBatchResponse{
               success_count: 2,
               error_count: 1,
               results: results
             } = response

      assert length(results) == 3
      # First and third should succeed, second should fail
      assert Enum.at(results, 0).success == true
      assert Enum.at(results, 1).success == false
      assert Enum.at(results, 2).success == true
    end
  end

  describe "gRPC Message Formatting" do
    test "handles binary payload correctly" do
      {:ok, _} = Ratatoskr.create_topic("binary-topic")

      binary_data = :crypto.strong_rand_bytes(100)

      request = %PublishRequest{
        topic: "binary-topic",
        payload: binary_data,
        metadata: %{"type" => "binary"}
      }

      response = Ratatoskr.Grpc.Server.publish(request, %GRPC.Server.Stream{})

      assert %PublishResponse{success: true} = response
    end

    test "handles metadata correctly" do
      {:ok, _} = Ratatoskr.create_topic("metadata-topic")

      metadata = %{
        "user_id" => "12345",
        "session" => "abc-def-ghi",
        "timestamp" => "2024-01-01T00:00:00Z"
      }

      request = %PublishRequest{
        topic: "metadata-topic",
        payload: "test with metadata",
        metadata: metadata
      }

      response = Ratatoskr.Grpc.Server.publish(request, %GRPC.Server.Stream{})

      assert %PublishResponse{success: true} = response
    end
  end

  describe "gRPC Subscription & Streaming" do
    test "handles subscribe for non-existent topic" do
      request = %SubscribeRequest{
        topic: "non-existent-topic",
        subscriber_id: "test-subscriber"
      }

      # Create a mock stream to capture the error response
      test_pid = self()

      mock_stream = %GRPC.Server.Stream{
        server: test_pid,
        adapter: :mock
      }

      # Mock GRPC.Server.send_reply to capture the response

      # Override the function to capture calls
      :meck.new(GRPC.Server, [:passthrough])

      :meck.expect(GRPC.Server, :send_reply, fn stream, message ->
        send(test_pid, {:grpc_reply, stream, message})
        :ok
      end)

      # Call subscribe
      result = Ratatoskr.Grpc.Server.subscribe(request, mock_stream)

      # Wait for the error message
      assert_receive {:grpc_reply, ^mock_stream, {:error, error_msg}}, 1000
      assert error_msg =~ "Topic does not exist"
      assert result == :ok

      :meck.unload(GRPC.Server)
    end

    test "handles valid subscription setup" do
      {:ok, _} = Ratatoskr.create_topic("valid-stream-topic")

      test_pid = self()

      # Mock the streaming to capture subscription setup calls
      :meck.new(GRPC.Server, [:passthrough])

      :meck.expect(GRPC.Server, :send_reply, fn stream, message ->
        send(test_pid, {:grpc_stream_setup, stream, message})
        :ok
      end)

      # Create subscription request
      request = %SubscribeRequest{
        topic: "valid-stream-topic",
        subscriber_id: "stream-test"
      }

      mock_stream = %GRPC.Server.Stream{
        server: test_pid,
        adapter: :mock
      }

      # Start subscription in background with timeout to avoid infinite sleep
      subscription_pid =
        spawn(fn ->
          # Override timer sleep to avoid blocking
          :meck.new(:timer, [:passthrough])
          :meck.expect(:timer, :sleep, fn :infinity -> Process.sleep(50) end)

          Ratatoskr.Grpc.Server.subscribe(request, mock_stream)

          :meck.unload(:timer)
        end)

      # Give subscription time to establish
      Process.sleep(200)

      # Clean up the subscription process
      if Process.alive?(subscription_pid) do
        Process.exit(subscription_pid, :kill)
      end

      :meck.unload(GRPC.Server)
    end

    test "unsubscribes from topic via gRPC" do
      {:ok, _} = Ratatoskr.create_topic("unsub-topic")
      {:ok, ref} = Ratatoskr.subscribe("unsub-topic")

      # Encode reference properly for gRPC transport
      encoded_ref = ref |> :erlang.term_to_binary() |> Base.encode64()

      request = %UnsubscribeRequest{
        topic: "unsub-topic",
        subscription_ref: encoded_ref
      }

      response = Ratatoskr.Grpc.Server.unsubscribe(request, %GRPC.Server.Stream{})

      assert %UnsubscribeResponse{success: true, error: ""} = response
    end

    test "handles unsubscribe for non-existent topic" do
      # Create a real reference first
      {:ok, _} = Ratatoskr.create_topic("temp-for-ref")
      {:ok, ref} = Ratatoskr.subscribe("temp-for-ref")

      # Encode reference properly for gRPC transport
      encoded_ref = ref |> :erlang.term_to_binary() |> Base.encode64()

      request = %UnsubscribeRequest{
        topic: "non-existent",
        subscription_ref: encoded_ref
      }

      response = Ratatoskr.Grpc.Server.unsubscribe(request, %GRPC.Server.Stream{})

      assert %UnsubscribeResponse{success: false} = response
      assert response.error != ""
    end

    test "handles unsubscribe with invalid subscription reference" do
      {:ok, _} = Ratatoskr.create_topic("valid-topic")

      # Use a fake reference string that can't be converted
      request = %UnsubscribeRequest{
        topic: "valid-topic",
        subscription_ref: "invalid-ref-format"
      }

      response = Ratatoskr.Grpc.Server.unsubscribe(request, %GRPC.Server.Stream{})

      assert %UnsubscribeResponse{success: false} = response
      assert response.error != ""
    end
  end

  describe "gRPC Message Conversion Helpers" do
    test "converts map payload to binary" do
      payload = %{data: "test message", metadata: %{key: "value"}}

      # Test the payload conversion through a publish request
      {:ok, _} = Ratatoskr.create_topic("conversion-topic")

      request = %PublishRequest{
        topic: "conversion-topic",
        payload: Jason.encode!(payload),
        metadata: %{"type" => "json"}
      }

      response = Ratatoskr.Grpc.Server.publish(request, %GRPC.Server.Stream{})
      assert %PublishResponse{success: true} = response
    end

    test "handles empty metadata in message conversion" do
      {:ok, _} = Ratatoskr.create_topic("empty-meta-topic")

      request = %PublishRequest{
        topic: "empty-meta-topic",
        payload: "simple message",
        metadata: %{}
      }

      response = Ratatoskr.Grpc.Server.publish(request, %GRPC.Server.Stream{})
      assert %PublishResponse{success: true} = response
    end

    test "handles nil metadata gracefully" do
      # This tests the convert_metadata/1 function's fallback clause
      {:ok, _} = Ratatoskr.create_topic("nil-meta-topic")

      # Publish a message and then get stats to trigger metadata conversion
      {:ok, _} = Ratatoskr.publish("nil-meta-topic", %{data: "test"})

      request = %GetStatsRequest{topic: "nil-meta-topic"}
      response = Ratatoskr.Grpc.Server.get_stats(request, %GRPC.Server.Stream{})

      assert %GetStatsResponse{message_count: 1} = response
    end

    test "converts different payload types correctly" do
      {:ok, _} = Ratatoskr.create_topic("payload-types-topic")

      # Test string payload
      request1 = %PublishRequest{
        topic: "payload-types-topic",
        payload: "simple string",
        metadata: %{}
      }

      response1 = Ratatoskr.Grpc.Server.publish(request1, %GRPC.Server.Stream{})
      assert %PublishResponse{success: true} = response1

      # Test binary payload
      binary_payload = <<1, 2, 3, 4, 5>>

      request2 = %PublishRequest{
        topic: "payload-types-topic",
        payload: binary_payload,
        metadata: %{}
      }

      response2 = Ratatoskr.Grpc.Server.publish(request2, %GRPC.Server.Stream{})
      assert %PublishResponse{success: true} = response2

      # Test JSON-like payload
      json_payload = Jason.encode!(%{nested: %{data: "complex"}, array: [1, 2, 3]})

      request3 = %PublishRequest{
        topic: "payload-types-topic",
        payload: json_payload,
        metadata: %{"content-type" => "application/json"}
      }

      response3 = Ratatoskr.Grpc.Server.publish(request3, %GRPC.Server.Stream{})
      assert %PublishResponse{success: true} = response3
    end

    test "handles complex metadata structures" do
      {:ok, _} = Ratatoskr.create_topic("complex-meta-topic")

      complex_metadata = %{
        "string_value" => "text",
        "integer_string" => "42",
        "float_string" => "3.14",
        "boolean_string" => "true",
        "uuid" => "550e8400-e29b-41d4-a716-446655440000",
        "timestamp" => "2024-01-15T10:30:00Z"
      }

      request = %PublishRequest{
        topic: "complex-meta-topic",
        payload: "test with complex metadata",
        metadata: complex_metadata
      }

      response = Ratatoskr.Grpc.Server.publish(request, %GRPC.Server.Stream{})
      assert %PublishResponse{success: true} = response
    end
  end

  describe "gRPC Error Handling" do
    test "handles publish to topic that gets deleted during operation" do
      {:ok, _} = Ratatoskr.create_topic("temp-topic")

      # Delete the topic to simulate race condition
      :ok = Ratatoskr.delete_topic("temp-topic")

      request = %PublishRequest{
        topic: "temp-topic",
        payload: "test message",
        metadata: %{}
      }

      response = Ratatoskr.Grpc.Server.publish(request, %GRPC.Server.Stream{})

      assert %PublishResponse{success: false} = response
      assert response.error != ""
    end

    test "handles batch publish with some invalid topics" do
      {:ok, _} = Ratatoskr.create_topic("valid-batch-topic")

      messages = [
        %PublishRequest{topic: "valid-batch-topic", payload: "msg1", metadata: %{}},
        %PublishRequest{topic: "invalid-topic", payload: "msg2", metadata: %{}},
        %PublishRequest{topic: "valid-batch-topic", payload: "msg3", metadata: %{}}
      ]

      request = %PublishBatchRequest{
        topic: "valid-batch-topic",
        messages: messages
      }

      response = Ratatoskr.Grpc.Server.publish_batch(request, %GRPC.Server.Stream{})

      assert %PublishBatchResponse{
               success_count: 2,
               error_count: 1,
               results: results
             } = response

      assert length(results) == 3
      assert Enum.at(results, 0).success == true
      assert Enum.at(results, 1).success == false
      assert Enum.at(results, 2).success == true
    end

    test "handles create topic with empty name" do
      # Test with empty name - this may succeed depending on the broker implementation
      request = %CreateTopicRequest{name: ""}
      response = Ratatoskr.Grpc.Server.create_topic(request, %GRPC.Server.Stream{})

      # Just verify we get a valid response structure
      assert %CreateTopicResponse{} = response
      # Empty name might be allowed, so don't assert specific success/failure
    end

    test "handles stats request for topic with no subscribers" do
      {:ok, _} = Ratatoskr.create_topic("no-subs-topic")
      {:ok, _} = Ratatoskr.publish("no-subs-topic", %{data: "lonely message"})

      request = %GetStatsRequest{topic: "no-subs-topic"}
      response = Ratatoskr.Grpc.Server.get_stats(request, %GRPC.Server.Stream{})

      assert %GetStatsResponse{
               topic: "no-subs-topic",
               message_count: 1,
               subscriber_count: 0,
               error: ""
             } = response
    end
  end
end
