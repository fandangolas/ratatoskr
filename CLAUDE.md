# CLAUDE.md - Ratatoskr Project Guide

## 🐿️ Project Overview

**Ratatoskr** is a lightweight message broker built with Elixir/OTP, named after the Norse mythology squirrel who carries messages between the eagle at the top of Yggdrasil and the dragon at its roots.

### Core Mission
Build a production-ready message broker that provides:
- At-least-once delivery guarantees
- Persistent message storage
- High throughput (10,000+ msg/s per node)
- Low latency (p99 <10ms)
- Fault tolerance through OTP supervision

## 🎯 Current Phase: MVP Development

We are starting with **Milestone 1: Core Message Engine** (Week 1)

### Immediate Goals
1. ✅ Create project structure
2. ✅ Implement supervisor tree
3. ✅ Basic topic management (create/delete/list)
4. ✅ In-memory message queue
5. ✅ Simple publish/subscribe API
6. ✅ Core tests with >80% coverage

## 🏗️ Project Structure

```
ratatoskr/
├── lib/
│   ├── ratatoskr/
│   │   ├── application.ex      # Main OTP application
│   │   ├── broker.ex           # Broker coordinator
│   │   ├── topic/
│   │   │   ├── supervisor.ex   # DynamicSupervisor for topics
│   │   │   └── server.ex       # GenServer per topic
│   │   ├── message.ex          # Message struct
│   │   ├── consumer/
│   │   │   ├── supervisor.ex   # Consumer supervisor
│   │   │   └── worker.ex       # Consumer worker
│   │   └── storage/            # (Future: Milestone 2)
│   │       ├── writer.ex
│   │       └── reader.ex
│   └── ratatoskr.ex            # Public API
├── test/
│   ├── ratatoskr_test.exs
│   ├── topic_test.exs
│   └── integration_test.exs
├── config/
│   └── config.exs
├── mix.exs
└── README.md
```

## 🔧 Technical Decisions

### Architecture Decisions
1. **One GenServer per topic** - Fault isolation and natural backpressure
2. **ETS for temporary storage** - Fast in-memory operations  
3. **Registry for process discovery** - Built-in Elixir Registry
4. **Push model for consumers** - At least in MVP
5. **UUID v4 for message IDs** - No coordination required

### Technology Stack
- **Elixir 1.15+** 
- **OTP 26+**
- **No external dependencies for core** (MVP)
- **Phoenix** (later, for monitoring dashboard)
- **Telemetry** (for metrics)

## 📝 API Design

### Public API (Target for Milestone 1)
```elixir
# Start the broker
{:ok, _pid} = Ratatoskr.start_link()

# Topic management
{:ok, topic} = Ratatoskr.create_topic("orders")
:ok = Ratatoskr.delete_topic("orders")
{:ok, topics} = Ratatoskr.list_topics()

# Publishing
{:ok, message_id} = Ratatoskr.publish("orders", %{
  id: 123,
  amount: 99.90,
  currency: "USD"
})

# Subscribing
{:ok, subscription_id} = Ratatoskr.subscribe("orders", fn message ->
  IO.inspect(message)
  :ack  # or :nack for retry
end)

# Unsubscribe
:ok = Ratatoskr.unsubscribe(subscription_id)
```

## 🚀 Implementation Steps

### Step 1: Basic Project Setup ✅
```bash
mix new ratatoskr --sup
cd ratatoskr
git init
```

### Step 2: Core Supervisor Tree
Create the supervision tree with:
- Main application supervisor
- Topic supervisor (DynamicSupervisor)
- Registry for topic discovery

### Step 3: Topic GenServer
Implement `Ratatoskr.Topic.Server`:
- State: topic name, messages queue, subscribers list
- Handle publish (add to queue, notify subscribers)
- Handle subscribe (add to subscribers)
- Handle message acknowledgment

### Step 4: Public API Module
Create `lib/ratatoskr.ex` with the public interface:
- Delegate to appropriate GenServers
- Handle error cases gracefully
- Add typespecs

### Step 5: Testing
- Unit tests for each module
- Integration tests for full flow
- Property-based tests for message ordering

## 🧪 Testing Strategy

### Test Coverage Goals
- Unit tests: >80% coverage
- Integration tests: Core happy paths
- Property tests: Message ordering, delivery guarantees

### Key Test Scenarios
```elixir
# 1. Basic publish/subscribe
test "publishes and receives messages" do
  Ratatoskr.create_topic("test")
  
  received = []
  Ratatoskr.subscribe("test", fn msg -> 
    send(self(), {:received, msg})
    :ack
  end)
  
  Ratatoskr.publish("test", %{data: "hello"})
  
  assert_receive {:received, %{data: "hello"}}, 1000
end

# 2. Multiple subscribers
# 3. Topic isolation
# 4. Crash recovery
# 5. Performance under load
```

