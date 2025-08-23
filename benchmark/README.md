# 🧪 Ratatoskr Performance Test Suite

This directory contains production-ready performance testing tools for Ratatoskr message broker.

## Test Architecture

The test suite uses a **separated architecture** to provide honest, production-representative measurements:

```
┌─────────────────┐         ┌──────────────────┐
│ External Client │ ──gRPC→ │  Ratatoskr       │
│   Publisher     │         │  Message Broker  │
└─────────────────┘         └──────────────────┘
```

## Available Tools

### 1. `concurrent_grpc_publisher.exs`
**Purpose:** High-throughput concurrent gRPC client simulation

```bash
# Usage
elixir benchmark/concurrent_grpc_publisher.exs <total_messages> <topic_count> [concurrency_level]

# Examples
elixir benchmark/concurrent_grpc_publisher.exs 10000 100 20      # Quick test
elixir benchmark/concurrent_grpc_publisher.exs 100000 100 50     # Standard test  
elixir benchmark/concurrent_grpc_publisher.exs 1000000 1000 100  # Extreme scale
```

**Metrics Provided:**
- Concurrent publishing throughput (msg/s)
- Average, P50, P99 latency (ms)
- CPU utilization (%)
- Memory overhead (MB)
- Connection pool efficiency

### 2. `broker_memory_monitor.exs`
**Purpose:** Monitors broker-only resource consumption

```bash
# Usage
elixir benchmark/broker_memory_monitor.exs <topic_count> <subscriber_count>

# Examples
elixir benchmark/broker_memory_monitor.exs 10 100     # Small setup
elixir benchmark/broker_memory_monitor.exs 100 1000   # Medium setup
elixir benchmark/broker_memory_monitor.exs 1000 10000 # Large setup
```

**Metrics Provided:**
- Broker memory consumption (excluding client overhead)
- Delivery throughput and P99 latency
- Process count and resource efficiency
- Real-time activity monitoring

## Running Production Tests

### Quick Performance Test (< 1 minute)
```bash
# Test with 10K messages across 100 topics, 20 concurrent workers
elixir benchmark/concurrent_grpc_publisher.exs 10000 100 20
```

Expected Results:
- Throughput: ~25,000 msg/s
- P99 Latency: <2ms
- CPU Usage: ~12%

### Standard Load Test (1-2 minutes)
```bash
# Test with 100K messages across 100 topics, 50 concurrent workers
elixir benchmark/concurrent_grpc_publisher.exs 100000 100 50
```

Expected Results:
- Throughput: ~35,000 msg/s
- P99 Latency: <2ms
- CPU Usage: ~25%

### Extreme Scale Test (30 seconds)
```bash
# Test with 1M messages across 1000 topics, 100 concurrent workers
elixir benchmark/concurrent_grpc_publisher.exs 1000000 1000 100
```

Expected Results:
- Throughput: ~30,600 msg/s
- P99 Latency: ~1.3ms
- CPU Usage: ~24%
- Memory: ~101MB client overhead

## Separated Testing (Advanced)

For the most accurate production simulation, run broker monitoring and client publishing in separate terminals:

**Terminal 1 - Start Broker Monitor:**
```bash
elixir benchmark/broker_memory_monitor.exs 100 1000
# Wait for "BROKER READY FOR PRODUCTION LOAD"
```

**Terminal 2 - Run Concurrent Publisher:**
```bash
elixir benchmark/concurrent_grpc_publisher.exs 100000 100 50
```

This separation ensures:
- Broker-only memory measurements
- No interference between test tools
- True production-like scenarios

## Performance Baselines

Based on MacBook Air M4 (16GB RAM):

| Test Type | Messages | Topics | Throughput | P99 Latency | CPU |
|-----------|----------|--------|------------|-------------|-----|
| Quick | 10K | 100 | 25,641 msg/s | 1.592ms | 12.7% |
| Standard | 100K | 100 | 35,817 msg/s | 1.863ms | 26.57% |
| Extreme | 1M | 1,000 | 30,612 msg/s | 1.338ms | 24.31% |

## Key Features

✅ **Honest Measurements**: Real gRPC network overhead included  
✅ **CPU Tracking**: Accurate CPU utilization monitoring  
✅ **Memory Separation**: Client vs broker memory tracking  
✅ **Reproducible**: Consistent results across runs  
✅ **Production-Ready**: Simulates real-world scenarios  

## Notes

- All tests use real gRPC/HTTP2 protocol with Protocol Buffers
- CPU measurement requires scheduler wall time tracking
- Memory measurements use physical RAM (not BEAM VM memory)
- Results are saved to `/tmp/` with timestamps

---

*Last Updated: August 2025*  
*Performance Test Suite for Ratatoskr v0.1.0*