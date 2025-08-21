defmodule Ratatoskr.GrpcTest do
  use ExUnit.Case
  doctest Ratatoskr.Grpc.Server

  alias Ratatoskr.Grpc.{
    CreateTopicRequest, CreateTopicResponse,
    DeleteTopicRequest, DeleteTopicResponse,
    ListTopicsRequest, ListTopicsResponse,
    TopicExistsRequest, TopicExistsResponse,
    GetStatsRequest, GetStatsResponse,
    PublishRequest, PublishResponse,
    PublishBatchRequest, PublishBatchResponse
  }

  setup do
    # Start fresh for each test
    topics = case Ratatoskr.list_topics() do
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
end