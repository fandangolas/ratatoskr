defmodule RatatoskrTest do
  use ExUnit.Case, async: false  # Changed to false to prevent race conditions in topic management
  doctest Ratatoskr

  describe "Topic Management" do
    test "creates and lists topics" do
      topic_name = "test_topic_#{:rand.uniform(100000)}_#{System.system_time(:microsecond)}"

      # Clean up any existing topic first (defensive)
      if Ratatoskr.topic_exists?(topic_name) do
        Ratatoskr.delete_topic(topic_name)
        Process.sleep(10)
      end

      # Topic shouldn't exist initially
      assert false == Ratatoskr.topic_exists?(topic_name)

      # Create topic
      assert {:ok, ^topic_name} = Ratatoskr.create_topic(topic_name)

      # Topic should now exist
      assert true == Ratatoskr.topic_exists?(topic_name)

      # Should appear in topic list
      {:ok, topics} = Ratatoskr.list_topics()
      assert topic_name in topics

      # Clean up
      assert :ok = Ratatoskr.delete_topic(topic_name)
      assert false == Ratatoskr.topic_exists?(topic_name)
    end

    test "handles duplicate topic creation" do
      topic_name = "duplicate_test_#{:rand.uniform(1000)}"

      # Create topic
      assert {:ok, ^topic_name} = Ratatoskr.create_topic(topic_name)

      # Try to create same topic again
      assert {:error, :topic_already_exists} = Ratatoskr.create_topic(topic_name)

      # Clean up
      Ratatoskr.delete_topic(topic_name)
    end

    test "handles deletion of non-existent topics" do
      assert {:error, :topic_not_found} = Ratatoskr.delete_topic("nonexistent_topic")
    end
  end

  describe "Pub/Sub Integration" do
    setup do
      topic_name = "integration_test_#{:rand.uniform(1000)}"
      {:ok, ^topic_name} = Ratatoskr.create_topic(topic_name)

      on_exit(fn -> Ratatoskr.delete_topic(topic_name) end)

      %{topic: topic_name}
    end

    test "basic publish and subscribe flow", %{topic: topic_name} do
      # Subscribe to topic
      {:ok, subscription_ref} = Ratatoskr.subscribe(topic_name)

      # Publish a message
      payload = %{id: 123, amount: 99.90, currency: "USD"}
      {:ok, message_id} = Ratatoskr.publish(topic_name, payload)

      assert is_binary(message_id)

      # Should receive the message
      assert_receive {:message, message}, 1000
      assert message.payload == payload
      assert message.topic == topic_name
      assert message.id == message_id

      # Unsubscribe
      assert :ok = Ratatoskr.unsubscribe(topic_name, subscription_ref)

      # Publish another message - should not receive it
      {:ok, _} = Ratatoskr.publish(topic_name, %{data: "should not receive"})
      refute_receive {:message, _}, 100
    end

    test "multiple subscribers receive same message", %{topic: topic_name} do
      # Create multiple test processes
      test_pid = self()

      _subscribers =
        for i <- 1..3 do
          spawn_link(fn ->
            {:ok, _ref} = Ratatoskr.subscribe(topic_name)

            receive do
              {:message, message} ->
                send(test_pid, {:subscriber_received, i, message})
            end
          end)
        end

      # Wait for subscriptions to be registered
      Process.sleep(10)

      # Publish message
      payload = %{broadcast: "message to all"}
      {:ok, message_id} = Ratatoskr.publish(topic_name, payload)

      # All subscribers should receive the message
      for i <- 1..3 do
        assert_receive {:subscriber_received, ^i, message}, 1000
        assert message.payload == payload
        assert message.id == message_id
      end
    end

    test "topic stats are accurate", %{topic: topic_name} do
      # Initial stats
      {:ok, stats} = Ratatoskr.stats(topic_name)
      assert stats.message_count == 0
      assert stats.subscriber_count == 0
      assert stats.topic == topic_name

      # Add subscriber
      {:ok, _ref} = Ratatoskr.subscribe(topic_name)
      {:ok, stats} = Ratatoskr.stats(topic_name)
      assert stats.subscriber_count == 1

      # Add messages
      {:ok, _} = Ratatoskr.publish(topic_name, %{msg: 1})
      {:ok, _} = Ratatoskr.publish(topic_name, %{msg: 2})

      {:ok, stats} = Ratatoskr.stats(topic_name)
      assert stats.message_count == 2
      assert stats.subscriber_count == 1
    end
  end

  describe "Error Handling" do
    test "handles operations on non-existent topics" do
      nonexistent = "nonexistent_#{:rand.uniform(1000)}"

      # Publish should succeed by auto-creating the topic
      assert {:ok, _message_id} = Ratatoskr.publish(nonexistent, %{})

      # Verify topic was auto-created
      assert Ratatoskr.topic_exists?(nonexistent)

      # Other operations on truly non-existent topics should fail
      nonexistent2 = "nonexistent2_#{:rand.uniform(1000)}"
      assert {:error, :topic_not_found} = Ratatoskr.subscribe(nonexistent2)
      assert {:error, :topic_not_found} = Ratatoskr.stats(nonexistent2)

      # These should also handle gracefully
      fake_ref = make_ref()
      assert {:error, :topic_not_found} = Ratatoskr.unsubscribe(nonexistent2, fake_ref)
    end

    test "handles invalid subscription references" do
      topic_name = "invalid_ref_test_#{:rand.uniform(1000)}"
      {:ok, ^topic_name} = Ratatoskr.create_topic(topic_name)

      # Try to unsubscribe with invalid reference
      fake_ref = make_ref()
      assert {:error, :subscription_not_found} = Ratatoskr.unsubscribe(topic_name, fake_ref)

      Ratatoskr.delete_topic(topic_name)
    end
  end
end
