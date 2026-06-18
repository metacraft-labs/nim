# CodeTracer examples — Nim compile-time tracer

Small Nim programs designed to be recorded and replayed with
[CodeTracer](https://github.com/metacraft-labs/codetracer) using
**codetracer-nim**, this fork's compile-time tracer. Each example takes
seconds to capture and produces a self-contained `.ct` trace you can
scrub through in the GUI.

## Prerequisites

- `ct` (the CodeTracer CLI) on your `PATH`.
- A `codetracer-nim` build from this repo. The latest
  `feature/column-aware-replay-navigation` branch produces column-aware
  traces (the fix landed in `Column-Aware-Replay: emit per-column steps
  from the Nim VM tracer`); older Nim builds will still record but will
  collapse multi-statement lines into a single step.
- Optional but recommended: a terminal that can render the GUI launched
  by `ct replay` (X11 / Wayland / macOS).

## The workflow in two flavours

CodeTracer offers a two-step and a one-step entry point. Both produce
the same `.ct` trace directory; the difference is just whether the GUI
opens automatically.

### Two-step: record, then replay

```sh
ct record examples/codetracer/hello.nim     # produces hello.ct/
ct replay -t hello.ct                       # opens the GUI on that trace
```

`ct record` invokes the codetracer-nim compiler under the hood, runs
the program through the Nim VM, and writes the trace to `<name>.ct/`
next to the source file. `ct replay -t <trace>` reopens any trace
later — useful for sharing a `.ct` directory with a teammate or
re-examining a failure days after the fact.

### One-step: record and open in one go

```sh
ct run examples/codetracer/hello.nim
```

`ct run` is the convenience wrapper: record, then immediately replay.
Use this for fast iteration; switch to `record` + `replay` when you
want to archive or share the trace.

## Examples in this directory

| File | What it shows |
| ---- | ------------- |
| [`hello.nim`](./hello.nim) | Smallest program — single proc, a couple of locals, one `echo`. |
| [`factorial.nim`](./factorial.nim) | Recursion — each call becomes its own frame in the call tree. |
| [`column_aware.nims`](./column_aware.nims) | Multi-statement line + sub-expressions — the column-aware fixture below. |

Each program is a few lines long and has no external dependencies
beyond the standard library; they exist to be opened, stepped, and
discarded.

## Walkthrough: column-aware step-over

This is the headline capability that just landed on
`feature/column-aware-replay-navigation`. The end-to-end regression
test lives at
[`tests/sourcemap/tvm_trace_column_aware.nim`](../../tests/sourcemap/tvm_trace_column_aware.nim)
and the example script in this directory mirrors its payload:

```nim
var a = 1; var b = 2; var c = 3
echo a, " ", b, " ", c
```

Three `var` statements share a single source line. Pre-extension, the
Nim VM tracer keyed steps on `(file, line)` only, so the whole line
collapsed to one step in the GUI — you could not step *between* `a`,
`b`, and `c`. Post-extension, the tracer keys on `(file, line, col)`
and the writer carries a per-path line-length table so the reader can
round-trip every column.

Try it:

```sh
ct run examples/codetracer/column_aware.nims
```

In the GUI, hit "step over" repeatedly on line 1. You should see the
position cursor advance through multiple distinct columns on the same
line — **7 or more** in practice, not just the three you'd expect from
the `var` keywords. That's because Nim's `vmgen` tags each
sub-expression opcode (the `1`, `2`, `3` literals; the assignment
targets; the implicit semicolon-statement boundaries) with its own
column, so the trace surfaces sub-statement granularity for free.

The regression test asserts the floor (`≥ 3 distinct columns on line
1`, one per `var` keyword); in the GUI you typically observe the
higher number, which is the user-visible payoff of column keying:
**sub-expression step resolution on packed lines, even inside CTFS /
`nim e` execution.**

## Where to go from here

- The full set of compile-time tracer regression tests lives under
  [`tests/sourcemap/`](../../tests/sourcemap/) — many of them double
  as miniature examples (exceptions, closures, complex values, macro
  expansion, etc.). Read the `discard """ ... """` header for what
  each one demonstrates.
- The replay format is documented inside the
  `dist/codetracer-trace-format-nim` submodule that this repo vendors;
  see its README for the binary layout if you want to write your own
  consumer of the `.ct` directory.
- `ct --help` lists the rest of the CLI (filters, snapshot export,
  remote replay, …).
