[default]
[private]
default:
    @just --list --unsorted

[private]
pre-commit-hook: format-check lint

[group("Basics")]
build *FLAGS:
    bazel build {{ FLAGS }} //...
[group("Basics")]
test *FLAGS:
    bazel test {{ FLAGS }} //...
[group("Basics")]
bench target *FLAGS:
    bazel run {{ FLAGS }} //bench:{{ target }}

# Deliberately separate from `test`: coverage instruments the build, so the
# flags differ and merging the two would make every ordinary `just test`
# thrash the analysis cache between instrumented and uninstrumented
# configurations. `bazel coverage` runs the tests itself, so this stands alone.

# run the tests under coverage and render an HTML report
[group("Basics")]
coverage *FLAGS:
    bazel coverage {{ FLAGS }} //...
    # --ignore-errors unsupported: genhtml expects gcov's function end-line
    # records, which are a GCC 9+ feature. Clang's lcov output has no such
    # thing, so genhtml derives the end lines and warns. It is a gcov-ism that
    # does not apply to clang source-based coverage; scoped to that one
    # category so genuine problems still surface.
    genhtml --output-directory coverage-html --demangle-cpp llvm-cxxfilt \
      --show-details --legend --ignore-errors unsupported \
      "$(bazel info output_path)/_coverage/_coverage_report.dat"
    @echo "coverage report -> coverage-html/index.html"

# render the API docs and open them
[group("Docs")]
docs: docs-check
    xdg-open docs/html/index.html

# WARN_AS_ERROR = FAIL_ON_WARNINGS in the Doxyfile, so this is the gate: an
# added function with no comment, a @param naming an argument that does not
# exist, or a stale reference all exit non-zero. `docs` runs it first for the
# same reason -- no point opening a page that was generated from a failed run.

# build the API docs, failing on any undocumented public API
[group("Docs")]
docs-check:
    doxygen Doxyfile

# This is the "what did the optimiser actually do" view: real machine code from
# the real binary, after inlining and register allocation, not a snippet
# compiled in isolation. Bazel records source paths as /proc/self/cwd/..., and
# just runs from the workspace root, so the disassembler resolves them -- which
# is why the C++ shows up next to the instructions at all.
#
#   just asm //bench:example_bench            # whole binary
#   just asm //src/lib:example                # the library archive
#   just asm //src/lib:example greet          # just matching functions
#
# FILTER matches against the *demangled* name, so `greet` finds
# example::greet(std::string_view) without spelling out _ZN7example5greet...

# disassemble a built target, source interleaved
[group("Dev")]
asm target filter="":
    #!/usr/bin/env bash
    set -euo pipefail
    bazel build --config=asm {{ target }}
    # cquery, not a guessed path: a cc_binary yields one file, a cc_library
    # yields .a/.pic.a/.so and the plain archive is the one worth reading.
    obj="$(bazel cquery --config=asm --output=files {{ target }} 2>/dev/null | head -1)"
    echo "==> $obj" >&2
    # Not --demangle: it makes --disassemble-symbols expect the demangled
    # name, and those contain commas, which is the separator that flag uses.
    # Matching on mangled names and demangling the output stream avoids both.
    args=(-d -S -l --no-show-raw-insn --x86-asm-syntax=intel)
    if [[ -n "{{ filter }}" ]]; then
      # llvm-objdump wants mangled names, so demangle the symbol table once,
      # match on the readable form, and hand back the mangled ones.
      mangled="$(mktemp)"; trap 'rm -f "$mangled"' EXIT
      llvm-nm --defined-only --format=just-symbols "$obj" | sort -u > "$mangled"
      syms="$(paste -d'\t' "$mangled" <(llvm-cxxfilt < "$mangled") \
              | grep -F -- '{{ filter }}' | cut -f1 | paste -sd, -)"
      [[ -n "$syms" ]] || { echo "no symbol matching '{{ filter }}' in $obj" >&2; exit 1; }
      args+=("--disassemble-symbols=$syms")
    fi
    llvm-objdump "${args[@]}" "$obj" | llvm-cxxfilt \
      | bat --language=asm --style=plain --paging=always

