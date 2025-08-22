# Ratatoskr Message Broker Architecture

## Table of Contents
- [Overview](#overview)
- [Core Architectural Principles](#core-architectural-principles)
- [Message Flow Patterns](#message-flow-patterns)
- [Scalability Architecture](#scalability-architecture)
- [Clean Architecture Layers](#clean-architecture-layers)
- [Testing Architecture](#testing-architecture)
- [Performance & Observability](#performance--observability)
- [Configuration Architecture](#configuration-architecture)
- [Future-Proof Design](#future-proof-design)
- [Current Implementation Status](#current-implementation-status)

## Overview

Ratatoskr is designed as a high-performance, fault-tolerant message broker built on Elixir/OTP principles. This document outlines the architectural decisions, patterns, and future roadmap for building a production-ready messaging system.

### Design Goals
- **High Performance**: 10,000+ messages/second per node
- **Low Latency**: p99 < 10ms message delivery
- **Fault Tolerance**: Complete system recovery from any component failure
- **Scalability**: Horizontal scaling through clustering and partitioning
- **Developer Experience**: Clean APIs and comprehensive tooling

## Core Architectural Principles

### 1. Separation of Concerns

The system is divided into distinct, loosely-coupled layers:

```
┌─────────────────┐
│   Protocol      │  ← gRPC, HTTP, WebSocket handlers
│     Layer       │
├─────────────────┤
│   Application   │  ← Use cases, business workflows
│     Layer       │
├─────────────────┤
│   Domain        │  ← Core business logic (topics, messages)
│     Layer       │
├─────────────────┤
│ Infrastructure  │  ← Storage, networking, external services
│     Layer       │
└─────────────────┘
```

### 2. Fault Isolation Through OTP

```elixir
Ratatoskr.Application
├── Ratatoskr.Supervisor
    ├── Ratatoskr.Broker (singleton, manages topic lifecycle)
    ├── Ratatoskr.Topic.Supervisor (DynamicSupervisor)
    │   ├── TopicServer:topic_a (isolated process per topic)
    │   ├── TopicServer:topic_b (crash of one doesn't affect others)
    │   └── TopicServer:topic_c
    ├── Ratatoskr.Storage.Supervisor (future: persistence layer)
    ├── Ratatoskr.Network.Supervisor (protocol handlers)
    └── Registry (process discovery and routing)
```

**Key Benefits:**
- **Fault Isolation**: Topic crashes don't affect other topics
- **Graceful Degradation**: System remains partially functional during failures
- **Hot Restarts**: Failed components restart without system downtime
- **Backpressure**: Natural flow control through process mailboxes

### 3. Process-Per-Topic Model

Each topic runs in its own GenServer process:

```elixir
defmodule Ratatoskr.Topic.Server do
  use GenServer
  
  defstruct [
    :name,
    :messages,      # :queue.queue() - FIFO message buffer
    :subscribers,   # [pid()] - active subscriber processes
    :stats          # %{message_count: int, subscriber_count: int}
  ]
end
```

**Advantages:**
- Parallel processing of different topics
- Natural backpressure through mailbox size
- Easy to monitor and debug individual topics
- Fits OTP supervision model perfectly

## Message Flow Patterns

### Push Model (Current Implementation)

```
Publisher ──publish──> Topic Server ──direct──> Subscribers
                           │
                           ├──> Subscriber A
                           ├──> Subscriber B  
                           └──> Subscriber C
```

**How it works:**
1. Publisher sends message to topic server
2. Topic server immediately forwards to all active subscribers
3. Subscribers receive messages in their process mailboxes
4. Message delivery is fire-and-forget (at-most-once)

**Characteristics:**
- ✅ **Low Latency**: Direct delivery, no storage round-trip
- ✅ **Simple Implementation**: Minimal moving parts
- ✅ **Real-time**: Immediate message propagation
- ❌ **No Persistence**: Messages lost if no active subscribers
- ❌ **No Replay**: Can't recover missed messages
- ❌ **Limited Scalability**: All subscribers must keep up

**Best For:**
- Real-time notifications
- Event streaming
- Low-latency use cases
- MVP and prototyping

### Pull Model (Future Enhancement)

```
Publisher ──publish──> Topic Server ──persist──> Storage
                                                     ↑
Consumers ←──poll/ack── Topic Server ←──fetch/offset──┘
```

**How it works:**
1. Publisher sends message to topic server
2. Topic server persists message to storage with offset
3. Consumers poll topic server for new messages
4. Topic server fetches from storage based on consumer offset
5. Consumer acknowledges processing, advancing offset

**Characteristics:**
- ✅ **Durability**: Messages survive system restarts
- ✅ **Replay Capability**: Consumers can rewind to any offset
- ✅ **Scalability**: Consumers process at their own pace
- ✅ **Consumer Groups**: Load balancing across multiple consumers
- ❌ **Higher Latency**: Additional storage round-trip
- ❌ **Complexity**: Offset management, acknowledgments
- ❌ **Storage Requirements**: Persistent storage needed

**Best For:**
- Data processing pipelines
- Event sourcing
- Reliable message delivery
- High-throughput scenarios

### Hybrid Model (Future Advanced Feature)

```
Publisher ──> Topic Server ──┬──> Active Subscribers (push)
                              └──> Storage (pull backup)
```

Combines both approaches:
- Real-time delivery for active subscribers (push)
- Persistent storage for offline consumers (pull)
- Best of both worlds for different use cases

## Scalability Architecture

### 1. Horizontal Topic Partitioning

```elixir
# Partition topics by message key for load distribution
defmodule Ratatoskr.Partitioner do
  def route_message(topic, message_key, partition_count) do
    partition = :erlang.phash2(message_key, partition_count)
    topic_server = :"#{topic}_partition_#{partition}"
    
    case Registry.lookup(Ratatoskr.Registry, topic_server) do
      [{pid, _}] -> {:ok, pid}
      [] -> start_partition(topic_server)
    end
  end
end
```

### 2. Consumer Groups (Load Balancing)

```elixir
defmodule Ratatoskr.ConsumerGroup do
  defstruct [
    :group_id,
    :topic,
    :members,        # %{consumer_id => %{pid, partitions}}
    :partition_assignment  # %{partition => consumer_id}
  ]
  
  def join_group(group_id, consumer_id, consumer_pid)
  def assign_partitions(group_id)  # Rebalance on membership changes
  def handle_consumer_failure(group_id, consumer_id)
end
```

### 3. Multi-Node Clustering

```elixir
# Distributed topic registry across cluster nodes
defmodule Ratatoskr.Cluster do
  def create_topic(topic_name) do
    node = select_node_for_topic(topic_name)
    :rpc.call(node, Ratatoskr.Topic.Supervisor, :start_child, [topic_name])
  end
  
  defp select_node_for_topic(topic_name) do
    nodes = [Node.self() | Node.list()]
    index = :erlang.phash2(topic_name, length(nodes))
    Enum.at(nodes, index)
  end
end
```

## Clean Architecture Layers

### 1. Domain Layer (Core Business Logic)

```elixir
# Pure business logic, no dependencies
defmodule Ratatoskr.Core.Message do
  @type t :: %__MODULE__{
    id: binary(),
    topic: binary(),
    payload: term(),
    metadata: map(),
    timestamp: integer(),
    partition_key: binary() | nil
  }
  
  def new(payload, opts \\ []), do: ...
  def add_metadata(message, key, value), do: ...
end

defmodule Ratatoskr.Core.Topic do
  @type t :: %__MODULE__{
    name: binary(),
    partition_count: pos_integer(),
    retention_ms: pos_integer(),
    config: map()
  }
  
  def create(name, opts \\ []), do: ...
  def add_subscriber(topic, subscriber), do: ...
  def remove_subscriber(topic, subscriber), do: ...
end
```

### 2. Application Layer (Use Cases)

```elixir
# Orchestrates domain objects, handles business workflows
defmodule Ratatoskr.UseCases.PublishMessage do
  alias Ratatoskr.Core.{Message, Topic}
  
  def execute(topic_name, payload, opts \\ []) do
    with {:ok, topic} <- find_or_create_topic(topic_name),
         {:ok, message} <- Message.new(payload, opts),
         {:ok, message_id} <- route_and_publish(topic, message) do
      emit_telemetry(:publish_success, topic_name, message)
      {:ok, message_id}
    else
      error -> 
        emit_telemetry(:publish_error, topic_name, error)
        error
    end
  end
end

defmodule Ratatoskr.UseCases.SubscribeToTopic do
  def execute(topic_name, subscriber_pid, opts \\ []) do
    with {:ok, topic} <- ensure_topic_exists(topic_name),
         {:ok, subscription} <- create_subscription(topic, subscriber_pid, opts),
         :ok <- start_message_delivery(subscription) do
      {:ok, subscription.reference}
    end
  end
end
```

### 3. Infrastructure Layer (External Concerns)

```elixir
# Handles external dependencies and technical concerns
defmodule Ratatoskr.Infrastructure.Storage.Disk do
  @behaviour Ratatoskr.Core.Storage
  
  def persist_message(topic, message) do
    file_path = Path.join([storage_dir(), topic, "#{message.id}.msg"])
    File.write(file_path, :erlang.term_to_binary(message))
  end
  
  def load_messages(topic, offset, limit) do
    # Read from disk storage
  end
end

defmodule Ratatoskr.Infrastructure.Metrics.Prometheus do
  @behaviour Ratatoskr.Core.Metrics
  
  def increment_counter(name, value, labels) do
    :prometheus_counter.inc(name, labels, value)
  end
end
```

## Testing Architecture

### 1. Test Pyramid Structure

```
┌─────────────────────────────────────┐
│        E2E/Integration Tests        │  ← Full system scenarios
│     • gRPC protocol compliance      │
│     • Multi-node cluster tests      │
│     • Chaos/Recovery scenarios      │
├─────────────────────────────────────┤
│           Contract Tests            │  ← Interface compliance
│     • Storage adapter contracts     │
│     • Protocol handler contracts    │
│     • Plugin API contracts          │
├─────────────────────────────────────┤
│            Unit Tests               │  ← Business logic
│     • Message routing logic         │
│     • Topic lifecycle management    │
│     • Subscription handling         │
└─────────────────────────────────────┘
```

### 2. Property-Based Testing

```elixir
defmodule Ratatoskr.Properties do
  use ExUnitProperties
  
  property "messages maintain FIFO order per topic" do
    check all messages <- list_of(message_generator(), min_length: 1, max_length: 100) do
      topic = start_supervised_topic()
      subscriber = start_test_subscriber()
      
      subscribe(topic, subscriber)
      publish_messages(topic, messages)
      received = collect_messages(subscriber, length(messages))
      
      assert received == messages
    end
  end
  
  property "topic survives random subscriber failures" do
    check all {subscriber_count, failure_count} <- {pos_integer(), non_neg_integer()},
              subscriber_count >= 1,
              failure_count < subscriber_count do
      
      topic = start_supervised_topic()
      subscribers = start_subscribers(subscriber_count)
      
      # Random failures
      failing_subscribers = Enum.take_random(subscribers, failure_count)
      Enum.each(failing_subscribers, &Process.exit(&1, :kill))
      
      # Topic should still deliver to remaining subscribers
      remaining = subscribers -- failing_subscribers
      test_message_delivery(topic, remaining)
    end
  end
end
```

### 3. Test Utilities and Helpers

```elixir
defmodule Ratatoskr.TestHelpers do
  def start_supervised_topic(name \\ random_topic_name()) do
    {:ok, pid} = start_supervised({Ratatoskr.Topic.Server, name})
    {name, pid}
  end
  
  def publish_and_assert_delivery(topic, payload, expected_subscribers) do
    {:ok, msg_id} = Ratatoskr.publish(topic, payload)
    
    for subscriber <- expected_subscribers do
      assert_receive {:message, %{id: ^msg_id, payload: ^payload}}, 1000
    end
    
    msg_id
  end
  
  def chaos_test(scenario_fn, recovery_assertion) do
    initial_state = capture_system_state()
    
    try do
      scenario_fn.()
      Process.sleep(100)  # Allow recovery
      recovery_assertion.(initial_state)
    rescue
      error -> flunk("Chaos test failed: #{inspect(error)}")
    end
  end
end
```

## Performance & Observability

### 1. Telemetry Events

```elixir
defmodule Ratatoskr.Telemetry do
  @events [
    [:ratatoskr, :publish, :start],
    [:ratatoskr, :publish, :complete],
    [:ratatoskr, :publish, :error],
    [:ratatoskr, :subscribe, :start],
    [:ratatoskr, :subscribe, :complete],
    [:ratatoskr, :topic, :created],
    [:ratatoskr, :topic, :deleted],
    [:ratatoskr, :message, :delivered],
    [:ratatoskr, :subscriber, :failed]
  ]
  
  def emit_publish_metrics(topic, start_time, message_size) do
    duration = System.monotonic_time() - start_time
    
    :telemetry.execute(
      [:ratatoskr, :publish, :complete],
      %{duration: duration, message_size: message_size},
      %{topic: topic}
    )
  end
end
```

### 2. Health Check System

```elixir
defmodule Ratatoskr.Health do
  def system_health do
    %{
      status: overall_status(),
      uptime: get_uptime(),
      broker: broker_health(),
      topics: topic_health(),
      cluster: cluster_health(),
      resources: resource_health()
    }
  end
  
  defp broker_health do
    %{
      alive: Process.alive?(Process.whereis(Ratatoskr.Broker)),
      topic_count: count_active_topics(),
      total_subscribers: count_total_subscribers(),
      message_rate: calculate_message_rate(),
      error_rate: calculate_error_rate()
    }
  end
  
  defp resource_health do
    %{
      memory_usage: get_memory_percentage(),
      process_count: length(Process.list()),
      message_queue_lengths: get_mailbox_sizes(),
      disk_usage: get_disk_usage()
    }
  end
end
```

### 3. Performance Monitoring

```elixir
defmodule Ratatoskr.Metrics.Collector do
  use GenServer
  
  # Collect metrics every 5 seconds
  @collect_interval 5_000
  
  def init(_) do
    schedule_collection()
    {:ok, %{metrics: %{}, history: []}}
  end
  
  def handle_info(:collect, state) do
    current_metrics = %{
      timestamp: System.system_time(:millisecond),
      topics: count_topics(),
      subscribers: count_subscribers(),
      messages_per_second: calculate_message_rate(),
      memory_mb: get_memory_usage_mb(),
      process_count: length(Process.list())
    }
    
    # Store history for trend analysis
    history = [current_metrics | state.history] |> Enum.take(720)  # 1 hour of data
    
    schedule_collection()
    {:noreply, %{state | metrics: current_metrics, history: history}}
  end
end
```

## Configuration Architecture

### 1. Environment-Based Configuration

```elixir
# config/config.exs
config :ratatoskr,
  # Core settings
  max_topics: {:system, :integer, "RATATOSKR_MAX_TOPICS", 1000},
  max_subscribers_per_topic: {:system, :integer, "MAX_SUBSCRIBERS", 10000},
  message_retention_ms: {:system, :integer, "RETENTION_MS", 3_600_000},
  
  # Performance tuning
  topic_buffer_size: {:system, :integer, "TOPIC_BUFFER_SIZE", 1000},
  subscriber_timeout_ms: {:system, :integer, "SUBSCRIBER_TIMEOUT", 5000},
  
  # Storage configuration
  storage_adapter: Ratatoskr.Storage.ETS,  # or .Disk, .Redis
  storage_path: {:system, "STORAGE_PATH", "./data"},
  
  # Network configuration
  grpc_port: {:system, :integer, "GRPC_PORT", 9090},
  http_port: {:system, :integer, "HTTP_PORT", 8080},
  
  # Clustering
  cluster_nodes: {:system, :list, "CLUSTER_NODES", []},
  node_discovery: :dns  # or :static, :kubernetes
```

### 2. Runtime Configuration Updates

```elixir
defmodule Ratatoskr.Config do
  def update_topic_config(topic, config_changes) do
    GenServer.call({:via, Registry, {Ratatoskr.Registry, topic}}, 
                  {:update_config, config_changes})
  end
  
  def update_global_config(key, value) do
    Application.put_env(:ratatoskr, key, value)
    broadcast_config_change(key, value)
  end
  
  def get_topic_config(topic) do
    default_config = Application.get_env(:ratatoskr, :topic_defaults, %{})
    topic_specific = get_topic_specific_config(topic)
    Map.merge(default_config, topic_specific)
  end
end
```

## Future-Proof Design

### 1. Plugin Architecture

```elixir
defmodule Ratatoskr.Plugin do
  @callback on_message_published(topic :: binary(), message :: Message.t()) :: :ok
  @callback on_subscriber_joined(topic :: binary(), subscriber :: pid()) :: :ok
  @callback on_subscriber_left(topic :: binary(), subscriber :: pid()) :: :ok
  @callback on_topic_created(topic :: binary()) :: :ok
  @callback on_topic_deleted(topic :: binary()) :: :ok
end

# Example implementations:
defmodule Ratatoskr.Plugins.Metrics do
  @behaviour Ratatoskr.Plugin
  
  def on_message_published(topic, message) do
    :telemetry.execute([:ratatoskr, :message, :published], 
                      %{size: byte_size(message.payload)}, 
                      %{topic: topic})
  end
end

defmodule Ratatoskr.Plugins.Audit do
  @behaviour Ratatoskr.Plugin
  
  def on_message_published(topic, message) do
    Logger.info("Message published", topic: topic, message_id: message.id)
  end
end
```

### 2. Protocol Abstraction

```elixir
defmodule Ratatoskr.Protocol do
  @callback handle_publish(request :: term()) :: {:ok, response :: term()} | {:error, reason :: term()}
  @callback handle_subscribe(request :: term(), stream :: term()) :: :ok | {:error, reason :: term()}
  @callback handle_unsubscribe(request :: term()) :: {:ok, response :: term()} | {:error, reason :: term()}
end

# Protocol implementations:
defmodule Ratatoskr.Protocols.Grpc do
  @behaviour Ratatoskr.Protocol
  # Current implementation
end

defmodule Ratatoskr.Protocols.Http do
  @behaviour Ratatoskr.Protocol
  # RESTful HTTP API
end

defmodule Ratatoskr.Protocols.WebSocket do
  @behaviour Ratatoskr.Protocol
  # Real-time web connections
end
```

### 3. Storage Abstraction

```elixir
defmodule Ratatoskr.Storage do
  @callback persist_message(topic :: binary(), message :: Message.t()) :: 
    {:ok, offset :: integer()} | {:error, reason :: term()}
    
  @callback load_messages(topic :: binary(), offset :: integer(), limit :: integer()) :: 
    {:ok, [Message.t()]} | {:error, reason :: term()}
    
  @callback delete_messages(topic :: binary(), before_offset :: integer()) :: 
    :ok | {:error, reason :: term()}
end

# Storage implementations:
defmodule Ratatoskr.Storage.ETS do
  @behaviour Ratatoskr.Storage
  # Current in-memory implementation
end

defmodule Ratatoskr.Storage.Disk do
  @behaviour Ratatoskr.Storage
  # File-based persistence
end

defmodule Ratatoskr.Storage.Redis do
  @behaviour Ratatoskr.Storage
  # Redis-based storage
end
```

## Current Implementation Status

### ✅ Completed (Milestone 1)
- [x] Basic OTP supervision tree
- [x] Topic management (create/delete/list)
- [x] In-memory message queuing
- [x] Publish/subscribe API
- [x] gRPC protocol support
- [x] Process-per-topic isolation
- [x] Registry-based service discovery
- [x] Comprehensive test suite (82% coverage)
- [x] Performance benchmarks

### 🚧 In Progress
- [ ] Documentation and architecture guides
- [ ] Enhanced error handling and recovery
- [ ] Performance optimization

### 📅 Planned (Future Milestones)

**Milestone 2: Persistence & Durability**
- [ ] Storage abstraction layer
- [ ] Disk-based message persistence
- [ ] Message retention policies
- [ ] Crash recovery from storage

**Milestone 3: Advanced Features**
- [ ] Consumer groups and load balancing
- [ ] Topic partitioning
- [ ] Message ordering guarantees
- [ ] Dead letter queues

**Milestone 4: Scale & Operations**
- [ ] Multi-node clustering
- [ ] Admin API and dashboard
- [ ] Comprehensive monitoring
- [ ] Performance tuning tools

**Milestone 5: Enterprise Features**
- [ ] Authentication and authorization
- [ ] Message encryption
- [ ] Audit logging
- [ ] Multi-tenancy support

The architecture is designed to evolve incrementally while maintaining backward compatibility and system stability at each milestone.