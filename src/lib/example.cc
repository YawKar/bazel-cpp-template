#include "src/lib/example.h"

#include <string>

namespace example {

auto greet(std::string_view name) -> std::string {
    std::string result = "hello, ";
    result += name;
    return result;
}

}  // namespace example
