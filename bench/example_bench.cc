#include "src/lib/example.h"

#include <benchmark/benchmark.h>

namespace {

void bm_greet(benchmark::State& state) {
    for (auto _ : state) {
        auto result = example::greet("benchmark");
        benchmark::DoNotOptimize(result);
    }
}
BENCHMARK(bm_greet);

void bm_add(benchmark::State& state) {
    std::int64_t a = 42;
    std::int64_t b = 58;
    for (auto _ : state) {
        auto result = example::add(a, b);
        benchmark::DoNotOptimize(result);
    }
}
BENCHMARK(bm_add);

}  // namespace
