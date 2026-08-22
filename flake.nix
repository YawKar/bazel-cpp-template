{
  description = "bazel-cpp-template";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      perSystem =
        { pkgs, ... }:
        let
          # Must track the LLVM major the Bazel toolchain ships (see
          # LLVM_VERSION in MODULE.bazel). Check with:
          #   jq -r '.[0].arguments[0]' compile_commands.json
          # The compile database spells out every include path, so the only
          # thing these tools bring themselves is their builtin resource dir;
          # a major mismatch there is where the subtle "clangd disagrees with
          # the build" bugs come from.
          llvm = pkgs.llvmPackages_22;

          # Bazel assumes an FHS layout in places we do not control: the cc
          # wrapper toolchains_llvm generates is `#!/bin/bash`, `run_shell`
          # actions shell out to /bin/bash, and --incompatible_strict_action_env
          # pins the action PATH to /bin:/usr/bin:/usr/local/bin. None of that
          # exists on NixOS.
          #
          # Rather than patch each assumption, give Bazel the FHS layout it
          # expects. Three things fall out of this:
          #   1. No toolchain patches and no BAZEL_SH.
          #   2. The action PATH is the stock /bin:/usr/bin:/usr/local/bin, so
          #      action keys are byte-identical to a Debian/Ubuntu host and one
          #      remote cache serves every machine.
          #   3. Bazel's real linux-sandbox becomes usable, instead of falling
          #      back to processwrapper-sandbox.
          #
          # This is named `bazel` and forwards its arguments to bazelisk, so
          # `bazel build //...` transparently runs inside the FHS environment.
          # bazelisk is deliberately NOT exposed on its own: invoking it
          # directly would escape this environment and fail confusingly.
          bazel = pkgs.buildFHSEnv {
            name = "bazel";
            runScript = "bazelisk";
            targetPkgs =
              p: with p; [
                # Bazel itself, plus the shared libraries loaded inside this
                # environment. Bazel's bundled JVM server needs libz; the
                # upstream LLVM release binaries are dynamically linked, and
                # ld.lld additionally needs libxml2 (check with the DT_NEEDED
                # entries of external/...llvm_toolchain_llvm/bin/ld.lld).
                bazelisk
                zlib
                # libxml2_13, not libxml2: the upstream LLVM binaries are built
                # against the libxml2 2.x ABI and load libxml2.so.2, whereas
                # current nixpkgs libxml2 (2.15) has bumped its SONAME to
                # libxml2.so.16. `.out` because the default output is `bin`,
                # which carries no shared library at all.
                libxml2_13.out
                stdenv.cc.cc.lib

                # The POSIX toolbox that genrules and `run_shell` actions
                # expect to find on the action PATH.
                bashInteractive
                coreutils
                diffutils
                findutils
                gawk
                gnugrep
                gnused
                gnutar
                gzip
                which
                zstd

                # git for git_override/git_repository fetches; python3 for the
                # compile-commands extractor's launcher.
                git
                python3
              ];

            # toolchains_llvm reads /etc/os-release to pick an LLVM tarball.
            # The wrapper normally symlinks the host's copy in, which works on
            # NixOS (it points into /nix/store, bound through) but dangles on
            # Ubuntu, where /etc/os-release is a relative symlink into
            # ../usr/lib -- and /usr belongs to this environment, not the host.
            # Shipping our own makes the lookup succeed on every host, and an
            # entry present in the rootfs suppresses the host symlink.
            extraBuildCommands = ''
              mkdir -p "$out/etc"
              cat > "$out/etc/os-release" <<'EOF'
              NAME=NixOS
              ID=nixos
              VERSION_ID="25.11"
              PRETTY_NAME="Bazel FHS environment"
              EOF
            '';
          };

          # nixpkgs ships clangd/clang-tidy as shell wrappers that export
          # C_INCLUDE_PATH and CPLUS_INCLUDE_PATH pointing at Nix's own glibc
          # and libc++. Clang honours those *in addition to* whatever
          # compile_commands.json says, so Nix headers get mixed into a
          # translation unit Bazel compiled against its own pinned headers --
          # two standard libraries in one parse.
          #
          # The unwrapped binaries are the same LLVM tools with no environment
          # injection: they take their include paths from the compile database
          # and nowhere else. That is what makes the Bazel/Nix split hold.
          #
          # Unwrapping alone is not enough, because those variables are read by
          # clang itself, not by the wrapper -- an unwrapped clangd inherits
          # them just as happily from whatever environment the editor was
          # launched in. So each tool is re-wrapped for the sole purpose of
          # clearing them, which makes the tools correct no matter who starts
          # them. Symptom when this is missing: "no member named 'abs' in
          # namespace 'std'; did you mean 'std::__math::abs'?" -- one libc++'s
          # math.h meeting another libc++'s <__math/abs.h>.
          clang-tools =
            pkgs.runCommand "clang-tools-unwrapped-${llvm.clang-tools.version}"
              { nativeBuildInputs = [ pkgs.makeWrapper ]; }
              ''
                mkdir -p "$out/bin"
                for tool in clangd clang-tidy clang-format clang-apply-replacements clang-query clang-include-cleaner; do
                  makeWrapper "${llvm.clang-tools}/bin/$tool-unwrapped" "$out/bin/$tool" \
                    --unset C_INCLUDE_PATH \
                    --unset CPLUS_INCLUDE_PATH \
                    --unset CPATH \
                    --unset OBJC_INCLUDE_PATH \
                    --unset OBJCPLUS_INCLUDE_PATH
                done
              '';
        in
        {
          # mkShellNoCC on purpose: this shell must never put a compiler, a libc
          # or an LD_LIBRARY_PATH on the environment. Bazel downloads and pins
          # its own clang/lld/libc++ (see MODULE.bazel); a Nix compiler in scope
          # would only compete with it and leak /nix/store paths into
          # compile_commands.json.
          #
          # Rule of thumb for this list: things you *run* interactively belong
          # here; things that *build the code* belong in MODULE.bazel.
          devShells.default = pkgs.mkShellNoCC {
            nativeBuildInputs = [
              bazel

              # C++ tooling that only ever reads compile_commands.json:
              # clangd, clang-tidy, clang-format. Never compiles anything.
              clang-tools
              llvm.lldb

              # LLVM analysis tools for poking at what the build produced:
              # llvm-objdump / llvm-mca for assembly, llvm-nm / llvm-readelf /
              # llvm-size for object inspection, llvm-cxxfilt for demangling
              # (genhtml uses it), llvm-symbolizer for stack traces. Analysis
              # only -- this package carries no compiler.
              llvm.llvm
            ]
            ++ (with pkgs; [
              # nix user experience
              bashInteractive

              # Syntax highlighting and paging for `just asm` / `just asm-src`.
              # Reading a few thousand lines of x86 without it is miserable.
              bat

              # coverage reporting: genhtml renders the lcov tracefile that
              # `bazel coverage --combined_report=lcov` produces.
              lcov

              # interactive debugging / profiling
              gdb
              valgrind
              heaptrack

              # API docs: `just docs`. graphviz is not optional here -- the
              # Doxyfile sets HAVE_DOT, and without dot on PATH doxygen warns,
              # which WARN_AS_ERROR turns into a failure.
              doxygen
              graphviz
              # `just docs` opens the rendered page.
              xdg-utils

              # repo maintenance
              buildifier
              pre-commit
              just
              jq
              git

              # formatters / linters for the non-C++ files
              nixfmt
              statix
              yamlfmt
            ]);

            # The Doxyfile reads this as $(DOXYGEN_AWESOME_CSS). Keeping the
            # store path in the environment rather than in the tracked config
            # means the theme stays pinned by flake.lock and the Doxyfile stays
            # readable to anyone who does not use Nix.
            DOXYGEN_AWESOME_CSS = "${pkgs.doxygen-awesome-css}/share/doxygen-awesome-css";

            shellHook = ''
              # Hooks are declared in .pre-commit-config.yaml; commit-msg needs
              # its own hook type or the message-format check never runs.
              pre-commit install --overwrite \
                --hook-type pre-commit --hook-type commit-msg >/dev/null

              echo "[FLAKE] DevShell for bazel-cpp-template development is loaded!"
              echo "        bazel  -> $(bazel version 2>/dev/null | grep -m1 'Build label' || echo 'from .bazelversion')"
              echo "        clangd -> $(clangd --version | head -1)"
            '';
          };
        };
    };
}
