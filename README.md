# bazel-cpp-template

A C++20 project template built on one rule: **Bazel owns the build, Nix owns the
tools.** Bazel downloads and pins its own clang, lld, libc++, sysroot and JDK, so
a build is reproducible on any machine with `bazelisk` and nothing else. Nix
supplies the things you *run* — clangd, clang-format, doxygen, gdb — and never
touches what gets compiled.

Everything below explains why a given piece is there. The last section is the one
worth reading before you build something real on this: it lists the sharp edges
that are known and deliberate.

## Quick start

```sh
nix develop          # dev shell: bazel, clangd, formatters, docs, debuggers
just                 # list every recipe
just build           # bazel build //...
just test            # bazel test //...
just refresh         # regenerate compile_commands.json for your editor
```

Without Nix, on any Linux box with `bazelisk`:

```sh
bazelisk test //...
```

That second command is the point of the whole design, and CI enforces it — the
build jobs install no compiler and no Nix.

## What it uses, and why

### Bazel with bzlmod, no `WORKSPACE`

Dependencies live in `MODULE.bazel` and resolve through the Bazel Central
Registry. `MODULE.bazel.lock` is committed; CI runs with
`--lockfile_mode=error`, so a resolution that does not match the lockfile fails
the build instead of silently drifting.

### A pinned LLVM toolchain, and no gcc anywhere

`toolchains_llvm` downloads a fixed upstream LLVM release (`LLVM_VERSION` in
`MODULE.bazel`) and registers clang, lld, libc++ and compiler-rt as the toolchain.
`BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1` stops Bazel from probing the host for
`cc`/`gcc` — without it, Bazel builds an implicit `local_config_cc` toolchain from
whatever compiler happens to be installed, which "works" by accident on one
machine and produces cache entries nobody else can reuse.

`--incompatible_strict_action_env` scrubs the client environment out of actions,
so `PATH`, `LD_LIBRARY_PATH` and locale cannot leak into an action key.

Together these mean an action key computed on your laptop is valid on a CI runner
or a remote executor. Point `--remote_cache` at a shared instance (see the
commented block in `.bazelrc`) and every host lands in the same cache pool.

### Nix, and the FHS environment

Bazel assumes an FHS layout in places you do not control: the cc wrapper
`toolchains_llvm` generates starts with `#!/bin/bash`, `run_shell` actions shell
out to `/bin/bash`, and strict action env pins the action `PATH` to
`/bin:/usr/bin:/usr/local/bin`. None of that exists on NixOS.

Rather than patch each assumption, `flake.nix` runs Bazel inside
`pkgs.buildFHSEnv`. The wrapper is named `bazel` and forwards to `bazelisk`, so
`bazel build //...` transparently runs inside that environment. Three things fall
out of it:

1. No toolchain patches and no `BAZEL_SH`.
2. The action `PATH` is the stock FHS one, so action keys are byte-identical to a
   Debian or Ubuntu host — one cache serves every machine.
3. Bazel's real `linux-sandbox` becomes usable instead of falling back to
   `processwrapper-sandbox`.

`bazelisk` is deliberately *not* exposed on its own; calling it directly would
escape the environment and fail confusingly.

### clang-tools, unwrapped and then re-wrapped

nixpkgs ships `clangd` and `clang-tidy` as shell wrappers that export
`C_INCLUDE_PATH` and `CPLUS_INCLUDE_PATH` pointing at Nix's own libc++. Clang
honours those *in addition to* `compile_commands.json`, so Nix headers get mixed
into a translation unit Bazel compiled against its own pinned headers — two
standard libraries in one parse.

The dev shell uses the `-unwrapped` binaries, then re-wraps each one for the sole
purpose of clearing those variables. Unwrapping alone is not enough: the variables
are read by clang itself, not by the wrapper, so an unwrapped clangd inherits them
just as happily from whatever environment your editor was launched in.

The symptom, if this ever regresses:

```
no member named 'abs' in namespace 'std'; did you mean 'std::__math::abs'?
```

That is one libc++'s `math.h` meeting another libc++'s `<__math/abs.h>`.

### compile_commands.json via hedron

