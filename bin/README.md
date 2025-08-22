# Ratatoskr Benchmark Scripts

This directory contains **real, measured performance** benchmark scripts for Ratatoskr.

## 🎯 Available Scripts (Real Data Only)

### `real_benchmark.exs` ✅ **BASELINE**
**Real baseline performance** - Actual measured performance with honest memory usage.

**Usage:**
```bash
mix run bin/real_benchmark.exs
```

**Real Metrics:**
- ✅ **30,769 msg/s** with 50 subscribers
- ✅ **64MB baseline** → **66MB peak** (2MB overhead)
- ✅ **15,385 msg/s/MB** efficiency
- ✅ MacBook Air M4 16GB verified results

### `realistic_1gb_test.exs` 🎯 **REALISTIC SCALE**
**Honest scaling test** - Real physical RAM usage within system limits.

**Usage:**
```bash
mix run bin/realistic_1gb_test.exs
```

**Real Scale Results:**
- ✅ **3,293 msg/s** with 2,000 subscribers
- ✅ **64MB baseline** → **79MB peak** (15MB overhead)
- ✅ **209+ msg/s/MB** efficiency
- ✅ No virtual memory tricks - real physical RAM only
- ✅ System stays stable, no swapping

### `benchmark_grpc_p99.exs` ⚡ **gRPC PERFORMANCE**
**gRPC server performance** - Real network protocol benchmarks.

**Usage:**
```bash
mix run bin/benchmark_grpc_p99.exs
```

**gRPC Metrics:**
- ✅ Complete latency distribution (P99, P95, etc.)
- ✅ Network protocol overhead analysis
- ✅ Cross-language client compatibility

### `benchmark_grpc_comprehensive.exs` 📊 **gRPC ADVANCED**
**Extended gRPC analysis** - Advanced network performance testing.

**Usage:**
```bash
mix run bin/benchmark_grpc_comprehensive.exs
```

**Advanced Features:**
- ✅ Batch publishing analysis
- ✅ Concurrent client testing
- ✅ Connection overhead measurements

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