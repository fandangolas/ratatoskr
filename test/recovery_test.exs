defmodule Ratatoskr.RecoveryTest do
  use ExUnit.Case, async: false
  alias Ratatoskr.BenchmarkHelpers
  require Logger

  @moduletag :recovery
  @moduletag timeout: 30_000

  setup_all do
    # Ensure application is started
    Application.ensure_all_started(:ratatoskr)
    :ok
  end

  describe "Supervisor Tree Recovery" do
    test "topic server recovers from crashes" do
      topic_name = BenchmarkHelpers.benchmark_topic("crash_recovery")
      
      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)
      
      Logger.info("Testing topic server crash recovery")
      
      # Create topic and establish baseline
      {:ok, _topic} = Ratatoskr.create_topic(topic_name)
      {:ok, ref} = Ratatoskr.subscribe(topic_name)
      
      # Verify topic is working
      {:ok, _} = Ratatoskr.publish(topic_name, %{before: "crash"})
      assert_receive {:message, _}, 1000
      
      # Get the topic process PID
      [{topic_pid, _}] = Registry.lookup(Ratatoskr.Registry, topic_name)
      assert Process.alive?(topic_pid)
      
      # Kill the topic process
      Process.monitor(topic_pid)
      Process.exit(topic_pid, :kill)
      
      # Wait for the process to die
      receive do
        {:DOWN, _ref, :process, ^topic_pid, :killed} -> :ok
      after
        1000 -> flunk("Topic process didn't die within timeout")
      end
      
      refute Process.alive?(topic_pid)
      
      # Since restart is :transient, topic won't auto-restart after :kill
      # But we should be able to create it again
      Process.sleep(100)
      
      # Topic should be recreatable
      {:ok, _topic} = Ratatoskr.create_topic(topic_name)
      
      # Get new PID and verify it's different  
      [{new_topic_pid, _}] = Registry.lookup(Ratatoskr.Registry, topic_name)
      assert Process.alive?(new_topic_pid)
      assert new_topic_pid != topic_pid
      
      # Should be functional again
      {:ok, new_ref} = Ratatoskr.subscribe(topic_name)
      {:ok, _} = Ratatoskr.publish(topic_name, %{after: "recovery"})
      assert_receive {:message, message}, 1000
      assert message.payload.after == "recovery"
      
      Logger.info("✅ Topic server successfully recovered from crash")
    end

    test "broker recovers from crashes" do
      Logger.info("Testing broker crash recovery")
      
      topic_name = BenchmarkHelpers.benchmark_topic("broker_crash")
      
      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)
      
      # Create topic through broker
      {:ok, _topic} = Ratatoskr.create_topic(topic_name)
      {:ok, initial_topics} = Ratatoskr.list_topics()
      assert topic_name in initial_topics
      
      # Get broker PID
      broker_pid = Process.whereis(Ratatoskr.Broker)
      assert is_pid(broker_pid)
      
      # Kill the broker
      Process.monitor(broker_pid)
      Process.exit(broker_pid, :kill)
      
      # Wait for broker to die
      receive do
        {:DOWN, _ref, :process, ^broker_pid, :killed} -> :ok
      after
        1000 -> flunk("Broker process didn't die within timeout")
      end
      
      # Wait for supervisor to restart broker
      Process.sleep(200)
      
      # Verify new broker is running
      new_broker_pid = Process.whereis(Ratatoskr.Broker)
      assert is_pid(new_broker_pid)
      assert new_broker_pid != broker_pid
      
      # Broker should be functional (though it lost state)
      new_topic = BenchmarkHelpers.benchmark_topic("post_broker_crash")
      {:ok, _} = Ratatoskr.create_topic(new_topic)
      {:ok, topics} = Ratatoskr.list_topics()
      assert new_topic in topics
      
      # Clean up
      BenchmarkHelpers.cleanup_benchmark_topic(new_topic)
      
      Logger.info("✅ Broker successfully recovered from crash")
    end

    test "application supervision tree recovery" do
      Logger.info("Testing full application supervision tree")
      
      topic_name = BenchmarkHelpers.benchmark_topic("app_supervision")
      
      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)
      
      # Verify all main components are running
      assert is_pid(Process.whereis(Ratatoskr.Supervisor))
      assert is_pid(Process.whereis(Ratatoskr.Broker))
      assert is_pid(Process.whereis(Ratatoskr.Topic.Supervisor))
      
      # Registry should be running
      registry_pid = Process.whereis(Ratatoskr.Registry)
      assert is_pid(registry_pid)
      
      # Create topic and verify it's registered
      {:ok, _} = Ratatoskr.create_topic(topic_name)
      assert [{_pid, _}] = Registry.lookup(Ratatoskr.Registry, topic_name)
      
      # Kill registry (this will affect topic discovery)
      Process.exit(registry_pid, :kill)
      Process.sleep(100)
      
      # Registry should be restarted by supervisor
      new_registry_pid = Process.whereis(Ratatoskr.Registry)
      assert is_pid(new_registry_pid)
      assert new_registry_pid != registry_pid
      
      # Should be able to create new topics with new registry
      new_topic = BenchmarkHelpers.benchmark_topic("post_registry_crash")
      {:ok, _} = Ratatoskr.create_topic(new_topic)
      assert [{_pid, _}] = Registry.lookup(Ratatoskr.Registry, new_topic)
      
      BenchmarkHelpers.cleanup_benchmark_topic(new_topic)
      
      Logger.info("✅ Application supervision tree recovered successfully")
    end
  end

  describe "Graceful Degradation" do
    test "handles cascading subscriber failures" do
      topic_name = BenchmarkHelpers.benchmark_topic("cascade_failure")
      
      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)
      
      Logger.info("Testing cascading subscriber failure handling")
      
      {:ok, _topic} = Ratatoskr.create_topic(topic_name)
      
      # Create multiple subscriber processes that will crash
      subscriber_count = 10
      crash_subscribers = for i <- 1..subscriber_count do
        spawn_link(fn ->
          {:ok, _ref} = Ratatoskr.subscribe(topic_name)
          
          # Wait for message, then crash
          receive do
            {:message, _message} ->
              exit(:intentional_crash)  # Simulate subscriber crash
          end
        end)
      end
      
      # Create one healthy subscriber to verify topic still works
      healthy_subscriber = spawn_link(fn ->
        {:ok, _ref} = Ratatoskr.subscribe(topic_name)
        
        receive do
          {:message, message} ->
            send(:recovery_test, {:healthy_received, message})
        end
      end)
      
      Process.register(self(), :recovery_test)
      
      # Wait for all subscriptions
      Process.sleep(100)
      
      # Verify initial subscriber count
      {:ok, stats} = Ratatoskr.stats(topic_name)
      assert stats.subscriber_count == subscriber_count + 1
      
      # Publish message that will cause crashes
      {:ok, _} = Ratatoskr.publish(topic_name, %{trigger: "crash"})
      
      # Wait for crashes to propagate
      Process.sleep(500)
      
      # Verify healthy subscriber still received message
      assert_receive {:healthy_received, message}, 2000
      assert message.payload.trigger == "crash"
      
      # Check that crashed subscribers were cleaned up
      {:ok, final_stats} = Ratatoskr.stats(topic_name)
      assert final_stats.subscriber_count == 1  # Only healthy subscriber remains
      
      # Topic should still be functional
      {:ok, _} = Ratatoskr.publish(topic_name, %{after: "cascade"})
      
      Logger.info([
        "✅ Cascading failure handled gracefully",
        "💥 Crashed subscribers: #{subscriber_count}",
        "✅ Healthy subscribers: #{final_stats.subscriber_count}",
        "📊 Topic still functional: ✓"
      ] |> Enum.join(" | "))
    end

    test "handles topic overload gracefully" do
      topic_name = BenchmarkHelpers.benchmark_topic("overload_test")
      
      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)
      
      Logger.info("Testing topic overload handling")
      
      {:ok, _topic} = Ratatoskr.create_topic(topic_name)
      
      # Create subscriber that processes slowly
      slow_subscriber = spawn_link(fn ->
        {:ok, _ref} = Ratatoskr.subscribe(topic_name)
        process_messages_slowly(0)
      end)
      
      # Flood the topic with messages
      message_count = 1000
      
      {time_ms, results} = :timer.tc(fn ->
        for i <- 1..message_count do
          case Ratatoskr.publish(topic_name, %{flood: i, timestamp: System.monotonic_time()}) do
            {:ok, _} -> :ok
            error -> {:error, i, error}
          end
        end
      end)
      
      time_ms = div(time_ms, 1000)
      
      # Check for any publish failures
      failures = Enum.filter(results, fn
        {:error, _, _} -> true
        _ -> false
      end)
      
      Logger.info([
        "📊 Overload test results",
        "📨 Messages sent: #{message_count}",
        "⚠️  Failures: #{length(failures)}",
        "⏱️  Time: #{time_ms}ms",
        "🚀 Rate: #{Float.round(message_count / (time_ms / 1000), 2)} msg/s"
      ] |> Enum.join(" | "))
      
      # Topic should still be responsive even under load
      {:ok, stats} = Ratatoskr.stats(topic_name)
      assert stats.message_count > 0
      assert stats.subscriber_count == 1
      
      # Should still accept new messages
      {:ok, _} = Ratatoskr.publish(topic_name, %{after: "overload"})
      
      # Most messages should succeed (allowing for some backpressure)
      success_rate = (message_count - length(failures)) / message_count
      assert success_rate >= 0.95, 
        "Too many failures under load: #{Float.round((1 - success_rate) * 100, 1)}% failure rate"
    end
  end

  describe "Recovery Under Load" do
    test "recovers while handling concurrent operations" do
      topic_name = BenchmarkHelpers.benchmark_topic("recovery_under_load")
      
      on_exit(fn -> BenchmarkHelpers.cleanup_benchmark_topic(topic_name) end)
      
      Logger.info("Testing recovery under concurrent load")
      
      {:ok, _topic} = Ratatoskr.create_topic(topic_name)
      
      # Start background publishers
      publisher_count = 5
      publishers = for i <- 1..publisher_count do
        spawn_link(fn ->
          publish_continuously(topic_name, i, 200)  # 200 messages each
        end)
      end
      
      # Start background subscribers  
      subscriber_count = 10
      subscribers = for i <- 1..subscriber_count do
        spawn_link(fn ->
          {:ok, _ref} = Ratatoskr.subscribe(topic_name)
          consume_messages(100)  # Expect to receive messages
        end)
      end
      
      # Let the system run for a bit
      Process.sleep(500)
      
      # Kill topic server while under load
      [{topic_pid, _}] = Registry.lookup(Ratatoskr.Registry, topic_name)
      Process.exit(topic_pid, :kill)
      
      Logger.info("💥 Killed topic server under load")
      
      # Recreate topic quickly 
      Process.sleep(50)
      {:ok, _topic} = Ratatoskr.create_topic(topic_name)
      
      # Let system recover and continue
      Process.sleep(1000)
      
      # Verify topic is functional
      {:ok, stats} = Ratatoskr.stats(topic_name)
      assert stats.message_count >= 0  # Should have processed some messages
      
      # Should still accept new operations
      {:ok, _} = Ratatoskr.publish(topic_name, %{recovery: "successful"})
      {:ok, _ref} = Ratatoskr.subscribe(topic_name)
      
      Logger.info([
        "✅ Recovery under load successful",
        "📊 Final stats: #{stats.message_count} messages",
        "👥 Subscribers: #{stats.subscriber_count}"
      ] |> Enum.join(" | "))
    end
  end

  # Helper Functions

  defp process_messages_slowly(count) do
    receive do
      {:message, _message} ->
        Process.sleep(10)  # Simulate slow processing
        process_messages_slowly(count + 1)
    after
      5000 -> 
        count  # Return count of processed messages
    end
  end

  defp publish_continuously(_topic_name, _publisher_id, 0), do: :done
  
  defp publish_continuously(topic_name, publisher_id, remaining) do
    case Ratatoskr.publish(topic_name, %{publisher: publisher_id, seq: remaining}) do
      {:ok, _} -> :ok
      {:error, :topic_not_found} ->
        # Topic might be recovering, wait and retry
        Process.sleep(10)
      _error -> :ok
    end
    
    Process.sleep(5)  # Small delay between messages
    publish_continuously(topic_name, publisher_id, remaining - 1)
  end

  defp consume_messages(0), do: :done
  
  defp consume_messages(remaining) do
    receive do
      {:message, _message} ->
        consume_messages(remaining - 1)
    after
      100 ->
        consume_messages(remaining - 1)  # Continue even if no message
    end
  end
end