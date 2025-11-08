# Ratatoskr Architecture

## 🎯 Project Vision

**Ratatoskr** is a lightweight message broker inspired by Apache Kafka, built entirely in Elixir/OTP. Named after the Norse mythology squirrel who carries messages between the realms of Yggdrasil, Ratatoskr aims to demonstrate how Elixir's powerful concurrency primitives can be leveraged to build distributed systems.

### Purpose

1. **Educational**: Showcase how to build a message broker using Elixir/OTP best practices
3. **Demonstrative**: Illustrate the power of GenServers, supervision trees, ETS, and the Actor model
4. **Performant**: Achieve high throughput and low latency using Elixir's strengths

### Non-Goals (For Initial Version)

- ❌ Replace Apache Kafka in production enterprise environments
- ❌ Multi-node clustering (initially)
- ❌ Complex replication strategies
- ❌ ZooKeeper-like coordination

---

## 🏗️ Core Concepts

### Messages
- **Immutable**: Once published, messages cannot be changed
- **Ordered**: Messages within a partition maintain strict FIFO order
- **Persistent**: Messages are stored until retention policy expires (later phase)
- **Structure**: `{id, topic, partition, key, value, timestamp, headers}`

### Topics
- **Logical channels**: Named streams of messages (e.g., "user-events", "orders")
- **Partitioned**: Each topic has 1-N partitions for parallelism
- **Independent**: Topics are isolated; failure in one doesn't affect others

### Partitions
- **Ordered logs**: Append-only sequence of messages
- **Parallelism unit**: Different partitions can be consumed independently
- **Key-based routing**: Messages with the same key go to the same partition
f
### Producers
- **Publishers**: Clients that send messages to topics
- **Synchronous/Asynchronous**: Can wait for acknowledgment or fire-and-forget
- **Batching**: Can batch multiple messages for efficiency

### Consumers
- **Subscribers**: Clients that read messages from topics
- **Consumer Groups**: Multiple consumers can share the load (future phase)
- **Offset tracking**: Track position in the partition log

---

## 🔧 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Ratatoskr.Application                     │
│                     (OTP Application)                        │
└────────────────────────┬────────────────────────────────────┘
                         │
        ┌────────────────┼────────────────┐
        │                │                │
        ▼                ▼                ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│   Registry   │  │    Broker    │  │   Topic      │
│  (Built-in)  │  │ (Coordinator)│  │  Supervisor  │
└──────────────┘  └──────────────┘  │ (Dynamic)    │
                                    └──────┬───────┘
                                           │
                              ┌────────────┼────────────┐
                              │            │            │
                              ▼            ▼            ▼
                         ┌────────┐   ┌────────┐   ┌────────┐
                         │ Topic  │   │ Topic  │   │ Topic  │
                         │Server 1│   │Server 2│   │Server N│
                         └───┬────┘   └───┬────┘   └───┬────┘
                             │            │            │
                    ┌────────┼────┐  ┌───┼────┐  ┌───┼────┐
                    │        │    │  │   │    │  │   │    │
                    ▼        ▼    ▼  ▼   ▼    ▼  ▼   ▼    ▼
                  Part 0  Part 1 ... Partitions  ... Partitions
                (GenSrvr)(GenSrvr)   (GenServers)   (GenServers)
