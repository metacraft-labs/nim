# codetracer-nim — common build & test recipes
#
# Prereq: enter the flake's dev shell first
#     nix develop          # one-off
#     # or:  direnv allow  (with `use flake` in .envrc)
#
# Assumes the standard sibling-repo `dist/` layout. After CTFS-M1, the
# compiler links against `dist/codetracer-trace-format-nim`. Run
# `just bootstrap-dist-symlinks` to (re)create the symlinks if they
# are missing; the recipe is idempotent.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Default target: list recipes.
default:
    @just --list

# ---------------------------------------------------------------------
# Build

# Bootstrap a fresh release nim: compile koch with the host nim, then
# use koch to bootstrap bin/nim in release mode.
build-nim:
    nim c koch
    ./koch boot -d:release

# ---------------------------------------------------------------------
# Testing

# Run the full testament suite. Testament defaults to `nproc - 1`
# workers, which is fine on the 32-core host.
test-all:
    ./koch tests all

# Run a specific testament category, e.g. `just test sourcemap`.
test category:
    ./koch tests cat {{category}}

# Run the sourcemap category (our main focus given the V3 series).
test-sourcemap:
    ./koch tests cat sourcemap

# Run the vm category.
test-vm:
    ./koch tests cat vm

# Curated fast subset suitable for pre-push.
check:
    ./koch tests cat sourcemap
    ./koch tests cat vm

# Remove stale build artefacts. CTFS-M1 review noted that stale
# nimcache/build_* dirs can cause spurious test failures.
test-clean:
    rm -rf nimcache build_all_*.json testresults
    find . -maxdepth 3 -type d -name nimcache -prune -exec rm -rf {} +
    find . -maxdepth 3 -type d -name "build_*" -prune -exec rm -rf {} + 2>/dev/null || true
    @echo "Cleaned nimcache/build_* artefacts."

# ---------------------------------------------------------------------
# Repo bootstrap

# Create the sibling-repo `dist/` symlinks the build expects. Skips
# any that already point to an existing target.
bootstrap-dist-symlinks:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p dist
    workspace="$(realpath ..)"
    for repo in codetracer-trace-format-nim nim-stew nim-results; do
        target="${workspace}/${repo}"
        link="dist/${repo}"
        if [[ -e "${link}" || -L "${link}" ]]; then
            echo "[bootstrap] ${link} already exists, skipping"
            continue
        fi
        if [[ ! -e "${target}" ]]; then
            echo "[bootstrap] WARN: ${target} not found, cannot symlink"
            continue
        fi
        ln -s "${target}" "${link}"
        echo "[bootstrap] linked ${link} -> ${target}"
    done
