# 🐿️ Ratatoskr

<div align="center">
  <img src="https://64.media.tumblr.com/929ec29752b3017937dcccb9297916cc/29df4886dc0e9634-40/s540x810/743bd0878d44c6b247a796ce3826eed3cc61f451.gifv" width="200" align="right" />
  
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

## 📊 Performance

Ratatoskr delivers exceptional performance through careful engineering:

| Metric | Target | Achieved |
|--------|--------|----------|
| Throughput | 1,000 msg/s | **74,771 msg/s** |
| Concurrent Subscribers | 100+ | **500+** |
| Latency P99 | <100ms | **<50ms** |
| Memory Usage | Efficient | **<50MB @ 500 subscribers** |

## 🏗️ Architecture

Built on proven OTP patterns for maximum reliability:

- **One GenServer per topic** - Fault isolation and natural backpressure
- **DynamicSupervisor** - Dynamic topic lifecycle management  
- **Registry** - Fast process discovery and routing
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

