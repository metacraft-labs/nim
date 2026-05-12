# RFC: Clock Injection Hook for `std/asyncdispatch`

## Status

Draft for `nim-lang/RFCs`. Not yet filed upstream — this document is
the basis for a future RFC issue, drafted while validating the
mechanism in the `metacraft-labs/codetracer-nim` fork on the
`clock-injection-hook` branch.

A sister RFC for `nim-chronos` (proposing the same mechanism for the
companion async library) was drafted earlier; the chronos hook is
already prototyped in `metacraft-labs/nim-chronos` and provides prior
art for the design.

## Motivation

Async code is notoriously difficult to test deterministically. The most
common pattern in production async test suites — sprinkling
`await sleepAsync(...)` and `withTimeout(...)` with generous
tolerances — produces tests that are slow, flaky, and incapable of
exercising edge cases (e.g. "what happens when a timer fires at exactly
the same moment a future resolves?").

The industry-standard fix is to inject the clock. Tokio's
`time::pause()` / `time::advance()` does this for Rust; Java's
`Clock.fixed` / `Clock.offset`; Go's `clockwork` library; .NET's
`TimeProvider`. In each case the test installs a deterministic clock
source, drives events in controlled order, and asserts on a fully
synchronous timeline.

`std/asyncdispatch` does not currently expose any way to override its
clock reads. The audit for this RFC (see references) found that the
module reads `std/monotimes.getMonoTime()` at exactly six call sites
across three procs:

| Proc           | Lines        | Purpose                                                      |
| -------------- | ------------ | ------------------------------------------------------------ |
| `processTimers`| 254, 263     | Timer-wheel pop + next-deadline computation for `poll`.      |
| `drain`        | 1701, 1704   | `drain(timeout)`'s elapsed-budget accounting.                |
| `sleepAsync`   | 1926, 1929   | `finishAt` computation for `sleepAsync(ms)` / `sleepAsync(f)`. |

`withTimeout` (lines 1932-1967) does *not* read the clock itself — it
composes `sleepAsync(timeout)` with a callback race, so it inherits
fake-time-coverage for free once `sleepAsync` is hooked. The companion
modules `lib/pure/asyncfutures.nim` (516 LOC) and
`lib/pure/asyncmacro.nim` (396 LOC) contain no clock reads.

A single redirection point therefore covers timer scheduling, the
`poll` deadline, `drain`'s elapsed-budget tracking, `sleepAsync`'s
`finishAt` computation, and (transitively) `withTimeout` in one
stroke.

The downstream consumer is `metacraft-labs/nim-everywhere`, a
cross-target Nim platform library used by IsoNim apps that need
backend-neutral async primitives. Its `FakeAsyncContext` already
provides fake-time for code that routes through its `sleepFor`
facade; the asyncdispatch hook extends the same fake clock to
asyncdispatch's own timer wheel, so code that directly calls
`asyncdispatch.sleepAsync` / `asyncdispatch.withTimeout` /
`asyncdispatch.addTimer` is also covered without any user-code
discipline.

## Proposed change

Add a threadvar holding an optional clock source, plus two procs to
install / clear it. Gate the entire mechanism behind
`-d:asyncdispatchClockHook` so default builds are byte-identical to
current upstream (modulo a handful of file:line-number constants in
embedded `assert` / `raise` strings; see "Performance and identity"
below).

```diff
+when defined(asyncdispatchClockHook):
+  var customMonoTimeSource {.threadvar.}: proc(): MonoTime {.gcsafe.}
+
+  proc setMonoTimeSource*(source: proc(): MonoTime {.gcsafe.}) =
+    ## Override the monotonic-clock source consulted by asyncdispatch
+    ## for the current thread. Pass `nil` to restore the default
+    ## `std/monotimes.getMonoTime`.
+    customMonoTimeSource = source
+
+  proc clearMonoTimeSource*() {.inline.} =
+    customMonoTimeSource = nil
+
+  template currentMonoTime(): MonoTime =
+    (if customMonoTimeSource != nil:
+       customMonoTimeSource()
+     else:
+       getMonoTime())
+
 # ... at each of the 6 call sites:
-let t = getMonoTime()
+let t = (when defined(asyncdispatchClockHook): currentMonoTime() else: getMonoTime())
```

Total diff: 33 lines added, 6 lines changed (the 6 call-site
substitutions). Lives entirely in `lib/pure/asyncdispatch.nim`. No
changes to `asyncfutures.nim`, `asyncmacro.nim`, or `monotimes.nim`.

## Use case

A fake-time test using both nim-everywhere and the asyncdispatch hook
looks like:

```nim
import std/asyncdispatch, nim_everywhere

let ctx = newFakeAsyncContext()
ctx.install()                          # also calls setMonoTimeSource(...)
defer: ctx.uninstall()                 # also calls clearMonoTimeSource()

let slowFut = asyncdispatch.sleepAsync(200)
let timed   = asyncdispatch.withTimeout(slowFut, 50)

ctx.advance(50)
drainPlatformCallbacks()
check timed.read == false              # timeout fired, synchronously
```

The `install` proc registers a clock source that reads
`MonoTime() + initDuration(nanoseconds = ctx.nowMs * 1_000_000)`.
asyncdispatch's `processTimers` then sees the fake clock advance and
fires the right callbacks, in the right order, without any real
sleeping.

## Performance and identity

In the un-gated build (`-d:asyncdispatchClockHook` not set):

- The `when defined(asyncdispatchClockHook):` block compiles out
  entirely; no `setMonoTimeSource` / `clearMonoTimeSource` /
  `customMonoTimeSource` / `currentMonoTime` symbols are emitted.
- Each of the 6 call sites' `when defined(...)` expression reduces to
  the same single `getMonoTime()` call as upstream after constant
  folding.
- Resulting object file is functionally byte-identical to upstream.
  The only differences in the generated `asyncdispatch.nim.c` are
  file:line-number constants embedded in `assert` / `raise` strings:
  the gated `-d:release` build of a minimal asyncdispatch consumer
  produced a single `.rodata` change (one occurrence of
  `"asyncdispatch.nim(1230, "` shifts to `"asyncdispatch.nim(1264, "`
  because the patch adds 34 lines before that assert) and a single
  `.text` change (one `mov` immediate, `raiseExceptionEx`'s line
  argument: `0x57a` → `0x59c`). No symbol-table changes, no
  code-path differences, identical object-file size. Verified by
  stashing the patch and rebuilding with the same `--lib:` redirect;
  the only differences in `objdump -t / -d / -s -j .rodata` between
  the two `.o` files are the two changes listed. Debug builds may
  emit additional file:line strings for other asserts in the file,
  but the same logic applies — they shift mechanically by 34 lines
  with no functional impact.

In the gated build (`-d:asyncdispatchClockHook` set, source NOT
installed):

- One threadvar load + one nil-compare + one not-taken branch per
  clock read. On x86-64 with TLS-aware glibc this is ~2-3 cycles.
  asyncdispatch reads the clock O(callbacks fired) times, not O(events
  polled) — the overhead is invisible at any practical workload.

In the gated build with a source installed:

- One threadvar load + one nil-compare + one taken branch + one
  indirect call. Still O(1); cost dominated by the user-supplied
  source proc, not by the dispatch.

## API alternatives considered

**Compile-time clock injection** (e.g. a generic `Clock` type
parameter on the global dispatcher). Rejected: tests need to install
/ uninstall the fake clock dynamically. One test binary may have both
fake-time tests and real-time tests; a `when` switch forces the build
to pick one. A threadvar is per-thread, dynamic, zero cost when
unset — strictly better.

**Module-level mocking** (an `asyncdispatch_test` shim that overrides
the 6 `getMonoTime` reads). Rejected: asyncdispatch's API is used
reflectively in many places (`addTimer`, `withTimeout`, `sleepAsync`,
the timer wheel, `drain`'s elapsed budget); a shim would have to patch
every internal call site. The proposed hook lives at all 6 chokepoints
they all funnel through — minimal surface area, maximum coverage.

**Hook `std/monotimes` directly** (override `getMonoTime` itself,
affecting the whole program). Rejected: that would interfere with
unrelated stdlib consumers (e.g. user code that times its own
operations alongside an asyncdispatch test). The hook needs to be
scoped to asyncdispatch.

**Public time-of-day getter** (a `var clockNow: proc()` exposed at
module scope). Rejected: globally-scoped (not per-thread), wouldn't
compose with multi-threaded asyncdispatch consumers.

## Backwards compatibility

Zero breakage. The hook is additive:

- New public procs (`setMonoTimeSource`, `clearMonoTimeSource`) only
  when `-d:asyncdispatchClockHook` is set.
- All existing proc signatures (`processTimers`, `drain`,
  `sleepAsync`, `poll`, `runOnce`, `withTimeout`) are unchanged.
- Behaviour with the flag unset is functionally byte-identical to
  current upstream (the only differences are file:line-number debug
  strings, as documented above).
- Behaviour with the flag set but no source installed is
  observationally identical to current upstream (same return value,
  just a few cycles slower).

## Cross-Nim-version stability

The patch touches code that has been stable across Nim 1.6 → 2.0 →
2.2:

```
$ git log --oneline lib/pure/asyncdispatch.nim | wc -l
# Substantive changes per release: roughly 1-2.
```

The 6 call sites have not moved since Nim 1.4 (`getMonoTime` was
introduced in 1.0; the asyncdispatch timer-wheel design has been
stable). Re-applying the patch against future Nim releases is
mechanical.

## References

- Audit:
  `codetracer-specs/Front-Ends/IsoNim/nim-everywhere-Async-Fork.md`
  § 2 (asyncdispatch clock-touching code audit) + § 5 (proposed hook
  points).
- Sister RFC (chronos):
  `metacraft-labs/nim-chronos/RFC-clock-injection-hook.md`,
  implementation merged on `clock-injection-hook` branch.
- Downstream consumer: `metacraft-labs/nim-everywhere`
  (https://github.com/metacraft-labs/nim-everywhere) —
  `FakeAsyncContext` and its `asyncdispatch_fake_clock.nim` wiring
  module.
- Tokio's analogous mechanism:
  https://docs.rs/tokio/latest/tokio/time/fn.pause.html.
- .NET's `TimeProvider`:
  https://learn.microsoft.com/en-us/dotnet/api/system.timeprovider.

## Next steps

After local validation in `metacraft-labs/codetracer-nim` (this RFC's
implementation branch — `clock-injection-hook`):

1. File an RFC at `github.com/nim-lang/RFCs/` titled "Hook for clock
   injection in `std/asyncdispatch`", linking the chronos RFC's
   acceptance / merge status as prior art.
2. Discussion on `forum.nim-lang.org` to gauge core-team appetite.
   asyncdispatch is in maintenance mode; some core devs would prefer
   downstream consumers migrate to chronos rather than accept new
   stdlib hooks. This RFC's hypothesis is that the patch is small
   enough (33 LOC, additive, hard-gated) to be uncontroversial even
   in maintenance mode.
3. PR against `nim-lang/Nim` if discussion is positive.
4. Estimated review window: 6-18 months based on stdlib's historical
   review cadence — substantially longer than the chronos RFC's
   estimated 1-3 months. The fallback strategy is to maintain the
   patch in `metacraft-labs/codetracer-nim` and select it via
   `nim --lib:` for downstream consumers; a 50-line `tools/
   rebase-asyncdispatch-patch.sh` automates re-applying the patch
   against new Nim releases.