# The other half of the picture. `asm` disassembles the finished artifact;
# this is the compiler's own output -- directives, labels, and the vectoriser's
# choices as it wrote them, which is what a Compiler Explorer pane shows. The
# difference matters when you want to see structure rather than final encoding.
#
#   just asm-src //src/lib:example

# show the compiler's own assembly output for a target
[group("Dev")]
asm-src target:
    #!/usr/bin/env bash
    set -euo pipefail
    # --save_temps leaves the .s (and .i) next to each object file.
    bazel build --config=asm --save_temps {{ target }}
    label="{{ target }}"; label="${label#//}"
    pkg="${label%%:*}"; name="${label##*:}"
    [[ "$name" != "$label" ]] || name="${pkg##*/}"
    # --config=asm on `info` too: without it bazel-bin points at the fastbuild
    # output tree and the files built a moment ago are not there.
    dir="$(bazel info --config=asm bazel-bin)/${pkg}/_objs/${name}"
    # A cc_library builds both PIC and non-PIC objects; the .s files are near
    # identical, so show the plain one and fall back to PIC if that is all
    # there is (as for a cc_binary built PIC-only).
    mapfile -t files < <(find "$dir" -name '*.s' ! -name '*.pic.s' | sort)
    [[ ${#files[@]} -gt 0 ]] || mapfile -t files < <(find "$dir" -name '*.s' | sort)
    [[ ${#files[@]} -gt 0 ]] || { echo "no .s found under $dir" >&2; exit 1; }
    printf '==> %s\n' "${files[@]}" >&2
    # Through cxxfilt for the same reason as `asm`: raw .s is all mangled names.
    cat "${files[@]}" | llvm-cxxfilt \
      | bat --language=asm --style=plain --paging=always

# regenerate compile_commands.json for clangd / clang-tidy
[group("Dev")]
refresh:
    # No post-processing. The toolchain names every system include path on
    # the command line (--sysroot into the pinned sysroot, -nostdinc++ plus
    # -cxx-isystem for libc++, -idirafter for clang's builtin headers), so the
    # extracted database is self-contained and contains no host or /nix/store
    # path. This is what the -isystem injection hack used to work around.
    bazel run //:refresh_compile_commands

# format everything
[group("Code Style")]
format check="":
    # nix
    find . -type f -name "*.nix" -exec nixfmt -sv {{ if check != "" { "-c" } else { "" } }} {} +
    # yaml
    yamlfmt {{ if check != "" { "-lint" } else { "" } }} .
    # just
    just --fmt {{ if check != "" { "--check" } else { "" } }}
    # bazel
    buildifier -r {{ if check != "" { "-mode check -lint warn" } else { "" } }} .
    # c++
    find src test bench docs/examples -type f \( -name "*.cc" -o -name "*.h" \) \
      -exec clang-format {{ if check != "" { "--dry-run --Werror" } else { "-i" } }} {} +
[group("Code Style")]
format-check: (format "check")

# lint everything
[group("Code Style")]
lint fix="": refresh
    # nix
    statix {{ if fix != "" { "fix" } else { "check" } }}
    # clang-tidy over every translation unit, headers covered via
    # --header-filter. nixpkgs' clang-tools does not ship run-clang-tidy, and
    # xargs -P does the same job without the extra dependency. Fixes are
    # applied serially so two jobs cannot rewrite the same header at once.
    find src test bench docs/examples -type f -name "*.cc" -print0 \
      | xargs -0 -n1 -P {{ if fix != "" { "1" } else { "$(nproc)" } }} \
          clang-tidy -p . --quiet --header-filter='.*/(src|test|bench|docs)/.*' \
          {{ if fix != "" { "--fix --fix-errors" } else { "--warnings-as-errors=*" } }}
[group("Code Style")]
lint-fix: (lint "fix")
