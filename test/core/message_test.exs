defmodule Ratatoskr.Core.MessageTest do
  use ExUnit.Case, async: true
  alias Ratatoskr.Core.Message

  describe "Message.new/3" do
    test "creates a valid message with required fields" do
      assert {:ok, message} = Message.new("orders", %{id: 123, amount: 99.90})

      assert message.topic == "orders"
      assert message.payload == %{id: 123, amount: 99.90}
      assert is_binary(message.id)
      assert match?(%DateTime{}, message.timestamp)
      assert message.metadata == %{}
      assert is_nil(message.partition_key)
    end

    test "accepts metadata and partition_key options" do
      opts = [
        metadata: %{"source" => "api", "version" => "1.0"},
        partition_key: "user-123"
      ]

      assert {:ok, message} = Message.new("users", %{name: "John"}, opts)

      assert message.metadata == %{"source" => "api", "version" => "1.0"}
      assert message.partition_key == "user-123"
    end

    test "validates topic name" do
      assert {:error, :empty_topic} = Message.new("", %{})
      assert {:error, :topic_too_long} = Message.new(String.duplicate("a", 256), %{})
      assert {:error, :invalid_topic_format} = Message.new("invalid topic!", %{})
      assert {:error, :topic_must_be_string} = Message.new(123, %{})
    end

    test "validates payload serializability" do
      # Valid payloads
      assert {:ok, _} = Message.new("test", %{data: "string"})
      assert {:ok, _} = Message.new("test", [1, 2, 3])
      assert {:ok, _} = Message.new("test", 42)

      # Invalid payload (functions are not serializable)
      invalid_payload = fn -> :ok end
      assert {:error, :payload_not_serializable} = Message.new("test", invalid_payload)
    end
  end

  describe "Message.new!/3" do
    test "creates message successfully" do
      message = Message.new!("orders", %{id: 123})
      assert message.topic == "orders"
    end

    test "raises on validation errors" do
      assert_raise ArgumentError, ~r/Invalid message: empty_topic/, fn ->
        Message.new!("", %{})
      end
    end
  end

  describe "Message metadata operations" do
    setup do
      {:ok, message} = Message.new("test", %{data: "value"})
      %{message: message}
    end

    test "adds metadata to message", %{message: message} do
      updated = Message.add_metadata(message, "key", "value")
      assert updated.metadata["key"] == "value"

      updated = Message.add_metadata(updated, :atom_key, 123)
      assert updated.metadata["atom_key"] == 123
    end

    test "gets metadata from message", %{message: message} do
      message = Message.add_metadata(message, "key", "value")

      assert Message.get_metadata(message, "key") == "value"
      assert Message.get_metadata(message, :key) == "value"
      assert Message.get_metadata(message, "nonexistent") == nil
      assert Message.get_metadata(message, "nonexistent", "default") == "default"
    end
  end

  describe "Message.valid?/1" do
    test "validates well-formed messages" do
      {:ok, message} = Message.new("valid_topic", %{data: "test"})
      assert Message.valid?(message)
    end

    test "detects invalid messages" do
      {:ok, valid_message} = Message.new("valid", %{})

      # Invalid topic
      invalid_topic = %{valid_message | topic: ""}
      refute Message.valid?(invalid_topic)

      # Invalid timestamp
      invalid_timestamp = %{valid_message | timestamp: "not a datetime"}
      refute Message.valid?(invalid_timestamp)

      # Invalid ID
      invalid_id = %{valid_message | id: nil}
      refute Message.valid?(invalid_id)
    end
  end

  describe "Message.size_bytes/1" do
    test "calculates message size in bytes" do
      {:ok, message} = Message.new("test", %{data: "hello"})
      size = Message.size_bytes(message)

      assert is_integer(size)
      assert size > 0

      # Larger payload should result in larger size
      {:ok, large_message} = Message.new("test", %{data: String.duplicate("a", 1000)})
      large_size = Message.size_bytes(large_message)

      assert large_size > size
    end

    test "handles different payload types" do
      test_cases = [
        %{simple: "string"},
        [1, 2, 3, 4, 5],
        {:tuple, "with", :values},
        %{nested: %{deep: %{structure: true}}}
      ]

      for payload <- test_cases do
        {:ok, message} = Message.new("test", payload)
        size = Message.size_bytes(message)
        assert is_integer(size)
        assert size > 0
      end
    end
  end

  describe "Message ID generation" do
    test "generates unique IDs" do
      {:ok, msg1} = Message.new("test", %{})
      {:ok, msg2} = Message.new("test", %{})

      assert msg1.id != msg2.id
      assert String.length(msg1.id) == String.length(msg2.id)
    end

    test "generates UUID v4 format" do
      {:ok, message} = Message.new("test", %{})

      # UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
      uuid_pattern = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

      assert Regex.match?(uuid_pattern, message.id)
    end
  end
end
