# 🐿️ Ratatoskr

<div align="center">
  <img src="./ratatoskr.webp" width="200" align="right" alt="Ratatoskr - The messenger squirrel" />
  
  **A lightweight, high-performance message broker built with Elixir/OTP**
  
  Named after the Norse mythology squirrel who carries messages between the eagle at the top of Yggdrasil and the dragon at its roots, Ratatoskr delivers messages reliably across your distributed system.
</div>

## 🎯 What is Ratatoskr?

Ratatoskr is a lightweight, educational message broker inspired by Apache Kafka, built entirely in Elixir/OTP. It demonstrates how to build a distributed messaging system using Elixir's powerful concurrency primitives.

**Key Features:**
- 🚀 High throughput (10,000+ msg/s target)
- ⚡ Low latency (P99 < 10ms target)
- 🛡️ Fault-tolerant with OTP supervision
- 📊 Topic-based publish/subscribe
- 🔀 Partition-based parallelism
- 💾 In-memory storage with ETS (Phase 1)

**Purpose:**
- 📚 Educational: Showcase Elixir/OTP best practices
- 🎓 Demonstrative: Illustrate GenServers, supervision trees, and the Actor model
- 🛠️ Practical: Provide a lightweight messaging solution for small-to-medium applications

## 🚀 Quick Start

```bash
# Clone the repository
git clone https://github.com/fandangolas/ratatoskr.git
cd ratatoskr

# Install dependencies
mix deps.get

# Run tests
mix test

# Start the broker (interactive shell)
iex -S mix
```

### Basic Usage

```elixir
# Create a topic with 3 partitions
{:ok, _topic} = Ratatoskr.create_topic("orders", partition_count: 3)

# Publish a message
{:ok, offset} = Ratatoskr.publish("orders", %{id: 123, amount: 99.99})

# Publish with a key (routes to specific partition)
{:ok, offset} = Ratatoskr.publish("orders", "user-123", %{id: 456, amount: 49.99})

# Subscribe to messages
{:ok, subscription_id} = Ratatoskr.subscribe("orders", 0, fn message ->
  IO.inspect(message, label: "Received")
  :ack
end)

# List all topics
{:ok, topics} = Ratatoskr.list_topics()

# Delete a topic
:ok = Ratatoskr.delete_topic("orders")
```

## 🏗️ Architecture

Ratatoskr leverages OTP patterns for maximum reliability and performance:

```
Application Supervisor (one_for_one)
├── Registry (process discovery)
├── Broker (topic lifecycle coordinator)
└── Topic.Supervisor (dynamic)
    └── Topic.Server (per topic)
        └── Partition.Server (per partition)
            ├── ETS storage
            └── :queue (FIFO ordering)
```

### Core Components

**Broker** (`Ratatoskr.Broker`)
- Manages topic lifecycle (create/delete/list)
- Maintains topic metadata
- Coordinates with Topic.Supervisor

**Topic Server** (`Ratatoskr.Topic.Server`)
- Routes messages to partitions
- Manages partition processes
- Handles key-based routing: `hash(key) % partition_count`

**Partition Server** (`Ratatoskr.Partition.Server`)
- Stores messages in FIFO order
- Manages subscribers (push model)
- Assigns auto-incrementing offsets
- Uses ETS for fast offset-based lookups

**Registry** (Built-in)
- Fast process discovery
- Topic and partition name resolution
- No external dependencies

### Design Principles

1. **Fault Isolation**: One GenServer per partition - failures are isolated
2. **Let It Crash**: OTP supervisors handle recovery
3. **Immutability**: Messages are append-only
4. **Process Isolation**: Each partition is independent
5. **Simple First**: Start minimal, add complexity as needed

## 📊 Performance Targets (Phase 1)

| Metric | Target |
|--------|--------|
| Throughput | 10,000+ msg/s per node |
| Latency (P99) | < 10ms |
| Concurrent Consumers | 100+ per partition |
| Message Size | Up to 1MB |
| Memory per Partition | ~10MB baseline |

## 🗺️ Roadmap

### Phase 1: Core Engine (MVP) - **Current Phase**
- [x] Project setup with supervision tree
- [ ] Broker GenServer (topic management)
- [ ] Topic.Server (routing logic)
- [ ] Partition.Server (message storage + delivery)
- [ ] Producer API
- [ ] Consumer API (callback mode)
- [ ] Basic tests (>80% coverage)
- [ ] Performance benchmarks

### Phase 2: Persistence
- [ ] Append-only log files per partition
- [ ] Write-ahead logging (WAL)
- [ ] Configurable retention policies
- [ ] Recovery on crash

### Phase 3: Advanced Features
- [ ] Consumer groups (load balancing)
- [ ] Offset management (commit/reset)
- [ ] Dead letter queues
- [ ] Message TTL
- [ ] Compression

### Phase 4: Observability
- [ ] Telemetry integration
- [ ] Metrics dashboard (Phoenix LiveView)
- [ ] Distributed tracing
- [ ] Health checks

### Phase 5: Clustering (Stretch Goal)
- [ ] Multi-node deployment
- [ ] Partition replication
- [ ] Leader election

## 🧪 Testing

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run performance benchmarks (future)
mix run benchmark/throughput.exs
```

### Testing Strategy

- **Unit Tests**: Each GenServer module tested independently
- **Integration Tests**: Full publish-subscribe flows
- **Property Tests**: Message ordering guarantees
- **Performance Tests**: Throughput and latency benchmarks
- **Target**: >90% code coverage

## 🔧 Development

### Requirements

- Elixir 1.17+
- Erlang/OTP 27+

### Code Quality

```bash
# Format code
mix format

# Run static analysis (future)
mix credo

# Run dialyzer (future)
mix dialyzer
```

## 📚 Documentation

For detailed architecture and design decisions, see [ARCHITECTURE.md](ARCHITECTURE.md).

## 📝 License

MIT License - see [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Inspired by [Apache Kafka](https://kafka.apache.org/)
- Built with [Elixir](https://elixir-lang.org/) and [OTP](https://www.erlang.org/)

---

<div align="center">
  <i>Built with ❤️ and Elixir</i>
</div>

