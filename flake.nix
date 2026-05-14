# Reproducible dev shell for building Nim from source and running the
# test suite.
#
# Role: provide every system-level dependency required by `./koch boot`
# and by the testament categories we care about (sourcemap, vm, async,
# stdlib, etc.) without falling back on host-provided packages.
#
# Motivation: CTFS-M1 made libzstd a link-time requirement for `bin/nim`
# itself. The compiler now links against codetracer_trace_writer (built
# from dist/codetracer-trace-format-nim), and that library calls into
# `<zstd.h>` with `{.passL: "-lzstd".}`. Without zstd dev headers + lib
# on the C compiler's search path, `./koch boot` fails. The metacraft
# workspace flake at ../flake.nix does not provide zstd, so this flake
# stands on its own.
#
# See spec §3 in codetracer-specs for the rationale (commit prefix
# `nix:` is reserved for test-infrastructure commits so they are
# trivially filterable when cherry-picking milestones upstream).
#
# Usage:
#   nix develop
#   ./koch boot -d:release
#   just test-sourcemap
{
  description = "Dev shell for building and testing codetracer-nim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          isLinux = pkgs.stdenv.isLinux;
        in
        {
          default = pkgs.mkShell {
            name = "codetracer-nim-dev";

            # Compilers and build tools. zstd appears in `packages`
            # rather than `buildInputs` so its bin is on $PATH too; pkgs
            # of dev-output (zstd.dev, curl.dev, ...) populate the C
            # compiler include + library search paths automatically via
            # the stdenv setup hooks.
            packages = with pkgs; [
              # Toolchain
              gcc
              pkg-config
              gnumake
              git
              just

              # CTFS-M1: required to link bin/nim itself.
              zstd
              zstd.dev

              # System libraries used by testament categories.
              curl.dev
              boehmgc.dev
              openssl.dev
              pcre
              blas
              lapack
              SDL
              sfml   # nixpkgs renamed SFML -> sfml on unstable

              # Test tools
              valgrind
              gdb
              nodejs
              python3
            ] ++ pkgs.lib.optionals isLinux [
              # X11 headers (xorg category in testament). On unstable
              # the package was renamed from `xorg.libX11` to `libx11`.
              libx11.dev
            ];

            # Libraries that Nim code dlopen()s at runtime (rather than
            # link against statically). testament and the stdlib net
            # modules dlopen libcrypto/libssl by SONAME, so they must
            # be discoverable via LD_LIBRARY_PATH.
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (with pkgs; [
              openssl
              pcre
              curl
              zstd
              boehmgc
            ]);

            shellHook = ''
              # Show that the dev shell is active.
              echo "[codetracer-nim] dev shell active"
              echo "[codetracer-nim] zstd: $(${pkgs.zstd}/bin/zstd --version 2>&1 | head -1)"
              echo "[codetracer-nim] gcc:  $(${pkgs.gcc}/bin/gcc --version | head -1)"
              echo "[codetracer-nim] Run 'just' to see available recipes."
            '';
          };
        });
    };
}
