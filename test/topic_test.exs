defmodule Ratatoskr.Core.TopicTest do
  use ExUnit.Case, async: true
  alias Ratatoskr.Core.Logic.{Message, Topic}
  alias Ratatoskr.Servers.TopicServer

  setup do
    topic_name = "test_topic_#{:rand.uniform(1000)}"
    {:ok, topic} = Topic.new(topic_name)
    {:ok, topic_pid} = TopicServer.start_link(topic)

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

    test "publishes messages and returns message ID", %{topic_pid: topic_pid} do
      payload = %{data: "hello world"}
      {:ok, message} = Message.new("test_topic", payload)
      assert {:ok, message_id} = TopicServer.publish_to_server(topic_pid, message)
      assert is_binary(message_id)
    end

    test "subscribes processes and receives messages", %{
      topic_name: topic_name,
      topic_pid: topic_pid
    } do
      # Create subscription
      {:ok, subscription} = Ratatoskr.Core.Logic.Subscription.new(topic_name, self())
      assert {:ok, _subscription_ref} = TopicServer.subscribe_to_server(topic_pid, subscription)

      # Publish a message
      payload = %{data: "test message"}
      {:ok, message} = Message.new(topic_name, payload)
      assert {:ok, _message_id} = TopicServer.publish_to_server(topic_pid, message)

      # Should receive the message
      assert_receive {:message, %Message{payload: ^payload}}, 1000
    end

    test "supports multiple subscribers", %{topic_name: topic_name, topic_pid: topic_pid} do
      # Create multiple subscriber processes
      subscribers =
        for _ <- 1..3 do
          spawn_link(fn ->
            {:ok, subscription} = Ratatoskr.Core.Logic.Subscription.new(topic_name, self())
            {:ok, _ref} = TopicServer.subscribe_to_server(topic_pid, subscription)

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
      {:ok, message} = Message.new(topic_name, payload)
      {:ok, _message_id} = TopicServer.publish_to_server(topic_pid, message)

      # All subscribers should receive the message
      for subscriber <- subscribers do
        assert_receive {:received, ^subscriber, %Message{payload: ^payload}}, 1000
      end
    end

    test "unsubscribes processes correctly", %{topic_name: topic_name, topic_pid: topic_pid} do
      # Subscribe
      {:ok, subscription} = Ratatoskr.Core.Logic.Subscription.new(topic_name, self())
      {:ok, subscription_ref} = TopicServer.subscribe_to_server(topic_pid, subscription)

      # Unsubscribe
      assert :ok = TopicServer.unsubscribe_from_server(topic_pid, subscription_ref)

      # Publish a message
      {:ok, message} = Message.new(topic_name, %{data: "should not receive"})
      {:ok, _message_id} = TopicServer.publish_to_server(topic_pid, message)

      # Should not receive the message
      refute_receive {:message, _}, 100
    end

    test "handles subscriber process death", %{topic_name: topic_name, topic_pid: topic_pid} do
      # Start initial stats
      {:ok, initial_stats} = TopicServer.get_stats(topic_pid)
      assert initial_stats.subscriber_count == 0

      # Create a subscriber process that will die
      subscriber_pid =
        spawn(fn ->
          {:ok, subscription} = Ratatoskr.Core.Logic.Subscription.new(topic_name, self())
          {:ok, _ref} = TopicServer.subscribe_to_server(topic_pid, subscription)

          receive do
            :die -> exit(:normal)
          end
        end)

      # Wait for subscription
      Process.sleep(10)

      # Check subscriber was added
      {:ok, stats} = TopicServer.get_stats(topic_pid)
      assert stats.subscriber_count == 1

      # Kill the subscriber
      send(subscriber_pid, :die)
      Process.sleep(10)

      # Check subscriber was removed
      {:ok, final_stats} = TopicServer.get_stats(topic_pid)
      assert final_stats.subscriber_count == 0
    end

    test "returns topic statistics", %{topic_name: topic_name, topic_pid: topic_pid} do
      {:ok, stats} = TopicServer.get_stats(topic_pid)

      assert %{
               topic: ^topic_name,
               message_count: 0,
               subscriber_count: 0
             } = stats

      # Add a subscriber and message
      {:ok, subscription} = Ratatoskr.Core.Logic.Subscription.new(topic_name, self())
      {:ok, _ref} = TopicServer.subscribe_to_server(topic_pid, subscription)
      {:ok, message} = Message.new(topic_name, %{data: "test"})
      {:ok, _message_id} = TopicServer.publish_to_server(topic_pid, message)

      {:ok, new_stats} = TopicServer.get_stats(topic_pid)
      assert new_stats.subscriber_count == 1
      assert new_stats.message_count == 1
    end

    test "handles topic server operations directly" do
      # Create a topic and test health check on the actual topic server
      {:ok, topic} = Topic.new("health_check_test")
      {:ok, topic_pid} = TopicServer.start_link(topic)

      # Now health check the actual topic server process
      assert :ok = TopicServer.health_check(topic_pid)

      # Clean up
      GenServer.stop(topic_pid)
    end

    test "preserves message order (FIFO)", %{topic_name: topic_name, topic_pid: topic_pid} do
      # Subscribe first
      {:ok, subscription} = Ratatoskr.Core.Logic.Subscription.new(topic_name, self())
      {:ok, _ref} = TopicServer.subscribe_to_server(topic_pid, subscription)

      # Publish multiple messages quickly
      messages =
        for i <- 1..5 do
          payload = %{id: i, data: "message #{i}"}
          {:ok, message} = Message.new(topic_name, payload)
          {:ok, _id} = TopicServer.publish_to_server(topic_pid, message)
          payload
        end

      # Receive messages and check order
      received_messages =
        for _i <- 1..5 do
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
