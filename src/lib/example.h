#pragma once

#include <cstdint>
#include <string>
#include <string_view>

/// @file
/// Example library API, kept as the smallest thing the docs build can check.

/// Everything this template ships lives here.
///
/// The namespace needs its own comment: with EXTRACT_ALL = NO, doxygen will
/// not emit members of an undocumented namespace, so leaving this off silently
/// produces an empty docs tree that `just docs-check` still reports as clean.
namespace example {

/// Smoke-test function. Replace with real code in Phase 1.
///
/// @param name Text to address the greeting to. Copied into the result.
/// @return The greeting, as `"hello, <name>"`.
///
/// @snippet greet_example.cc greet
[[nodiscard]] auto greet(std::string_view name) -> std::string;

/// Trivial constexpr for compile-time verification.
///
/// @param a Left addend.
/// @param b Right addend.
/// @return The sum. Overflow is undefined, as for any signed addition.
///
/// @snippet greet_example.cc add
constexpr auto add(std::int64_t a, std::int64_t b) noexcept -> std::int64_t {
    return a + b;
}

}  // namespace example
