# Ratatoskr Benchmark Scripts

This directory contains performance benchmark scripts for measuring Ratatoskr's gRPC server performance.

## Available Scripts

### `benchmark_grpc_p99.exs`
**Primary benchmark script** - Comprehensive gRPC performance analysis including P99 latency measurements.

**Usage:**
```bash
mix run bin/benchmark_grpc_p99.exs
```

**Metrics:**
- ✅ Complete latency distribution (min, avg, P50, P95, P99, P99.9, max)
- ✅ Throughput performance under load
- ✅ Direct comparison with Internal Elixir API
- ✅ Performance efficiency ratios

**Sample Output:**
```
🎯 gRPC Publish Latency Results (1000 samples):
- Average: 0.105ms
- P99: 0.124ms
- Throughput: 9,496 msg/s
```

### `benchmark_grpc_comprehensive.exs`
**Advanced benchmark script** - Extended analysis with batch performance and concurrent client testing.

**Usage:**
```bash
mix run bin/benchmark_grpc_comprehensive.exs
```

**Additional Features:**
- ✅ Batch publishing performance analysis
- ✅ Concurrent client benchmarking  
- ✅ Connection overhead measurements
- ✅ Detailed performance tables and comparisons

## Running Benchmarks

**Prerequisites:**
- Ratatoskr application must be running
- gRPC server listening on port 50051
- No conflicting processes using the test topics

**Quick Performance Check:**
```bash
# Start Ratatoskr and run primary benchmark
mix run bin/benchmark_grpc_p99.exs
```

**Full Performance Analysis:**
```bash
# Run comprehensive benchmark suite
mix run bin/benchmark_grpc_comprehensive.exs
```

## Expected Performance Results

Based on latest measurements:

| Metric | Internal API | gRPC API | Status |
|--------|-------------|----------|--------|
| **Throughput** | ~311K msg/s | ~9.5K msg/s | ✅ Excellent |
| **Average Latency** | 0.002ms | 0.105ms | ✅ Sub-millisecond |  
| **P99 Latency** | 0.007ms | 0.124ms | ✅ Outstanding |
| **Efficiency** | 100% | 3.0% | ✅ Expected for gRPC |

## Troubleshooting

**Port Already in Use:**
```bash
# Kill any existing processes on port 50051
lsof -ti:50051 | xargs kill -9
```

**Application Not Starting:**
```bash
# Ensure all dependencies are installed
mix deps.get
mix compile
```

**Performance Lower Than Expected:**
- Check system load and available resources
- Ensure no other heavy processes are running
- Verify network configuration (even localhost adds overhead)
- Run multiple times to account for JIT warm-up

## Performance Targets

| Use Case | Min Throughput | Max P99 Latency | Status |
|----------|----------------|-----------------|--------|
| **Real-time Chat** | 1,000 msg/s | 5ms | ✅ Exceeded |
| **IoT Data Ingestion** | 5,000 msg/s | 10ms | ✅ Exceeded |
| **Financial Transactions** | 500 msg/s | 1ms | ✅ Exceeded |
| **High-Frequency Trading** | 10,000 msg/s | 0.5ms | ✅ Nearly met |

---

*Last Updated: August 2025*  
*Benchmark Scripts for Ratatoskr v0.1.0*