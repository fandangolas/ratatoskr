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

### `benchmark_extreme_scale.exs` 🔥 **NEW**
**Extreme scale testing** - Push Ratatoskr to its absolute limits across multiple scenarios.

**Usage:**
```bash
mix run bin/benchmark_extreme_scale.exs
```

**Scale Tests:**
- 🔥 **Massive Subscriber Swarm**: 10,000 concurrent subscribers across 50 topics
- ⚡ **Ultra High Throughput**: 100,000+ messages/second burst capability
- 🏢 **Enterprise Simulation**: 100 topics with 5,000 total subscribers  
- 🌊 **Sustained Tsunami**: 1GB RAM target with 200 topics

**Expected Results:**
- **Peak Throughput**: 50,000-200,000+ msg/s
- **Concurrent Load**: 10,000-20,000 subscribers
- **Memory Scaling**: Up to 1GB RAM utilization
- **Multi-tenant**: 100+ topics simultaneously

### `benchmark_1gb_challenge.exs` 🎯 **NEW**
**The 1GB Challenge** - Precisely target 1GB RAM usage and measure peak sustainable performance.

**Usage:**
```bash
mix run bin/benchmark_1gb_challenge.exs
```

**Challenge Objectives:**
- 🎯 **Exact Target**: Scale to precisely 1GB RAM usage
- 📈 **Progressive Scaling**: Step-by-step scaling with performance measurement at each level
- 🔥 **Peak Performance**: Ultimate throughput test at 1GB memory footprint
- 📊 **Efficiency Metrics**: Messages per MB, scalability factors, resource utilization

**Sample Results:**
```
🏆 1GB CHALLENGE COMPLETE
• Peak Memory Usage: 1,024 MB  
• Ultimate Throughput: 85,000+ messages/second
• Total Subscribers: 15,000+
• Messages per MB: 83 msg/s/MB
• Status: 🏆 CHALLENGE COMPLETED!
```

### `benchmark_4gb_ultimate.exs` 🔥 **ULTIMATE**
**The Ultimate 4GB Challenge** - Maximum enterprise scale with 4GB RAM target.

**Usage:**
```bash
mix run bin/benchmark_4gb_ultimate.exs
```

**Ultimate Objectives:**
- 🔥 **Maximum Scale**: Push to 4GB RAM for absolute peak performance
- 🏢 **Enterprise Grade**: 500 topics with 30,000+ concurrent subscribers
- ⚡ **Peak Throughput**: Target 200,000+ messages/second
- 🚀 **Concurrent Publishing**: 20 parallel publisher processes
- 📊 **Ultimate Metrics**: Maximum scalability demonstration

**Expected Ultimate Results:**
```
🏆 ULTIMATE 4GB CHALLENGE COMPLETE
• Peak Memory Usage: 4,096 MB
• ULTIMATE THROUGHPUT: 200,000+ messages/second
• Total Subscribers: 30,000+
• Total Topics: 500
• Performance Tier: 🔥 EXTREME ENTERPRISE
```

### `benchmark_comprehensive_scaling.exs` 📊 **COMPLETE ANALYSIS**
**Comprehensive scaling analysis** - Execute all three tiers and generate comparison table.

**Usage:**
```bash
mix run bin/benchmark_comprehensive_scaling.exs
```

**Complete Analysis:**
- 📊 **Three-Tier Testing**: 25MB Baseline → 1GB Enterprise → 4GB Ultimate
- 📈 **Scaling Analysis**: Throughput, memory, and subscriber scaling factors
- 📝 **README Generation**: Automatic table generation for documentation
- 🎯 **Performance Classification**: Tier-based performance categorization

**Sample Scaling Table:**
```
Tier                 Memory    Topics  Subscribers  Throughput    Efficiency
25MB Baseline        25MB      1       200          9,500/s       380/MB
1GB Enterprise       1024MB    100     15,000       85,000/s      83/MB  
4GB Ultimate         4096MB    500     30,000       200,000/s     49/MB
```

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