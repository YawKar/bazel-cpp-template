#include "src/lib/example.h"

#include <gtest/gtest.h>

namespace example {
namespace {

TEST(ExampleTest, GreetReturnsExpected) {
    EXPECT_EQ(greet("world"), "hello, world");
}

TEST(ExampleTest, GreetEmptyName) {
    EXPECT_EQ(greet(""), "hello, ");
}

TEST(ExampleTest, AddConstexpr) {
    static_assert(add(2, 3) == 5);
    static_assert(add(-1, 1) == 0);
    static_assert(add(0, 0) == 0);
    // Runtime check too — sanitizers only instrument runtime paths
    EXPECT_EQ(add(1'000'000, 2'000'000), 3'000'000);
}

}  // namespace
}  // namespace example
