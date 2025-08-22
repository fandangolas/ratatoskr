defmodule Ratatoskr.Core.SubscriptionTest do
  use ExUnit.Case, async: true
  alias Ratatoskr.Core.Logic.{Subscription, Message}

  describe "Subscription.new/3" do
    test "creates a valid subscription with default options" do
      assert {:ok, subscription} = Subscription.new("orders", self())

      assert subscription.topic == "orders"
      assert subscription.subscriber_pid == self()
      assert is_reference(subscription.id)
      assert match?(%DateTime{}, subscription.created_at)
      assert subscription.status == :active
      assert subscription.options == []
    end

    test "creates subscription with custom options" do
      opts = [filter: %{type: "urgent"}, batch_size: 10]
      assert {:ok, subscription} = Subscription.new("events", self(), opts)

      assert subscription.topic == "events"
      assert subscription.options == opts
    end

    test "validates topic name" do
      assert {:error, :invalid_topic} = Subscription.new("", self())
      assert {:error, :invalid_topic} = Subscription.new(123, self())
    end

    test "validates subscriber PID" do
      assert {:error, :invalid_subscriber} = Subscription.new("test", "not_a_pid")
      assert {:error, :invalid_subscriber} = Subscription.new("test", nil)
    end
  end

  describe "Subscription.active?/1" do
    test "returns true for active subscriptions" do
      {:ok, subscription} = Subscription.new("test", self())
      assert Subscription.active?(subscription)
    end

    test "returns false for inactive subscriptions" do
      {:ok, subscription} = Subscription.new("test", self())
      inactive = %{subscription | status: :cancelled}
      refute Subscription.active?(inactive)

      paused = %{subscription | status: :paused}
      refute Subscription.active?(paused)
    end
  end

  describe "Subscription.cancel/1" do
    test "cancels an active subscription" do
      {:ok, subscription} = Subscription.new("test", self())
      cancelled = Subscription.cancel(subscription)

      assert cancelled.status == :cancelled
      refute Subscription.active?(cancelled)
    end

    test "can cancel already cancelled subscription" do
      {:ok, subscription} = Subscription.new("test", self())
      cancelled = Subscription.cancel(subscription)
      double_cancelled = Subscription.cancel(cancelled)

      assert double_cancelled.status == :cancelled
    end
  end

  describe "Subscription.pause/1 and resume/1" do
    test "pauses and resumes subscriptions" do
      {:ok, subscription} = Subscription.new("test", self())

      paused = Subscription.pause(subscription)
      assert paused.status == :paused
      refute Subscription.active?(paused)

      resumed = Subscription.resume(paused)
      assert resumed.status == :active
      assert Subscription.active?(resumed)
    end
  end

  describe "Subscription.should_deliver?/2" do
    setup do
      {:ok, subscription} = Subscription.new("test", self())
      {:ok, message} = Message.new("test", %{type: "order", priority: "high"})

      %{subscription: subscription, message: message}
    end

    test "delivers to active subscriptions without filters", %{
      subscription: subscription,
      message: message
    } do
      assert Subscription.should_deliver?(subscription, message)
    end

    test "does not deliver to inactive subscriptions", %{
      subscription: subscription,
      message: message
    } do
      cancelled = Subscription.cancel(subscription)
      refute Subscription.should_deliver?(cancelled, message)

      paused = Subscription.pause(subscription)
      refute Subscription.should_deliver?(paused, message)
    end

    test "applies message filters when present", %{subscription: subscription} do
      # Subscription with filter
      filtered_sub = %{subscription | options: [filter: %{type: "order"}]}

      # Message that matches filter
      {:ok, matching_msg} = Message.new("test", %{type: "order", id: 123})
      assert Subscription.should_deliver?(filtered_sub, matching_msg)

      # Message that doesn't match filter
      {:ok, non_matching_msg} = Message.new("test", %{type: "user", id: 456})
      refute Subscription.should_deliver?(filtered_sub, non_matching_msg)
    end

    test "handles complex filter conditions", %{subscription: subscription} do
      # Multiple filter conditions
      complex_filter = %{type: "order", priority: "high"}
      filtered_sub = %{subscription | options: [filter: complex_filter]}

      # Message matching all conditions
      {:ok, matching_msg} = Message.new("test", %{type: "order", priority: "high", id: 1})
      assert Subscription.should_deliver?(filtered_sub, matching_msg)

      # Message matching some conditions
      {:ok, partial_msg} = Message.new("test", %{type: "order", priority: "low", id: 2})
      refute Subscription.should_deliver?(filtered_sub, partial_msg)
    end
  end

  describe "Reference serialization" do
    test "serializes and deserializes references for gRPC transport" do
      {:ok, subscription} = Subscription.new("test", self())

      serialized = Subscription.serialize_reference(subscription.id)
      assert is_binary(serialized)

      deserialized = Subscription.deserialize_reference(serialized)
      assert deserialized == subscription.id
    end

    test "handles invalid serialized references" do
      assert_raise ArgumentError, fn ->
        Subscription.deserialize_reference("invalid_reference")
      end

      assert_raise ArgumentError, fn ->
        Subscription.deserialize_reference("")
      end
    end

    test "round-trip serialization preserves reference" do
      {:ok, sub1} = Subscription.new("test", self())
      {:ok, sub2} = Subscription.new("test", self())

      # Serialize both references
      serialized1 = Subscription.serialize_reference(sub1.id)
      serialized2 = Subscription.serialize_reference(sub2.id)

      # They should be different
      assert serialized1 != serialized2

      # Deserialize and verify they match originals
      assert Subscription.deserialize_reference(serialized1) == sub1.id
      assert Subscription.deserialize_reference(serialized2) == sub2.id
    end
  end

  describe "Subscription validation" do
    test "valid?/1 validates well-formed subscriptions" do
      {:ok, subscription} = Subscription.new("valid_topic", self())
      assert Subscription.valid?(subscription)
    end

    test "valid?/1 detects invalid subscriptions" do
      {:ok, valid_subscription} = Subscription.new("valid", self())

      # Invalid topic
      invalid_topic = %{valid_subscription | topic: ""}
      refute Subscription.valid?(invalid_topic)

      # Invalid subscriber_pid
      invalid_pid = %{valid_subscription | subscriber_pid: "not_a_pid"}
      refute Subscription.valid?(invalid_pid)

      # Invalid status
      invalid_status = %{valid_subscription | status: :unknown}
      refute Subscription.valid?(invalid_status)
    end
  end

  describe "Subscription lifecycle" do
    test "tracks subscription creation time" do
      {:ok, subscription} = Subscription.new("test", self())

      assert match?(%DateTime{}, subscription.created_at)

      # Creation time should be recent (within last second)
      now = DateTime.utc_now()
      diff = DateTime.diff(now, subscription.created_at, :millisecond)
      assert diff < 1000
    end

    test "generates unique subscription IDs" do
      {:ok, sub1} = Subscription.new("test", self())
      {:ok, sub2} = Subscription.new("test", self())
      {:ok, sub3} = Subscription.new("different", self())

      assert sub1.id != sub2.id
      assert sub1.id != sub3.id
      assert sub2.id != sub3.id
    end
  end
end
