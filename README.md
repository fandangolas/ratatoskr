# 🐿️ Ratatoskr

<div align="center">
  <img src="./ratatoskr.webp" width="200" align="right" alt="Ratatoskr - The messenger squirrel" />
  
  **A lightweight, high-performance message broker built with Elixir/OTP**
  
  Named after the Norse mythology squirrel who carries messages between the eagle at the top of Yggdrasil and the dragon at its roots, Ratatoskr delivers messages reliably across your distributed system.

  [![CI](https://github.com/fandangolas/ratatoskr/actions/workflows/ci.yml/badge.svg)](https://github.com/fandangolas/ratatoskr/actions/workflows/ci.yml)
  [![Coverage](https://img.shields.io/badge/coverage-94%25-brightgreen)](https://github.com/fandangolas/ratatoskr)
  [![Elixir](https://img.shields.io/badge/elixir-1.17.3-purple)](https://elixir-lang.org/)
  [![OTP](https://img.shields.io/badge/otp-27.3.4.2-red)](https://www.erlang.org/)
</div>

## ✨ Features

- **High Throughput**: 74,000+ messages/second per node
- **Low Latency**: P99 < 100ms response times
- **Fault Tolerant**: OTP supervision trees with automatic recovery
- **Concurrent**: Support for 500+ concurrent subscribers per topic
- **gRPC Integration**: Easy multi-language client support via Protocol Buffers
- **Simple API**: Clean, intuitive publish/subscribe interface
- **Production Ready**: Comprehensive testing and CI/CD pipeline

## 🚀 Quick Start

```elixir
# Add to your mix.exs
def deps do
  [{:ratatoskr, "~> 0.1.0"}]
end

# Start the broker
Application.ensure_all_started(:ratatoskr)

# Create a topic
{:ok, "orders"} = Ratatoskr.create_topic("orders")

# Subscribe to messages
{:ok, ref} = Ratatoskr.subscribe("orders")

# Publish a message
{:ok, message_id} = Ratatoskr.publish("orders", %{
  id: 123,
  amount: 99.90,
  currency: "USD"
})

# Receive messages
receive do
  {:message, message} -> 
    IO.inspect(message.payload)
end
```

## 🔌 gRPC Integration

Ratatoskr uses gRPC for high-performance, multi-language client support:

```go
// Connect from Go, Java, Python, C++, and more
client, err := ratatoskr.NewClient("localhost:50051")

// Publish messages with type safety
resp, err := client.Publish(ctx, &pb.PublishRequest{
    Topic:   "orders",
    Payload: orderBytes,
})

// Stream subscriptions in real-time
stream, err := client.Subscribe(ctx, &pb.SubscribeRequest{
    Topic: "orders",
})
```

**Benefits:**
- **Type-safe** communication via Protocol Buffers
- **Streaming support** for real-time subscriptions
- **Auto-generated clients** for multiple languages
- **9,500+ msg/s** gRPC throughput with 0.124ms P99 latency
- **Built-in** load balancing and connection management

## 📊 Performance

Ratatoskr delivers exceptional performance through careful engineering:

| Metric | Target | Internal API | gRPC API |
|--------|--------|-------------|----------|
| Throughput | 1,000 msg/s | **74,771 msg/s** | **9,496 msg/s** |
| Concurrent Subscribers | 100+ | **500+** | **Validated** |
| Latency P99 | <100ms | **<50ms** | **0.124ms** |
| Average Latency | <10ms | **<1ms** | **0.105ms** |
| Memory Usage | Efficient | **<50MB @ 500 subscribers** | **Low overhead** |

## 🏗️ Architecture

Built on proven OTP patterns for maximum reliability:

- **One GenServer per topic** - Fault isolation and natural backpressure
- **DynamicSupervisor** - Dynamic topic lifecycle management  
- **Registry** - Fast process discovery and routing
- **gRPC Server** - High-performance binary protocol for clients
- **ETS** - High-performance in-memory message storage
- **Supervision Trees** - Automatic crash recovery

## 🧪 Testing

Comprehensive test suite with multiple validation layers:

```bash
# Run core tests
mix test

# Performance benchmarks
mix test --include performance

# Stress testing (500+ concurrent)
mix test --include stress

# Recovery & resilience
mix test --include recovery

# Full test suite with coverage
mix test --cover
```

## 🔧 Development

Built with modern Elixir tooling and best practices:

- **Code Quality**: Credo static analysis with strict rules
- **Formatting**: Automatic code formatting enforcement
- **Coverage**: 94%+ test coverage on core functionality
- **CI/CD**: GitHub Actions with comprehensive validation
- **Documentation**: Full API documentation with examples

## 📈 Monitoring

Real-time insights into message broker performance:

```elixir
# Topic statistics
{:ok, stats} = Ratatoskr.stats("orders")
# => %{topic: "orders", message_count: 1250, subscriber_count: 5}

# List all topics
{:ok, topics} = Ratatoskr.list_topics()
# => ["orders", "notifications", "analytics"]
```

## 🛡️ Production Ready

- **Security**: Dependency vulnerability scanning
- **Reliability**: Crash recovery under load
- **Observability**: Built-in metrics and logging
- **Scalability**: Horizontal scaling capabilities
- **Maintenance**: Zero-downtime deployments

## 📝 License

MIT License - see [LICENSE](LICENSE) file for details.

---

<div align="center">
  <i>Built with ❤️ and Elixir</i>
</div>