`just refresh` runs the compile-commands extractor. No post-processing is needed:
the toolchain names every system include path on the command line, so the database
is self-contained and contains no host or `/nix/store` path.

### Warnings, scoped

`-Wall -Wextra -Wpedantic -Wshadow -Wconversion` apply to first-party code only,
via `--per_file_copt`. `-Werror` applies to `//src` alone — tests and benchmarks
warn but do not fail. Applying these globally would drown the build in warnings
from googletest and abseil, which we neither own nor want to patch.

`layering_check` enforces that every `#include` is backed by a declared dep.

### Sanitizers, coverage, docs, assembly

| Command | What it does |
| --- | --- |
| `just test --config=asan` | ASan + UBSan |
| `just test --config=tsan` | ThreadSanitizer |
| `just build --config=release` | `-O3 -DNDEBUG -flto=thin` |
| `just coverage` | clang source-based coverage → `coverage-html/` |
| `just docs` | Doxygen API docs → `docs/html/` |
| `just asm TARGET [FILTER]` | disassemble the built artifact, source interleaved |
| `just asm-src TARGET` | the compiler's own `.s`, before the assembler |

Coverage is clang's source-based instrumentation, not gcov: the pinned LLVM ships
`libclang_rt.profile`, `llvm-cov` and `llvm-profdata`, so it needs nothing from
the host. `--instrumentation_filter=^//src` keeps your dependencies out of the
report.

Docs are a build gate, not a formality. `WARN_AS_ERROR = FAIL_ON_WARNINGS` means
an undocumented public function, a `@param` naming an argument that no longer
exists, or a stale `@snippet` marker all fail `just docs-check`, which CI runs.

Examples shown in the docs are pulled from `docs/examples/` with `@snippet`, and
those files are real `cc_test` targets. Prose examples rot silently; these are
compiled and asserted by `bazel test //...`, so an API change breaks the build
instead of leaving a plausible lie on the docs page. Deleting an example breaks
the docs build too.

`just asm` and `just asm-src` answer different questions: the first disassembles
the finished binary (after inlining and register allocation), the second shows
what the compiler emitted. `--config=asm` is optimised like release but
deliberately *without* ThinLTO — under LTO the objects hold bitcode and code moves
across translation units, so per-function assembly stops corresponding to any one
source file.

### CI

Three jobs. `build-and-test` runs the ASan, TSan and Release configurations on
bare `bazelisk` with no Nix — which also serves as the standing guarantee that the
Bazel build never grows a Nix dependency. `coverage` uploads an lcov tracefile.
`checks` is the only job that installs Nix, and runs format, lint and docs from the
same dev shell you use.

## Layout

```
src/lib/        library code — the only place -Werror applies
test/           googletest
bench/          google/benchmark
docs/examples/  compiled examples, pulled into the docs with @snippet
config/         config_setting targets for select() branching
tools/          build tooling
```

## Concerns for later use

These are known, deliberate, and will bite eventually. Read this section before
building something large on the template.

**The LLVM version is pinned in two places and they must agree.** `LLVM_VERSION`
in `MODULE.bazel` sets what Bazel compiles with; `llvmPackages_22` in `flake.nix`
sets which clangd and clang-tidy you get. A major-version mismatch between them is
where subtle "clangd disagrees with the build" bugs come from. Change one, change
the other.

**The sysroot sets a hard floor on which glibc symbols you can use.** The build
pins Chromium's Debian bullseye sysroot (glibc 2.31) so binaries run on any
still-supported distribution. But Chromium's sysroots deliberately *demote* most
glibc symbols newer than their ABI floor — 2.26 for bullseye — from a default
version to a non-default one. 143 of the 2358 exported symbols are demoted:
`copy_file_range` appears as `@GLIBC_2.27` where a stock glibc has
`@@GLIBC_2.27`. A non-default version cannot satisfy a plain undefined
reference, so any dependency reaching for one of them fails at link time with:

```
undefined symbol: copy_file_range
>>> did you mean: copy_file_range@GLIBC_2.27
```

This is not a glibc-version problem and upgrading to a newer Chromium sysroot does
**not** fix it — the demotion is policy, and bullseye demotes `copy_file_range`
just as stretch did. Concretely, `std::filesystem::copy_file` in libc++ calls
`copy_file_range`, which is enough to block Google FuzzTest's coverage-guided
mode. If you hit this, you need a sysroot from somewhere other than Chromium.

