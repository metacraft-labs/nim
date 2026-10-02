#!/usr/bin/env bash
# Entering this repository's dev shell from ANOTHER git repository writes
# nothing into that repository, and entering it from a subdirectory of this
# repository writes nothing into that subdirectory.
#
# The shell's hook links the workspace siblings the compiler build needs into
# `dist/`. It used to create `dist/` in whatever directory the shell was
# entered from, so `nix develop /path/to/codetracer-nim` run elsewhere left an
# untracked `dist/` behind, which blocks that repository's pre-push gate.
#
# Asserted, from a scratch git repository and a subdirectory of it: no file
# appears there, not even an empty directory. As the
# positive control, entered from this repository's `tests/` directory, the
# links land in this repository's top-level `dist/` and not in `tests/dist`.
#
#   bash tests/devshell/test_dev_shell_writes_nothing_elsewhere.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

git -C "$SCRATCH" init -q
git -C "$SCRATCH" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$SCRATCH/sub"

for dir in "$SCRATCH" "$SCRATCH/sub"; do
  ( cd "$dir" && nix develop "$REPO" --no-write-lock-file -c true ) >/dev/null 2>&1 \
    || fail "the dev shell did not start from $dir"
  [ -z "$(git -C "$SCRATCH" status --porcelain --ignored)" ] \
    || fail "entered from $dir: files were written into the other repository: $(git -C "$SCRATCH" status --porcelain --ignored | tr '\n' ' ')"
  # git status does not list empty directories.
  extra="$(cd "$SCRATCH" && find . -mindepth 1 -path ./.git -prune -o ! -path ./sub -print)"
  [ -z "$extra" ] || fail "entered from $dir: entries were created in the other repository: $(echo $extra)"
done

[ ! -e "$REPO/tests/dist" ] || fail "precondition: $REPO/tests/dist already exists"
( cd "$REPO/tests" && nix develop "$REPO" --no-write-lock-file -c true ) >/dev/null 2>&1 \
  || fail "the dev shell did not start from this repository"
[ ! -e "$REPO/tests/dist" ] || { rm -rf "$REPO/tests/dist"; fail "control: entered from tests/, dist/ was created in tests/"; }
[ -d "$REPO/dist" ] || fail "control: entered from tests/, this repository's dist/ is missing"

echo "PASS: the dev shell writes its dist/ links only into this repository's top level"
