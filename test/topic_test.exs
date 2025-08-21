defmodule Ratatoskr.TopicTest do
  use ExUnit.Case, async: true
  alias Ratatoskr.Topic.Server, as: TopicServer
  alias Ratatoskr.Message

  setup do
    topic_name = "test_topic_#{:rand.uniform(1000)}"
    {:ok, topic_pid} = TopicServer.start_link(topic_name)
    
    on_exit(fn ->
      if Process.alive?(topic_pid) do
        Process.exit(topic_pid, :kill)
      end
    end)
    
    %{topic_name: topic_name, topic_pid: topic_pid}
  end

  describe "Topic Server" do
    test "starts successfully", %{topic_name: topic_name} do
      case Registry.lookup(Ratatoskr.Registry, topic_name) do
        [{_pid, _}] -> assert true
        [] -> flunk("Topic process not found in registry")
      end
    end

    test "publishes messages and returns message ID", %{topic_name: topic_name} do
      payload = %{data: "hello world"}
      assert {:ok, message_id} = TopicServer.publish(topic_name, payload)
      assert is_binary(message_id)
    end

    test "subscribes processes and receives messages", %{topic_name: topic_name} do
      # Subscribe to the topic
      assert {:ok, subscription_ref} = TopicServer.subscribe(topic_name, self())
      
      # Publish a message
      payload = %{data: "test message"}
      assert {:ok, _message_id} = TopicServer.publish(topic_name, payload)
      
      # Should receive the message
      assert_receive {:message, %Message{payload: ^payload}}, 1000
    end

    test "supports multiple subscribers", %{topic_name: topic_name} do
      # Create multiple subscriber processes
      subscribers = for _ <- 1..3 do
        spawn_link(fn ->
          {:ok, _ref} = TopicServer.subscribe(topic_name, self())
          receive do
            {:message, message} -> send(:test, {:received, self(), message})
          end
        end)
      end
      
      Process.register(self(), :test)
      
      # Small delay to ensure subscriptions are registered
      Process.sleep(10)
      
      # Publish a message
      payload = %{data: "broadcast"}
      {:ok, _message_id} = TopicServer.publish(topic_name, payload)
      
      # All subscribers should receive the message
      for subscriber <- subscribers do
        assert_receive {:received, ^subscriber, %Message{payload: ^payload}}, 1000
      end
    end

    test "unsubscribes processes correctly", %{topic_name: topic_name} do
      # Subscribe
      {:ok, subscription_ref} = TopicServer.subscribe(topic_name, self())
      
      # Unsubscribe
      assert :ok = TopicServer.unsubscribe(topic_name, subscription_ref)
      
      # Publish a message
      {:ok, _message_id} = TopicServer.publish(topic_name, %{data: "should not receive"})
      
      # Should not receive the message
      refute_receive {:message, _}, 100
    end

    test "handles subscriber process death", %{topic_name: topic_name} do
      # Start initial stats
      {:ok, initial_stats} = TopicServer.stats(topic_name)
      assert initial_stats.subscriber_count == 0
      
      # Create a subscriber process that will die
      subscriber_pid = spawn(fn ->
        {:ok, _ref} = TopicServer.subscribe(topic_name, self())
        receive do
          :die -> exit(:normal)
        end
      end)
      
      # Wait for subscription
      Process.sleep(10)
      
      # Check subscriber was added
      {:ok, stats} = TopicServer.stats(topic_name)
      assert stats.subscriber_count == 1
      
      # Kill the subscriber
      send(subscriber_pid, :die)
      Process.sleep(10)
      
      # Check subscriber was removed
      {:ok, final_stats} = TopicServer.stats(topic_name)
      assert final_stats.subscriber_count == 0
    end

    test "returns topic statistics", %{topic_name: topic_name} do
      {:ok, stats} = TopicServer.stats(topic_name)
      
      assert %{
        topic: ^topic_name,
        message_count: 0,
        subscriber_count: 0
      } = stats
      
      # Add a subscriber and message
      {:ok, _ref} = TopicServer.subscribe(topic_name, self())
      {:ok, _message_id} = TopicServer.publish(topic_name, %{data: "test"})
      
      {:ok, new_stats} = TopicServer.stats(topic_name)
      assert new_stats.subscriber_count == 1
      assert new_stats.message_count == 1
    end

    test "handles errors for non-existent topics" do
      assert {:error, :topic_not_found} = TopicServer.publish("nonexistent", %{})
      assert {:error, :topic_not_found} = TopicServer.subscribe("nonexistent", self())
      assert {:error, :topic_not_found} = TopicServer.stats("nonexistent")
    end

    test "preserves message order (FIFO)", %{topic_name: topic_name} do
      # Subscribe first
      {:ok, _ref} = TopicServer.subscribe(topic_name, self())
      
      # Publish multiple messages quickly
      messages = for i <- 1..5 do
        payload = %{id: i, data: "message #{i}"}
        {:ok, _id} = TopicServer.publish(topic_name, payload)
        payload
      end
      
      # Receive messages and check order
      received_messages = for _i <- 1..5 do
        receive do
          {:message, %Message{payload: payload}} -> payload
        after
          1000 -> nil
        end
      end
      
      assert received_messages == messages
    end
  end
end