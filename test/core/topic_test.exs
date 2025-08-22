defmodule Ratatoskr.Core.TopicEntityTest do
  use ExUnit.Case, async: true
  alias Ratatoskr.Core.Logic.{Topic, Message}

  describe "Topic.new/2" do
    test "creates a valid topic with default configuration" do
      assert {:ok, topic} = Topic.new("orders")

      assert topic.name == "orders"
      assert topic.partitions == 1
      assert topic.max_subscribers == 1000
      assert match?(%DateTime{}, topic.created_at)
      assert topic.config == %{}
    end

    test "creates topic with custom configuration" do
      config = %{partitions: 4, max_subscribers: 500, retention_ms: 86_400_000}
      assert {:ok, topic} = Topic.new("events", config)

      assert topic.name == "events"
      assert topic.partitions == 4
      assert topic.max_subscribers == 500
      assert topic.config[:retention_ms] == 86_400_000
    end

    test "validates topic name" do
      assert {:error, :empty_topic_name} = Topic.new("")
      assert {:error, :topic_name_too_long} = Topic.new(String.duplicate("a", 256))
      assert {:error, :invalid_topic_name_format} = Topic.new("invalid-topic!")
    end

    test "validates partitions" do
      assert {:error, :invalid_partitions} = Topic.new("test", %{partitions: 0})
      assert {:error, :invalid_partitions} = Topic.new("test", %{partitions: -1})
      assert {:error, :invalid_partitions} = Topic.new("test", %{partitions: "invalid"})
    end

    test "validates max_subscribers" do
      assert {:error, :invalid_max_subscribers} = Topic.new("test", %{max_subscribers: 0})
      assert {:error, :invalid_max_subscribers} = Topic.new("test", %{max_subscribers: -1})
    end
  end

  describe "Topic.route_message/2" do
    setup do
      {:ok, single_partition} = Topic.new("single")
      {:ok, multi_partition} = Topic.new("multi", %{partitions: 4})
      {:ok, message} = Message.new("test", %{id: 123})

      %{
        single_partition: single_partition,
        multi_partition: multi_partition,
        message: message
      }
    end

    test "routes to partition 0 for single partition topic", %{
      single_partition: topic,
      message: message
    } do
      assert Topic.route_message(topic, message) == 0
    end

    test "routes based on partition key when present", %{multi_partition: topic} do
      {:ok, message_with_key} = Message.new("test", %{}, partition_key: "user-123")
      partition = Topic.route_message(topic, message_with_key)

      assert partition in 0..3

      # Same key should always route to same partition
      assert Topic.route_message(topic, message_with_key) == partition
    end

    test "routes based on message ID when no partition key", %{
      multi_partition: topic,
      message: message
    } do
      partition = Topic.route_message(topic, message)
      assert partition in 0..3

      # Same message should always route to same partition
      assert Topic.route_message(topic, message) == partition
    end
  end

  describe "Topic.can_add_subscriber?/2" do
    test "allows subscribers under the limit" do
      {:ok, topic} = Topic.new("test", %{max_subscribers: 5})

      assert Topic.can_add_subscriber?(topic, 0)
      assert Topic.can_add_subscriber?(topic, 4)
      refute Topic.can_add_subscriber?(topic, 5)
      refute Topic.can_add_subscriber?(topic, 10)
    end

    test "handles unlimited subscribers" do
      {:ok, topic} = Topic.new("test", %{max_subscribers: :unlimited})

      assert Topic.can_add_subscriber?(topic, 0)
      assert Topic.can_add_subscriber?(topic, 1000)
      assert Topic.can_add_subscriber?(topic, 999_999)
    end
  end

  describe "Topic.update_config/2" do
    test "updates valid configuration" do
      {:ok, topic} = Topic.new("test")
      new_config = %{max_subscribers: 2000, custom_setting: "value"}

      assert {:ok, updated_topic} = Topic.update_config(topic, new_config)
      assert updated_topic.max_subscribers == 2000
      assert updated_topic.config[:custom_setting] == "value"
    end

    test "validates configuration updates" do
      {:ok, topic} = Topic.new("test")

      assert {:error, :invalid_max_subscribers} =
               Topic.update_config(topic, %{max_subscribers: -1})

      assert {:error, :invalid_partitions} =
               Topic.update_config(topic, %{partitions: 0})
    end

    test "preserves existing configuration" do
      {:ok, topic} = Topic.new("test", %{custom: "original"})

      {:ok, updated} = Topic.update_config(topic, %{max_subscribers: 500})

      assert updated.max_subscribers == 500
      assert updated.config[:custom] == "original"
    end
  end

  describe "Topic.stats_template/1" do
    test "creates proper stats template" do
      {:ok, topic} = Topic.new("test")
      stats = Topic.stats_template(topic)

      assert stats.topic == "test"
      assert stats.message_count == 0
      assert stats.subscriber_count == 0
      assert is_nil(stats.last_message_at)
      assert match?(%DateTime{}, stats.created_at)
    end
  end

  describe "Topic.valid?/1" do
    test "validates well-formed topics" do
      {:ok, topic} = Topic.new("valid_topic")
      assert Topic.valid?(topic)
    end

    test "detects invalid topics" do
      {:ok, valid_topic} = Topic.new("valid")

      # Invalid name
      invalid_name = %{valid_topic | name: ""}
      refute Topic.valid?(invalid_name)

      # Invalid partitions
      invalid_partitions = %{valid_topic | partitions: 0}
      refute Topic.valid?(invalid_partitions)

      # Invalid max_subscribers
      invalid_max = %{valid_topic | max_subscribers: -1}
      refute Topic.valid?(invalid_max)
    end
  end
end