```

---

## 📦 Component Design

### 1. Application Supervisor (`Ratatoskr.Application`)
**Responsibility**: Root supervisor managing the entire application

```elixir
children = [
  {Registry, keys: :unique, name: Ratatoskr.Registry},
  Ratatoskr.Broker,
  {DynamicSupervisor, name: Ratatoskr.Topic.Supervisor, strategy: :one_for_one}
]
```

**Supervision Strategy**: `:one_for_one`
- If Registry crashes, restart only Registry
- If Broker crashes, restart only Broker
- If Topic Supervisor crashes, restart only Topic Supervisor

---

### 2. Registry (`Ratatoskr.Registry`)
**Responsibility**: Process discovery for topics and partitions

**Why Built-in Registry?**
- Fast lookups (ETS-based)
- No external dependencies
- Built-in to Elixir
- Handles duplicate registrations gracefully

**Registered Processes**:
- Topic servers: `{Ratatoskr.Registry, {:topic, "topic-name"}}`
- Partition servers: `{Ratatoskr.Registry, {:partition, "topic-name", 0}}`

---

### 3. Broker (`Ratatoskr.Broker`)
**Responsibility**: API coordinator and topic lifecycle manager

**State**:
```elixir
%{
  topics: %{
    "orders" => %{partition_count: 3, config: %{}},
    "users" => %{partition_count: 1, config: %{}}
  }
}
```

**API**:
- `create_topic(name, partition_count, config)` → Creates topic with N partitions
- `delete_topic(name)` → Stops topic supervisor and all partitions
- `list_topics()` → Returns all active topics
- `get_topic_info(name)` → Returns metadata about topic

**Implementation**: GenServer
- Maintains metadata about topics
- Delegates actual message handling to Topic servers
- Handles topic creation/deletion atomically

---

### 4. Topic Supervisor (`Ratatoskr.Topic.Supervisor`)
**Responsibility**: Dynamically manage topic server processes

**Type**: `DynamicSupervisor`

**Why DynamicSupervisor?**
- Topics are created at runtime, not at startup
- Each topic can have different numbers of partitions
- Easy to add/remove topics without restarting app

**Children**: Topic.Server instances (one per topic)

---

### 5. Topic Server (`Ratatoskr.Topic.Server`)
**Responsibility**: Manage a single topic and its partitions

**State**:
```elixir
%{
  name: "orders",
  partition_count: 3,
  partitions: [pid1, pid2, pid3],
  config: %{retention_ms: 86400000}
}
```

**API**:
- `publish(message)` → Routes to appropriate partition
- `subscribe(partition_id, consumer_pid)` → Subscribe to partition
- `get_stats()` → Return topic statistics

**Partition Routing**:
- If message has `key`: `hash(key) % partition_count`
- If no key: Round-robin across partitions

**Implementation**: GenServer
- Manages child partition processes
- Routes messages to correct partition
- Aggregates stats from all partitions

---

### 6. Partition Server (`Ratatoskr.Partition.Server`)
**Responsibility**: Store and serve messages for a single partition

**State**:
```elixir
%{
  topic: "orders",
  partition_id: 0,
  messages: :queue.queue(),  # Erlang queue for FIFO
  subscribers: [{pid, offset}],
  next_offset: 42,
  storage: :memory  # or :disk in future
}
```

**API**:
- `append(message)` → Add message to log
- `read(offset, count)` → Read messages from offset
- `subscribe(consumer_pid, offset)` → Register consumer
- `unsubscribe(consumer_pid)` → Remove consumer

**Message Delivery**:
```elixir
# When new message arrives:
1. Append to queue
2. Assign offset (auto-incrementing)
3. Notify all subscribers (push model)
4. Store in ETS for fast random access
```

**Implementation**: GenServer
- Uses `:queue` for append-only log
- Uses ETS table for fast offset-based lookups
- Pushes messages to subscribers immediately

---

### 7. Consumer (`Ratatoskr.Consumer`)
**Responsibility**: Client API for consuming messages

**Modes**:
1. **Callback mode**: `subscribe(topic, partition, callback_fn)`
2. **Pull mode**: `poll(topic, partition, offset, count)` (future)

**Example**:
```elixir
{:ok, subscription_id} = Ratatoskr.subscribe("orders", 0, fn message ->
  IO.inspect(message)
  :ack  # or :nack for retry (future)
end)
```

**Implementation**: Lightweight wrapper
- Registers with partition server
- Receives messages via `handle_info/2`
- Executes callback function

---

### 8. Producer (`Ratatoskr.Producer`)
**Responsibility**: Client API for publishing messages

**API**:
```elixir
# Simple publish
{:ok, offset} = Ratatoskr.publish("orders", %{id: 123, amount: 99.99})

# With key (for partitioning)
{:ok, offset} = Ratatoskr.publish("orders", "user-123", %{id: 123, amount: 99.99})

# Batch publish
{:ok, offsets} = Ratatoskr.publish_batch("orders", [msg1, msg2, msg3])
```

**Implementation**: Wrapper functions
- Resolves topic via Registry
- Delegates to Topic.Server
- Returns acknowledgment with offset

---

## 🗄️ Data Storage

### Phase 1: In-Memory (ETS)
```elixir
# Per partition ETS table
:ets.new(:partition_0_messages, [
  :ordered_set,
  :public,
  :named_table,
  read_concurrency: true
])

