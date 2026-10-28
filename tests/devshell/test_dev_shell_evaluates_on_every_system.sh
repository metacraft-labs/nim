#!/usr/bin/env bash
# This repository's dev shell evaluates on every system the flake lists.
#
# `flake.nix` declares `devShells.<system>.default` for Linux and Darwin
# alike, but the package list once named `valgrind`, which nixpkgs marks
# broken on Darwin, unconditionally. `nix develop` on a Mac then refused to
# evaluate the shell at all, so none of the justfile recipes could be run as
# written there.
#
# Asserted: for each system in `devShells`, the shell's derivation path
# evaluates. Evaluation is pure and needs no builder for the target system,
# so this checks the Linux shells from a Mac and the Darwin shells from Linux
# equally. Nix reports only the first refused package per system, so the
# check is per system and names the error it got.
#
#   bash tests/devshell/test_dev_shell_evaluates_on_every_system.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

systems="$(nix eval --no-write-lock-file --raw "$REPO#devShells" \
  --apply 'shells: builtins.concatStringsSep " " (builtins.attrNames shells)')" \
  || fail "could not list the flake's devShells"
[ -n "$systems" ] || fail "the flake declares no devShells"

failed=""
for system in $systems; do
  if out="$(nix eval --no-write-lock-file --raw \
      "$REPO#devShells.$system.default.drvPath" 2>"$ERR")"; then
    echo "ok: $system -> $out"
  else
    echo "FAIL: devShells.$system.default does not evaluate:" >&2
    # The message follows Nix's trace frames; print it and its reasons.
    grep -E 'Refusing to evaluate|^ *- (broken|unsupported|insecure|unfree)' "$ERR" >&2 \
      || tail -5 "$ERR" >&2
    failed="$failed $system"
  fi
done

[ -z "$failed" ] || fail "the dev shell does not evaluate on:$failed"
echo "PASS: the dev shell evaluates on every listed system ($systems)"