The demotion list is not simply "everything past the floor" — `memfd_create` is
`@@GLIBC_2.27`, a default version, and links fine. Check the symbol you actually
need before assuming it is blocked:

```sh
llvm-nm -D --defined-only <sysroot>/lib/x86_64-linux-gnu/libc.so.6 | grep -w memfd_create
```

Bullseye is the newest amd64 sysroot Chromium publishes; the full list lives in
`build/linux/sysroot_scripts/sysroots.json` in the Chromium tree. Note the
download URL is content-addressed (`<prefix>/<sha256>`, no filename), which is
why the hash appears twice in `MODULE.bazel`.

**`--per_file_copt` regexes are unanchored.** `//src/.*` also matches
`@@protobuf+//src/google/protobuf/...`, because that is a real package in a real
dependency. Add a dependency whose layout resembles ours and our `-Werror` lands
on code we do not own. Anchor them with `^` (`^//src/.*`) the first time this
bites.

**`layering_check` is set globally.** It therefore applies to every external
dependency too, holding third-party code to a policy it never opted into. Some
libraries legitimately include each other's private headers. When that blocks you,
move the feature out of `.bazelrc` and into
`package(features = ["layering_check"])` in each of our own `BUILD` files.

**`parse_headers` and the compile-commands extractor do not get along.** Some
dependencies (abseil) enable `parse_headers`, which emits header-only
`-xc++-header -fsyntax-only` actions. The hedron extractor asserts on those
because they carry no source file, and `just refresh` dies. The fix is
`--features=-parse_headers` *and* `--host_features=-parse_headers` — the second is
easy to miss, because `--features` does not reach exec-configuration actions.

**CI disk is the binding constraint.** The extracted LLVM distribution alone is
~12 GB against a GitHub runner's ~14 GB of free space, which is why every job
starts by deleting the preinstalled SDKs it does not need. Adding a heavy
dependency can push a job over the edge, and the failure reads as an unrelated
"no space left on device".

**The dev shell needs unprivileged user namespaces.** The FHS environment is
bubblewrap. Ubuntu 24.04 sets `kernel.apparmor_restrict_unprivileged_userns=1`,
which hands back a namespace with no capabilities in it, so `bwrap` fails writing
`uid_map`; CI lifts it with a `sysctl`. This is fine on a GitHub runner with
passwordless sudo, and a real problem inside a restricted container.

**Your editor must get clangd from the dev shell.** If anything else puts a
`clangd` earlier on `PATH` — a Neovim/nixvim wrapper bundling its own
`clang-tools` is the classic case — you get the two-standard-libraries error
described above, and no amount of `just refresh` will help. Check with
`vim.fn.exepath("clangd")` or the equivalent, not with `which clangd` in a
terminal.

**Local constants must be named `kCamelCase`.** `.clang-tidy` sets
`ConstantCase: CamelCase` with prefix `k`, and clang-tidy's notion of a constant
includes function-local `const` and `constexpr` variables — Google style only
applies `k` to static-storage constants. `const` *parameters* are pinned
separately to plain `lower_case`; without that pin they inherit the rule and
clang-tidy starts demanding `greet(const std::string_view kName)`.

**Doxygen emits nothing for an undocumented namespace.** With `EXTRACT_ALL = NO`,
members of a namespace that has no comment of its own are silently skipped — you
get a green `docs-check` over an empty docs tree. If you add a namespace, document
the namespace itself, then confirm the members actually appear.

**`--config=native` is opt-in and must stay that way.** `-march=native` bakes the
build machine's CPU into the output, making artifacts non-portable and poisoning a
shared cache with host-specific entries. It is deliberately not part of
`--config=release`.

**The disk cache grows without bound.** `--disk_cache=~/.cache/bazel-disk` has no
eviction policy. Prune it yourself occasionally.

**`hedron_compile_commands` is pinned by commit, not version.** It is fetched with
`git_override`, so fetching it needs `git` on the action `PATH` (the FHS
environment provides it), and updating means bumping a commit hash by hand.
