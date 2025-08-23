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

### 1. `external_grpc_publisher.exs`
**Purpose:** Simulates production gRPC clients

```bash
# Usage
elixir bin/external_grpc_publisher.exs <total_messages> <topic_count>

# Examples
elixir bin/external_grpc_publisher.exs 10000 100      # Quick test
elixir bin/external_grpc_publisher.exs 100000 1       # Standard test  
elixir bin/external_grpc_publisher.exs 1000000 1000   # Extreme scale
```

**Metrics Provided:**
- Publishing throughput (msg/s)
- P50, P99 latency (ms)
- CPU utilization (%)
- Memory overhead (MB)

### 2. `broker_memory_monitor.exs`
**Purpose:** Monitors broker-only resource consumption

```bash
# Usage
elixir bin/broker_memory_monitor.exs <topic_count> <subscriber_count>

# Examples
elixir bin/broker_memory_monitor.exs 10 100     # Small setup
elixir bin/broker_memory_monitor.exs 100 1000   # Medium setup
elixir bin/broker_memory_monitor.exs 1000 10000 # Large setup
```

**Metrics Provided:**
- Broker memory consumption (excluding client overhead)
- Delivery throughput and P99 latency
- Process count and resource efficiency
- Real-time activity monitoring

## Running Production Tests

### Quick Performance Test (1 minute)
```bash
# Test with 10K messages across 100 topics
elixir bin/external_grpc_publisher.exs 10000 100
```

Expected Results:
- Throughput: ~8,000 msg/s
- P99 Latency: <0.2ms
- CPU Usage: ~2%

### Standard Load Test (2 minutes)
```bash
# Test with 100K messages
elixir bin/external_grpc_publisher.exs 100000 1
```

Expected Results:
- Throughput: ~8,000 msg/s
- P99 Latency: <0.5ms
- CPU Usage: ~2%

### Extreme Scale Test (2-3 minutes)
```bash
# Test with 1M messages across 1000 topics
elixir bin/external_grpc_publisher.exs 1000000 1000
```

Expected Results:
- Throughput: ~8,450 msg/s
- P99 Latency: ~0.158ms
- CPU Usage: ~2%
- Memory: 42-89MB client overhead

## Separated Testing (Advanced)

For the most accurate production simulation, run broker monitoring and client publishing in separate terminals:

**Terminal 1 - Start Broker Monitor:**
```bash
elixir bin/broker_memory_monitor.exs 100 1000
# Wait for "BROKER READY FOR PRODUCTION LOAD"
```

**Terminal 2 - Run Publisher:**
```bash
elixir bin/external_grpc_publisher.exs 100000 100
```

This separation ensures:
- Broker-only memory measurements
- No interference between test tools
- True production-like scenarios

## Performance Baselines

Based on MacBook Air M4 (16GB RAM):

| Test Type | Messages | Topics | Throughput | P99 Latency | CPU |
|-----------|----------|--------|------------|-------------|-----|
| Quick | 10K | 100 | 8,264 msg/s | 0.152ms | 1.91% |
| Standard | 100K | 1 | 8,333 msg/s | 0.481ms | ~2% |
| Extreme | 1M | 1,000 | 8,450 msg/s | 0.158ms | ~2% |

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