## 📊 Success Metrics for Milestone 1

- [x] Can create/delete topics dynamically
- [x] Can publish 1000 messages/second to single topic *(achieved 74,771+ msg/s)*
- [x] Can support 100 concurrent subscribers *(tested with 500+ subscribers)*
- [x] Messages delivered in FIFO order per topic
- [x] Supervisor tree handles crashes gracefully
- [x] Tests pass with >80% coverage *(achieved 92.63%)*
- [x] Basic benchmarks established *(comprehensive performance suite)*

### 🚀 Benchmark Results (as of implementation)

**Throughput Performance:**
- **74,771+ messages/second** (far exceeds 1000 msg/s target)
- **High throughput sustained:** 99,850+ msg/s for 5000 messages  
- **Memory efficient:** 1.25 MB for 2000 messages

**Latency Performance:**
- **P50 latency:** 0.029ms  
- **P99 latency:** 0.111ms (far below 100ms MVP target)
- **Max latency:** 0.123ms

**Concurrency Performance:**
- **100+ concurrent subscribers:** ✅ Tested up to 500 subscribers
- **Multiple topics:** ✅ Tested 5 topics with 20 subscribers each
- **Crash recovery:** ✅ Graceful handling of process failures

**Running Benchmarks:**
```bash
# Run performance tests
mix test --include performance

# Run stress tests  
mix test --include stress

# Run recovery tests
mix test --include recovery

# Run all benchmarks
mix test --include performance --include stress --include recovery
```

## ⚠️ Important Constraints

### What's NOT in Milestone 1
- ❌ Persistence (that's Milestone 2)
- ❌ Consumer groups
- ❌ Partitioning
- ❌ Clustering
- ❌ Dead letter queues
- ❌ Metrics/monitoring

Keep it simple! We're building foundation first.

## 🐛 Common Pitfalls to Avoid

1. **Don't over-engineer** - No GenStage/Broadway in MVP
2. **Keep topics isolated** - One topic crash shouldn't affect others
3. **Watch for memory leaks** - Monitor queue sizes
4. **Test concurrent scenarios** - Race conditions are common
5. **Handle supervisor restarts** - State recovery strategy

## 💡 Code Style Guidelines

### Elixir Conventions
- Use `snake_case` for functions and variables
- Use `PascalCase` for modules
- Add typespecs to public functions
- Document with `@moduledoc` and `@doc`
- Keep functions small (<20 lines)

### Example Module Structure
```elixir
defmodule Ratatoskr.Topic.Server do
  @moduledoc """
  GenServer managing a single topic's message queue and subscribers.
  """
  
  use GenServer
  require Logger
  
  # Type definitions
  @type state :: %{
    name: String.t(),
    messages: :queue.queue(),
    subscribers: list(pid())
  }
  
  # Public API
  @doc """
  Starts a new topic server.
  """
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(topic_name) do
    GenServer.start_link(__MODULE__, topic_name, name: via_tuple(topic_name))
  end
  
  # Callbacks
  @impl true
  def init(topic_name) do
    Logger.info("Starting topic: #{topic_name}")
    {:ok, initial_state(topic_name)}
  end
  
  # Private functions
  defp initial_state(name) do
    %{
      name: name,
      messages: :queue.new(),
      subscribers: []
    }
  end
  
  defp via_tuple(topic_name) do
    {:via, Registry, {Ratatoskr.Registry, topic_name}}
  end
end
```

## 🔄 Next Development Session

When continuing development:

1. **Check current status**: Run `mix test` to see what's working
2. **Review this guide**: Check which milestone we're on
3. **Pick next task**: Follow the implementation steps
4. **Test incrementally**: Write test, implement, verify
5. **Update progress**: Mark completed items with ✅

## 📚 Quick References

### Useful Erlang Modules
- `:queue` - Efficient FIFO queue
- `:ets` - In-memory storage (future use)
- `:erlang.unique_integer()` - For IDs
- `:timer` - For timeouts

### OTP Patterns We're Using
- **Supervisor** - Fault tolerance
- **GenServer** - Stateful processes
- **Registry** - Process discovery
- **DynamicSupervisor** - Dynamic children

## 🎯 Remember the Mission

We're building Ratatoskr - the messenger that never stops running up and down the world tree, delivering messages reliably between the realms of your distributed system!

Keep it simple, make it reliable, then make it fast.

---

*Last Updated: August 2025*
*Project Phase: Milestone 1 - Core Engine*
*Next Review: After Milestone 1 completion*