# Store format: {offset, message}
:ets.insert(:partition_0_messages, {0, %Message{}})
```

**Advantages**:
- Extremely fast reads/writes
- Simple implementation
- Perfect for MVP

**Limitations**:
- Lost on crash (until Phase 2: persistence)
- Memory constraints

### Phase 2: Disk Persistence (Future)
- Append-only log files per partition
- Periodic compaction
- Write-ahead logging (WAL)
- Index files for fast offset lookup

---

## ⚡ Performance Characteristics

### Target Metrics (Single Node)

| Metric | Target | Rationale |
|--------|--------|-----------|
| Throughput | 10,000+ msg/s | Sufficient for most small-medium apps |
| Latency (P99) | < 10ms | Fast enough for real-time use cases |
| Concurrent Consumers | 100+ per partition | Support many microservices |
| Message Size | Up to 1MB | Standard Kafka default |
| Memory per Partition | ~10MB baseline | ETS overhead + message buffer |

### Optimization Strategies

1. **ETS for Storage**: Fast in-memory operations
2. **Erlang `:queue`**: Efficient FIFO structure
3. **Minimal Copying**: Pass references where possible
4. **Batching**: Batch message notifications to subscribers
5. **GenServer Call vs Cast**: Use `cast` for fire-and-forget, `call` for acks

---

## 🧪 Testing Strategy

### Unit Tests
- Each GenServer module tested independently
- Mock dependencies using Mox
- Property-based testing with StreamData
- Target: >90% code coverage

### Integration Tests
- Full publish-subscribe flow
- Multi-topic scenarios
- Crash recovery (supervisor restart)
- Concurrent producer/consumer tests

### Performance Tests
- Benchmark suite using Benchee
- Load tests with thousands of messages
- Measure latency percentiles (P50, P95, P99)
- Memory profiling with `:observer`

### Chaos Tests (Future)
- Random process crashes
- Network partition simulation
- Resource exhaustion scenarios

---

## 📋 Implementation Phases

### Phase 1: Core Engine (MVP) ✅
**Goal**: Basic in-memory message broker

- [x] Project setup with supervision tree
- [ ] Broker GenServer (topic management)
- [ ] Topic.Server (routing logic)
- [ ] Partition.Server (message storage + delivery)
- [ ] Simple Producer API
- [ ] Simple Consumer API (callback mode)
- [ ] Basic tests
- [ ] Performance benchmarks

**Success Criteria**:
- Can create/delete topics
- Can publish 10,000 msg/s to single topic
- Can support 100 concurrent consumers
- Messages delivered in order
- Tests pass with >80% coverage

---

### Phase 2: Persistence
**Goal**: Durable message storage

- [ ] Append-only log files per partition
- [ ] Write-ahead logging (WAL)
- [ ] Periodic snapshots
- [ ] Recovery on crash
- [ ] Configurable retention policies

**Success Criteria**:
- Messages survive broker restart
- Minimal performance degradation (<20%)
- Configurable retention (time/size based)

---

### Phase 3: Advanced Features
**Goal**: Production-ready features

- [ ] Consumer groups (load balancing)
- [ ] Offset management (commit/reset)
- [ ] Dead letter queues
- [ ] Message TTL
- [ ] Compression (gzip/snappy)
- [ ] Authentication/authorization

---

### Phase 4: Observability
**Goal**: Monitoring and debugging

- [ ] Telemetry integration
- [ ] Metrics (throughput, latency, consumer lag)
- [ ] Phoenix LiveView dashboard
- [ ] Distributed tracing
- [ ] Health checks

---

### Phase 5: Clustering (Stretch Goal)
**Goal**: Multi-node deployment

- [ ] Partition replication across nodes
- [ ] Leader election for partitions
- [ ] Rebalancing on node join/leave
- [ ] Network partition handling

---

## 🔒 Fault Tolerance

### Supervision Strategy

```
Ratatoskr.Application (one_for_one)
├── Registry (transient)
├── Broker (permanent)
└── Topic.Supervisor (permanent)
    └── Topic.Server (transient)
        └── Partition.Supervisor (one_for_one)
            └── Partition.Server (transient)
```

**Restart Strategies**:
- **permanent**: Always restart (Broker, Supervisors)
- **transient**: Restart only on abnormal exit (Topic, Partition)
- **temporary**: Never restart (future: one-off tasks)

### Failure Scenarios

| Scenario | Impact | Recovery |
|----------|--------|----------|
| Partition crash | Messages in that partition unavailable | Supervisor restarts partition; messages lost (Phase 1) |
| Topic crash | All partitions in topic unavailable | Supervisor restarts topic and all partitions |
| Broker crash | No new topics can be created | Supervisor restarts broker; existing topics unaffected |
| Registry crash | Process lookups fail temporarily | Supervisor restarts registry; processes re-register |

---

## 🛠️ Technology Stack

### Core
- **Elixir 1.17+**: Modern language features
- **OTP 27+**: Latest OTP capabilities
- **GenServer**: Stateful processes
- **DynamicSupervisor**: Runtime child management
- **Registry**: Process discovery
- **ETS**: Fast in-memory storage

### Future Additions
- **Phoenix**: Web dashboard (Phase 4)
- **Telemetry**: Metrics and monitoring (Phase 4)
- **Jason**: JSON encoding/decoding
- **Benchee**: Performance benchmarking
- **StreamData**: Property-based testing

---

## 🎯 Design Principles

1. **Keep It Simple**: Start with minimal features, add complexity as needed
2. **Leverage OTP**: Use battle-tested Erlang/OTP patterns
3. **Fail Fast**: Let it crash, supervisors will recover
4. **Immutable Messages**: No in-place updates, append-only
5. **Process Isolation**: One GenServer per partition for fault isolation
6. **Test Everything**: High test coverage gives confidence to refactor
7. **Measure Performance**: Benchmark early and often
8. **Document Decisions**: Explain why, not just what

---

## 📚 Key Resources

- [Elixir GenServer Guide](https://hexdocs.pm/elixir/GenServer.html)
- [OTP Supervisor Behavior](https://www.erlang.org/doc/man/supervisor.html)
- [Apache Kafka Design](https://kafka.apache.org/documentation/#design)
- [Building a Message Queue in Elixir](https://thoughtbot.com/blog/implementing-a-message-queue-in-elixir)

---

## 🚀 Next Steps

1. Review and refine this architecture
2. Start implementing Phase 1 components
3. Write tests as you go
4. Benchmark early and iterate
5. Document API as it stabilizes

---

*Last Updated: 2025-11-07*
*Status: Architecture Design Phase*
*Next Milestone: Phase 1 - Core Engine Implementation*
