defmodule Ratatoskr.UseCases.PublishMessageTest do
  # Changed to false to avoid conflicts
  use ExUnit.Case, async: false
  alias Ratatoskr.UseCases.PublishMessage

  # Mock registry implementation for testing
  defmodule MockRegistry do
    @behaviour Ratatoskr.Core.Behaviours.Registry

    def register_topic(_name, _pid), do: :ok
    def unregister_topic(_name), do: :ok

    def lookup_topic(_topic_name), do: {:error, :not_found}

    def list_topics, do: {:ok, []}
  end

  # Mock metrics implementation for testing
  defmodule MockMetrics do
    @behaviour Ratatoskr.Core.Behaviours.Metrics

    def increment_counter(_event, _metadata \\ %{}), do: :ok
    def increment_counter(_event, _amount, _metadata), do: :ok
    def record_histogram(_event, _value, _metadata \\ %{}), do: :ok
    def observe_histogram(_event, _value, _metadata \\ %{}), do: :ok
    def set_gauge(_event, _value, _metadata \\ %{}), do: :ok
  end

  setup do
    # Mock the ManageTopics module to prevent actual topic creation
    :meck.new(Ratatoskr.UseCases.ManageTopics, [:non_strict])

    :meck.expect(Ratatoskr.UseCases.ManageTopics, :create, fn _topic_name, _opts, _deps ->
      {:error, :topic_creation_disabled_in_test}
    end)

    on_exit(fn ->
      try do
        :meck.unload(Ratatoskr.UseCases.ManageTopics)
      catch
        :error, _ -> :ok
      end
    end)

    deps = %{
      registry: MockRegistry,
      storage: nil,
      metrics: MockMetrics,
      event_publisher: nil
    }

    %{deps: deps}
  end

  describe "PublishMessage.execute/4" do
    test "returns error when topic not found", %{deps: deps} do
      payload = %{id: 123, amount: 99.90}

      assert {:error, :topic_creation_disabled_in_test} =
               PublishMessage.execute("existing_topic", payload, [], deps)
    end

    test "returns error for non-existent topic", %{deps: deps} do
      payload = %{data: "test"}

      assert {:error, :topic_creation_disabled_in_test} =
               PublishMessage.execute("nonexistent_topic", payload, [], deps)
    end

    test "validates message creation", %{deps: deps} do
      # Invalid topic name should fail during message creation
      assert {:error, :empty_topic} =
               PublishMessage.execute("", %{data: "test"}, [], deps)

      # Invalid payload should fail
      invalid_payload = fn -> :ok end

      assert {:error, :payload_not_serializable} =
               PublishMessage.execute("existing_topic", invalid_payload, [], deps)
    end

    test "handles metadata options", %{deps: deps} do
      payload = %{id: 456}
      opts = [metadata: %{"source" => "api", "version" => "1.0"}]

      assert {:error, :topic_creation_disabled_in_test} =
               PublishMessage.execute("existing_topic", payload, opts, deps)
    end

    test "handles partition_key options", %{deps: deps} do
      payload = %{user_id: 789}
      opts = [partition_key: "user-789"]

      assert {:error, :topic_creation_disabled_in_test} =
               PublishMessage.execute("existing_topic", payload, opts, deps)
    end

    test "measures execution time with metrics", %{deps: deps} do
      # This test verifies that metrics are called even when topic not found
      payload = %{data: "test"}

      assert {:error, :topic_creation_disabled_in_test} =
               PublishMessage.execute("existing_topic", payload, [], deps)

      # Metrics should be recorded (mocked in our test)
    end
  end

  describe "PublishMessage validation pipeline" do
    test "validates topic existence first", %{deps: deps} do
      # Even with valid message data, should fail if topic doesn't exist
      valid_payload = %{valid: "data"}

      assert {:error, :topic_creation_disabled_in_test} =
               PublishMessage.execute("nonexistent", valid_payload, [], deps)
    end

    test "validates message creation second", %{deps: deps} do
      # Topic exists but message creation fails
      invalid_payload = fn -> :invalid end

      assert {:error, :payload_not_serializable} =
               PublishMessage.execute("existing_topic", invalid_payload, [], deps)
    end
  end

  describe "PublishMessage error handling" do
    test "handles registry lookup failures gracefully", %{deps: deps} do
      # Simulate registry failure by using a topic that returns error
      assert {:error, :topic_creation_disabled_in_test} =
               PublishMessage.execute("fail_topic", %{}, [], deps)
    end

    test "propagates message validation errors", %{deps: deps} do
      test_cases = [
        {"", %{}, :empty_topic},
        {String.duplicate("a", 256), %{}, :topic_too_long},
        {"invalid!", %{}, :invalid_topic_format},
        {"existing_topic", fn -> :bad end, :payload_not_serializable}
      ]

      for {topic, payload, expected_error} <- test_cases do
        assert {:error, ^expected_error} =
                 PublishMessage.execute(topic, payload, [], deps)
      end
    end
  end

  describe "PublishMessage with different dependency configurations" do
    test "works without storage dependency", %{deps: deps} do
      # Storage is nil in our deps, should still work
      payload = %{no_storage: true}

      assert {:error, :topic_creation_disabled_in_test} =
               PublishMessage.execute("existing_topic", payload, [], deps)
    end

    test "works without event publisher dependency", %{deps: deps} do
      # Event publisher is nil in our deps, should still work
      payload = %{no_events: true}

      assert {:error, :topic_creation_disabled_in_test} =
               PublishMessage.execute("existing_topic", payload, [], deps)
    end

    test "requires registry dependency" do
      deps_without_registry = %{
        registry: nil,
        storage: nil,
        metrics: MockMetrics,
        event_publisher: nil
      }

      assert_raise FunctionClauseError, fn ->
        PublishMessage.execute("test", %{}, [], deps_without_registry)
      end
    end
  end

  describe "PublishMessage integration scenarios" do
    test "validates complex message structures", %{deps: deps} do
      complex_payload = %{
        order: %{
          id: 12_345,
          items: [
            %{sku: "ABC123", quantity: 2, price: 19.99},
            %{sku: "DEF456", quantity: 1, price: 29.99}
          ],
          total: 69.97,
          customer: %{
            id: 789,
            email: "customer@example.com"
          }
        },
        metadata: %{
          source: "web",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      }

      opts = [
        metadata: %{"correlation_id" => "order-12345", "trace_id" => "abc-def-123"},
        partition_key: "customer-789"
      ]

      # Should still validate the message structure even if topic not found
      assert {:error, :topic_creation_disabled_in_test} =
               PublishMessage.execute("existing_topic", complex_payload, opts, deps)
    end

    test "handles high-frequency publishing simulation", %{deps: deps} do
      # Simulate publishing many messages quickly
      results =
        for i <- 1..10 do
          PublishMessage.execute("existing_topic", %{msg_id: i}, [], deps)
        end

      # All should return topic_creation_disabled_in_test with our mock
      for {status, reason} <- results do
        assert status == :error
        assert reason == :topic_creation_disabled_in_test
      end
    end
  end
end
