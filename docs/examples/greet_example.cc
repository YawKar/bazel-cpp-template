// Documentation examples. Every snippet the API docs show is taken from this
// file with @snippet, and every one of them is a real assertion that
// `bazel test //...` runs.
//
// The rule: no example code in a doc comment. A comment can be well-formed,
// pass docs-check, and still be wrong -- it is prose, and nothing compiles it.
// A snippet is compiled against the current headers and its claims are
// checked, so an API change breaks the build or the test rather than quietly
// leaving a lie on the docs page.
//
// The `//! [name]` markers delimit what @snippet lifts. Keep the region tight:
// everything between the markers lands on the page verbatim, indentation and
// all.

#include "src/lib/example.h"

#include <gtest/gtest.h>

#include <string>

namespace {

TEST(GreetExample, FormatsAGreeting) {
    //! [greet]
    std::string message = example::greet("world");
    // -> "hello, world"
    //! [greet]

    EXPECT_EQ(message, "hello, world");
}

TEST(AddExample, EvaluatesAtCompileTime) {
    //! [add]
    static_assert(example::add(2, 40) == 42, "usable in a constant expression");
    //! [add]

    EXPECT_EQ(example::add(2, 40), 42);
}

}  // namespace
