discard """
  cmd: "nim e $file"
  targets: "e"
"""

## CTFS-M1 demonstrator (bootstrap path).
##
## No `evalTrace` field — default-on snapshot diffing. The first time this
## test is run, the harness:
##   1. Materializes the .ct trace produced by `nim e --trace:...`
##      via `codetracer_ct_print_lib.buildFullDocument` (imported directly,
##      no subprocess).
##   2. Writes the JSON to `tctfs_bootstrap_demo.nim.evaltrace.json` (sibling).
##   3. Fails the test with a `[CTFS] snapshot bootstrap` message so CI / a
##      reviewer notices.
##
## The parent assistant audits each bootstrap snapshot before commit per the
## spec's verification gate; CTFS-M2 generates the first real batch.
##
## See: codetracer-specs/Nim-Compiler-Patches.md
## § "CTFS / VM Tracing Coverage" → "CTFS-M1".

let x = 1 + 2
echo x
