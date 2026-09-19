=========================================
    Internals of the Nim Compiler
=========================================


:Author: Andreas Rumpf
:Version: |nimversion|

.. default-role:: code
.. include:: rstcommon.rst
.. contents::

> "Abstraction is layering ignorance on top of reality." -- Richard Gabriel


Directory structure
===================

The Nim project's directory structure is:

============   ===================================================
Path           Purpose
============   ===================================================
`bin`          generated binary files
`build`        generated C code for the installation
`compiler`     the Nim compiler itself; note that this
               code has been translated from a bootstrapping
               version written in Pascal, so the code is **not**
               a poster child of good Nim code
`config`       configuration files for Nim
`dist`         additional packages for the distribution
`doc`          the documentation; it is a bunch of
               reStructuredText files
`lib`          the Nim library
============   ===================================================


Bootstrapping the compiler
==========================

**Note**: Add ``.`` to your PATH so that `koch`:cmd: can be used without the ``./``.

Compiling the compiler is a simple matter of running:

  ```cmd
  nim c koch.nim
  koch boot -d:release
  ```

For a debug version use:

  ```cmd
  nim c koch.nim
  koch boot
  ```


And for a debug version compatible with GDB:

  ```cmd
  nim c koch.nim
  koch boot --debuginfo --linedir:on
  ```

The `koch`:cmd: program is Nim's maintenance script. It is a replacement for
make and shell scripting with the advantage that it is much more portable.
More information about its options can be found in the [koch](koch.html)
documentation.


Reproducible builds
-------------------

Set the compilation timestamp with the `SOURCE_DATE_EPOCH` environment variable.

  ```cmd
  export SOURCE_DATE_EPOCH=$(git log -n 1 --format=%at)
  koch boot # or `./build_all.sh`
  ```


Debugging the compiler
======================


Bisecting for regressions
-------------------------

There are often times when there is a bug that is caused by a regression in the
compiler or stdlib. Bisecting the Nim repo commits is a useful tool to identify
what commit introduced the regression.

Even if it's not known whether a bug is caused by a regression, bisection can reduce
debugging time by ruling it out. If the bug is found to be a regression, then you
focus on the changes introduced by that one specific commit.

`koch temp`:cmd: returns 125 as the exit code in case the compiler
compilation fails. This exit code tells `git bisect`:cmd: to skip the
current commit:

  ```cmd
  git bisect start bad-commit good-commit
  git bisect run ./koch temp -r c test-source.nim
  ```

You can also bisect using custom options to build the compiler, for example if
you don't need a debug version of the compiler (which runs slower), you can replace
`./koch temp`:cmd: by explicit compilation command, see [Bootstrapping the compiler].

See also:

- Crossplatform C/Cpp/Valgrind/JS Bisect in GitHub: https://github.com/juancarlospaco/nimrun-action#examples


Building an instrumented compiler
---------------------------------

Considering that a useful method of debugging the compiler is inserting debug
logging, or changing code and then observing the outcome of a testcase, it is
fastest to build a compiler that is instrumented for debugging from an
existing release build. `koch temp`:cmd: provides a convenient method of doing
just that.

By default, running `koch temp`:cmd: will build a lean version of the compiler
with `-d:debug`:option: enabled. The compiler is written to `bin/nim_temp` by
default. A lean version of the compiler lacks JS and documentation generation.

`bin/nim_temp` can be directly used to run testcases, or used with testament
with `testament --nim:bin/nim_temp r tests/category/tsometest`:cmd:.

`koch temp`:cmd: will build the temporary compiler with the `-d:debug`:option:
enabled. Here are compiler options that are of interest when debugging:

* `-d:debug`:option:\: enables `assert` statements and stacktraces and all
  runtime checks
* `--opt:speed`:option:\: build with optimizations enabled
* `--debugger:native`:option:\: enables `--debuginfo --lineDir:on`:option: for using
  a native debugger like GDB, LLDB or CDB
* `-d:nimDebug`:option: cause calls to `quit` to raise an assertion exception
* `-d:nimDebugUtils`:option:\: enables various debugging utilities;
  see `compiler/debugutils`
* `-d:stacktraceMsgs -d:nimCompilerStacktraceHints`:option:\: adds some additional
  stacktrace hints; see https://github.com/nim-lang/Nim/pull/13351
* `-u:leanCompiler`:option:\: enable JS and doc generation

Another method to build and run the compiler is directly through `koch`:cmd:\:

  ```cmd
  koch temp [options] c test.nim

  # (will build with js support)
  koch temp [options] js test.nim

  # (will build with doc support)
  koch temp [options] doc test.nim
  ```

Debug logging
-------------

"Printf debugging" is still the most appropriate way to debug many problems
arising in compiler development. The typical usage of breakpoints to debug
the code is often less practical, because almost all code paths in the
compiler will be executed hundreds of times before a particular section of the
tested program is reached where the newly developed code must be activated.

To work around this problem, you'll typically introduce an if statement in the
compiler code detecting more precisely the conditions where the tested feature
is being used. One very common way to achieve this is to use the `mdbg` condition,
which will be true only in contexts, processing expressions and statements from
the currently compiled main module:

  ```nim
  # inside some compiler module
  if mdbg:
    debug someAstNode
  ```

Using the `isCompilerDebug`:nim: condition along with inserting some statements
into the testcase provides more granular logging:

  ```nim
  # compilermodule.nim
  if isCompilerDebug():
    debug someAstNode

  # testcase.nim
  proc main =
    {.define(nimCompilerDebug).}
    let a = 2.5 * 3
    {.undef(nimCompilerDebug).}
  ```

Logging can also be scoped to a specific filename as well. This will of course
match against every module with that name.

  ```nim
  if `??`(conf, n.info, "module.nim"):
    debug(n)
  ```

The above examples also makes use of the `debug`:nim: proc, which is able to
print a human-readable form of an arbitrary AST tree. Other common ways to print
information about the internal compiler types include:

  ```nim
  # pretty print PNode

  # pretty prints the Nim ast
  echo renderTree(someNode)

  # pretty prints the Nim ast, but annotates symbol IDs
  echo renderTree(someNode, {renderIds})

  # pretty print ast as JSON
  debug(someNode)

  # print as YAML
  echo treeToYaml(config, someNode)


  # pretty print PType

  # print type name
  echo typeToString(someType)

  # pretty print as JSON
  debug(someType)

  # print as YAML
  echo typeToYaml(config, someType)


  # pretty print PSym

  # print the symbol's name
  echo symbol.name.s

  # pretty print as JSON
  debug(symbol)

  # print as YAML
  echo symToYaml(config, symbol)


  # pretty print TLineInfo
  lineInfoToStr(lineInfo)


  # print the structure of any type
  repr(someVar)
  ```

Here are some other helpful utilities:

  ```nim
  # how did execution reach this location?
  writeStackTrace()
  ```

These procs may not already be imported by the module you're editing.
You can import them directly for debugging:

  ```nim
  from astalgo import debug
  from types import typeToString
  from renderer import renderTree
  from msgs import `??`
  ```

Native debugging
----------------

Stepping through the compiler with a native debugger is a very powerful tool to
both learn and debug it. However, there is still the need to constrain when
breakpoints are triggered. The same methods as in [Debug logging] can be applied
here when combined with calls to the debug helpers `enteringDebugSection()`:nim:
and `exitingDebugSection()`:nim:.

#. Compile the temp compiler with `--debugger:native -d:nimDebugUtils`:option:
#. Set your desired breakpoints or watchpoints.
#. Configure your debugger:
   * GDB: execute `source tools/compiler.gdb` at startup
   * LLDB execute `command source tools/compiler.lldb` at startup
#. Use one of the scoping helpers like so:

  ```nim
  if isCompilerDebug():
    enteringDebugSection()
  else:
    exitingDebugSection()
  ```

A caveat of this method is that all breakpoints and watchpoints are enabled or
disabled. Also, due to a bug, only breakpoints can be constrained for LLDB.

The compiler's architecture
===========================

Nim uses the classic compiler architecture: A lexer/scanner feeds tokens to a
parser. The parser builds a syntax tree that is used by the code generators.
This syntax tree is the interface between the parser and the code generator.
It is essential to understand most of the compiler's code.

Semantic analysis is separated from parsing.

.. include:: filelist.txt


The syntax tree
---------------
The syntax tree consists of nodes which may have an arbitrary number of
children. Types and symbols are represented by other nodes, because they
may contain cycles. The AST changes its shape after semantic checking. This
is needed to make life easier for the code generators. See the "ast" module
for the type definitions. The [macros](macros.html) module contains many
examples how the AST represents each syntactic structure.


Symbol body hashes
------------------

`sighashes.symBodyDigest`:nim: computes a hash that identifies *what a routine
does*, which `macros.symBodyHash`:nim: exposes to macros. Tooling uses it to
decide whether a routine changed between two compilations, so the hash must
depend on the meaning of the code and on nothing else -- in particular not on
where the sources happen to sit on disk.

Three properties of the implementation make that easy to get wrong, and all
three bite silently: the result is still a perfectly good hash, it just answers
a different question than the caller thinks.

### What reaches the hash

`hashBodyTree`:nim: walks the routine's body and hashes literals *verbatim*:
string literals contribute their exact bytes. It also recurses:

* through every routine the body calls, so the callee's body is part of the
  caller's hash;
* through every global it reaches, via `hashVarSymBody`:nim:, which for a
  global spelled as `nkIdentDefs`/`nkConstDef` hashes the **initializer
  expression**.

The second point is the surprising one. Putting a value behind a runtime
indirection does not hide it: reaching it through a proc call, or through a
global, still pulls it into the transitive closure. The value has to be absent
from that closure entirely.

Measured, for a module-level `const theConst`:

| how the routine reaches the value            | in the hash? |
| -------------------------------------------- | ------------ |
| const inlined at the call site                | yes          |
| proc that names the global const              | yes          |
| global `let x = theConst`                     | yes          |
| global `var x = theConst` (initialised)       | yes          |
| global `var x: string`, assigned in module init | no         |
| proc calling a proc that reads that bare var  | no           |

Only the last two are safe, and they are safe for the same reason: an
uninitialised global has no initializer expression for `hashVarSymBody`:nim: to
descend into, and the module-init assignment is not part of any routine the
hashed body reaches.

### Local names, and the hygiene suffix

`hashVarSymBody`:nim: identifies a non-global local by its **name**, which is
right for a local the author wrote: renaming `x` to `y` is a change to the body
and must move the hash.

It is not right for a hygienic template local. `evaltempl`:nim: renames one to
``<base>`gensym<N>``, where `N` comes from `PContext.templInstCounter`:nim: --
a counter created fresh per module and bumped on every template expansion in
it. `N` therefore records how many expansions preceded this one *in the
module*, and nothing about the local. Hashing it verbatim made a body's hash
depend on its neighbours: adding or removing a template expansion anywhere
above it in the file moved it.

That reaches further than it sounds. `unittest.check`:nim:, `require`:nim: and
`expect`:nim: all expand `fail`:nim:, whose `for formatter in formatters`:nim:
is a hygienic local, so every test using an assertion macro was affected by
every test above it.

`hashLocalSymName`:nim: therefore hashes the base name -- the part the author
wrote, in the template -- followed by an ordinal counting distinct hygienic
locals within *this* body, in traversal order, rather than the module counter.
Ordinals are handed out from a table that `symBodyDigest`:nim: creates empty
per body, including for the nested digests it computes for callees, so they
cannot pick up an ordering from the rest of the compilation.

The ordinal, rather than dropping the suffix outright, keeps the scheme no less
discriminating than hashing the full name was: two distinct symbols get
distinct ordinals even when their base names collide, so no pair that used to
hash apart can be brought together.

Only the compiler-generated part of the name is normalised. Symbols from
`macros.genSym`:nim: are untouched: those carry `sfGenSym`:nim: but keep the
name the macro asked for, which is stable and meaningful.

This removes one of **two** ways a body's hash can move without the body
changing; the other is below and is deliberate. Measured, for a `unittest` test
whose text does not change:

| edit above it in the file          | uses `check` | hash moves? |
| ---------------------------------- | ------------ | ----------- |
| adds a template expansion, same line count | yes  | no (was yes) |
| shifts it down a line              | yes          | yes         |
| shifts it down a line              | no           | no          |

Line numbering still reaches the hash, because `check` plants its own line and
column into the body as a string literal -- see below. A hash consumer should
expect an edit that shifts lines to invalidate everything under it, and should
read this change as removing a dependency on a compiler-internal counter rather
than as making bodies insertion-proof.

### Paths written into the tree

A macro or template that plants a location into the code it expands -- as
`unittest.check`:nim: and `assertions.assert`:nim: do, so a failure message can
name its source -- writes a string literal into the caller's body, and that
literal is hashed verbatim. If it holds an absolute path, the body hash of
every routine containing such an expansion tracks the checkout directory, and
the same source hashes differently in two working copies, or after the
toolchain is reinstalled elsewhere.

Rendering the location is therefore a deliberate choice, spelled with
`system.InstantiationPath`:nim: -- `instantiationInfo(-1, ipCanonical)`:nim: and
`macros.lineInfo(n, ipCanonical)`:nim:. Two constraints apply at once and only
the canonical rendering satisfies both:

* **reproducible**: the same source must hash identically wherever it is
  checked out and whatever prefix the standard library is installed under.
  `ipAbsolute` fails this.
* **resolvable**: two same-named files in different directories must stay
  distinguishable, so the message can be traced back to a file. `ipBasename`
  fails this, and so does any rendering anchored on `conf.projectPath`, because
  `projectPath` is the directory of the *main module*: a test file compiled as
  its own main module renders as a bare basename again. That is the ambiguity
  that removed project-relative paths from `macros.lineInfoObj`:nim: in
  nim-lang/Nim#7429.

Note that `{.line.}`:nim: has the same hazard in its argument form. Bare
`{.line.}`:nim: takes the instantiation site from the compiler's context and
writes nothing into the tree; `{.line: (file, line, col).}`:nim: plants the
filename as an ordinary literal. Prefer the bare form in macros whose output
lands in hashed bodies.

### Anchoring

`ipCanonical` resolves through `options.canonicalImportAux`:nim:, which looks
for a root in this order: the standard library directories, then the search
paths, then the nearest enclosing `.nimble` file; failing all of those it falls
back to `conf.projectPath`. Measured, compiling `tests/a/t.nim` and
`tests/b/t.nim` as their own main modules:

| marker at the package root | `ipCanonical` renders | distinguishes `a` from `b`? |
| -------------------------- | --------------------- | --------------------------- |
| `pkg.nimble`               | `tests/a/t.nim`       | yes                         |
| `--path:<root>`            | `tests/a/t.nim`       | yes                         |
| `config.nims`              | `t.nim`               | no                          |
| `nim.cfg`                  | `t.nim`               | no                          |
| none                       | `t.nim`               | no                          |

`.nimble` and `--path:<root>` are interchangeable and produce identical hashes.
A bare `config.nims` or `nim.cfg` anchors nothing on its own -- only a
directive that actually adds a search path does. **A consumer that relies on
reproducible, resolvable body hashes must provide one of the two anchors**;
without one the rendering silently degrades to a basename, which is still
reproducible and so still passes any stability-only check, while losing the
directory that made the hash identify a file.

Standard library modules render without the `.nim` extension (`std/tables`),
package files render with it (`tests/a/t.nim`). That asymmetry comes from
`canonicalImportAux`:nim: and is shared with `--filenames:canonical`.

### What "stable" means, and where each half is pinned

"Stable" is not one property. It is four things a body hash must ignore and
three it must not, and the two halves constrain each other: every "must ignore"
is trivially satisfiable by a hash that has stopped looking, so each is only
worth anything next to the "must not" that rules that out. The tests are
written in those pairs.

| a body hash must **ignore**                       | pinned by |
| ------------------------------------------------- | --------- |
| where the package is checked out                   | `tunittest_body_hash_paths`, `tbody_hash_instantiation_path` |
| where the standard library is installed            | `tunittest_body_hash_identity` |
| how many template expansions precede it in its module | `tunittest_body_hash_position` |
| the test's own name, and its suite's name          | `tunittest_body_hash_identity` |

| a body hash must **not ignore**                    | pinned by |
| ------------------------------------------------- | --------- |
| the body at all                                     | `tunittest_body_hash_identity`, `tunittest_body_hash_position` |
| the bodies of the routines it calls, transitively    | `tunittest_protocol_body_hash` |
| the names of the author's own locals                | `tunittest_body_hash_position` |
| which directory a file is in, when two share a basename | `tunittest_body_hash_paths`, `tbody_hash_instantiation_path` |

The last pair is the one that is easy to lose: a rendering that drops the
directory satisfies every "must ignore" row above and is therefore accepted by
any stability-only test, while making two same-named test files
indistinguishable. `tbody_hash_instantiation_path` runs all three
`InstantiationPath`:nim: modes against the same fixture for that reason, so the
file states what each mode costs rather than only asserting the one in use.

**Line numbers are deliberately not in the "must ignore" list.** A body
containing a planted location rehashes when the location moves, because the
location is a literal in the body; see the table above. A consumer diffing
catalogs should expect an insertion to invalidate everything below it in the
same file.


What `unittest`'s runner protocol changed for an existing suite
---------------------------------------------------------------

`lib/pure/unittest.nim` here carries a runner protocol upstream's does not:
four command line flags (`--list`, `--list-json`, `--run`, `--catalog`), five
per-test metadata options, and a `test`:nim: that is a `macro`:nim: rather than
a `{.dirty.}`:nim: template. Everything else is meant to behave exactly as
upstream does, so that a suite written against upstream keeps compiling and
keeps printing the same bytes.

That is a claim about behaviour, no test in this repository enforces it, and it
is not true in full: two of the differences below have been in the module since
the protocol first landed and were not noticed at the time. So the claim has to
be measured, and re-measured after anything that edits the module. This section
records the method, so it can be repeated, and the result, so the next edit
knows what is supposed to stay fixed and what has already moved.

### Method

The measurement is a differential, and the only thing that may differ between
the two arms is the file under test. Concretely: one compiler binary built from
this branch, one `lib` tree copied twice, and `lib/pure/unittest.nim` replaced
in the second copy by the version at 62751cacf -- which is byte-identical to
upstream's at cc4c7377b, the last upstream commit to touch the module. Each
fixture is then compiled twice with `--lib:` pointing at one copy and then the
other, run with identical arguments, and standard output, standard error and
the exit status are compared byte for byte.

Building two whole compilers instead, or diffing against a checkout of the base
commit, would let the compiler changes on this branch leak into the comparison
and answer a different question. `--skipUserCfg --skipParentCfg` and a fixture
directory outside any package keep a stray configuration file out of it.

Coverage, at e06a98881: ten fixtures over four rows -- C with `--mm:refc`,
C with `--mm:orc`, JavaScript, and JavaScript with `-d:nodejs` -- and, on each
row, twelve argument vectors covering the filter shapes the module documents
(bare name, `suite::`, `suite::test`, `::test`, `*`, `*::*`, globs on either
side, several filters at once, one that matches nothing, the empty string) plus
a run under `disableParamFiltering`. 88 runs; 76 byte-identical; the 12 that
differ are three causes, each reproducing on all four rows.

Four further properties do not reduce to a single run of that A/B -- three of
them because the thing to compare against is not upstream -- and are checked
separately:

* A trailing block still binds for every call shape that worked before:
  `test "n": body`, `test("n"): body`, `test expr & expr: body`,
  `test identifier: body`, `test("n", body)`, multi-statement bodies, and
  bodies containing nested control flow. All seven compile and run. `skip`:nim:
  written without parentheses still compiles too, despite gaining a defaulted
  parameter.
* The five options do not change the meaning of a call that omits them. A
  fixture and its copy annotated with all five produce byte-identical console
  output, and the un-annotated copy is byte-identical to the upstream arm.
* `instantiationInfo(-1, true)`:nim: inside the expansion still names the
  user's call site. Against the immediately preceding template implementation
  of `test`:nim: (4e93a8a42), the `file`, `line` and `column` of all fifteen
  test call sites in the fixtures are unchanged. `getAst`:nim: on a template
  preserves the instantiation stack, so routing through a macro costs nothing
  here -- but that is the property, not an argument for skipping the check.
* The `bodyHash` a test reports is NOT stable across that change: every test's
  hash moved when `test`:nim: became a macro, because the expansion it produces
  is not the tree the template produced. `file`, `line` and `column` did not
  move. A consumer caching hashes across a toolchain upgrade re-runs
  everything, once.

### The intended difference: the reported location

`check`:nim:, `require`:nim: and `expect`:nim: render the location in their
failure message canonically rather than absolutely, for the reason the previous
section gives: the literal is planted in the caller's body and would otherwise
put the checkout directory into every containing routine's body hash. In a
package with a `.nimble` file at its root:

    - /home/u/pkg/tests/t.nim(7, 12): Check failed: x == y
    + tests/t.nim(7, 12): Check failed: x == y

Line and column are unchanged, and so is every other byte of the output. This
is the whole of the difference in the default console output of a failing
suite. Without one of the two anchors, the rendering degrades to the bare
basename, as "Anchoring" above describes.

### Reserved argument spellings

`--list`, `--list-json`, `--run`, `--run=`, `--catalog` and `--catalog=` are
now read as flags. Upstream added every argument to the filter set, so a suite
that was passed one of these six got a filter that matched nothing; it now
selects a mode. This is what the protocol is for, but it is a change in the
meaning of an argument vector, and a test whose name is literally one of those
six can no longer be selected by name.

The flags need an argument vector, so on the JavaScript backend they do nothing
-- as does filtering itself, in both arms, exactly as upstream. The JavaScript
rows of the matrix therefore prove the output formatting and not the filtering.

### Not intended: `result` cannot be assigned from a test body

A test body is compiled into a nested `testBodyIMPL`:nim: procedure so that
`macros.symBodyHash`:nim: has a routine to hash. Upstream's template left the
body inline in the enclosing scope, so a `test`:nim: inside a procedure with a
return type could assign to that procedure's `result`:nim:. It now cannot:

    proc f(): int =
      test "assigns to result":
        result = 7        # Error: 'result' is of type <int> which cannot be
                          # captured as it would violate memory safety

This is a compile-time break of a shape that compiled before. It is not caused
by the macro conversion: it dates from 3bf7c586f, the commit that first
introduced `testBodyIMPL`:nim:, and it is present in every revision since --
re-checked at 0322915eb by the A/B above, where the same fixture prints
`[OK] ...` and `f() = 7` against the upstream arm and fails to compile against
this one. Anyone relying on the shape has to lift the assignment out of the
test body.

The mechanism is `illegalCapture`:nim: in `compiler/lambdalifting.nim`, which
is `classifyViewType(s.typ) != noView or s.kind == skResult`. `result`:nim: is
an `skResult`:nim: symbol and may never be captured by a nested routine, for
the usual reason: depending on the return type and on NRVO it is either a local
slot or a hidden pointer into the caller's storage, and a closure holding it
can outlive the call. Any construction that puts the body inside a routine of
its own runs into that rule, and the body has to be inside a routine of its own
because `macros.symBodyHash`:nim: takes a symbol -- passing a `template`:nim:
where a routine symbol is expected expands it instead, so hashing a template
holding the body and leaving the body inline is not available:

    Error: symBodyHash() requires a symbol. 'discard helper() + 1' is of kind
    'nkDiscardStmt'

#### Why it stays recorded rather than fixed

There is exactly one mechanism that makes the shape compile without moving the
body out of a routine: take the address of the enclosing `result`:nim: in the
scope that encloses `testBodyIMPL`:nim: and alias the name over it, three lines
in `testImpl`:nim: guarded by `when declared(result)`:nim:. It was written and
measured, and it does restore the behaviour -- the fixture above and nineteen
more, covering module scope, `proc`:nim: without a return type, generic
procedures, iterators, converters, closures, tests reached through a
`template`:nim:, nested tests, a body that declares its own `result`:nim:,
`setup`/`teardown`, and `seq`, object, tuple and `var`:nim: results, all
produce output byte-identical to the upstream arm on C with `--mm:refc`, C with
`--mm:orc` and JavaScript, with identical compiler diagnostics on nineteen of
the twenty.

It is still the wrong change, because it does not satisfy the rule above, it
routes around it. `result`:nim: inside a test body stops being an
`skResult`:nim: symbol and becomes a dereference of an unchecked `ptr`:nim:,
and the compiler can no longer see the capture it is supposed to reject. This
program is refused by upstream and by this fork, with the error quoted above,
and is accepted by the aliased build, where it writes `12345` into the result
slot of a call that has already returned:

    var escaped: proc()
    proc leaks(): int =
      test "closure captures result":
        escaped = proc() =
          result = 12345
    discard leaks()
    escaped()

Restricting the alias to bodies that contain no nested routine does not close
this: the `test`:nim: macro sees the body untyped, so a nested routine arriving
from a `template`:nim: expanded inside the body is not visible to any check it
could run. The twentieth fixture is the second cost: taking the address defeats
the initialisation analysis, so a `proc (): var int`:nim: containing a test
gains a `ProveInit`:nim: warning that neither arm emits today, on all three
rows.

So the two candidates are: a library change that trades a compile-time error
for a silent memory-safety hole in a standard library module, or a compiler
change that teaches `lambdalifting` an escape analysis strong enough to admit a
nested routine that provably does not outlive its enclosing call -- a new
analysis in the compiler, not a scoping decision in `unittest`. Neither is
proportionate to the shape, which is rare and has a one-line workaround, so the
difference stays recorded. Should the compiler ever grow that analysis for its
own reasons, this becomes a two-line follow-up.

### Not intended: an extra stack frame

For the same reason, the traceback of an exception escaping a test body carries
one frame more than upstream's:

    - t.nim(5) t
    + t.nim(4) t
    + t.nim(5) testBodyIMPL

Also from 3bf7c586f. The macro conversion improved the outer frame -- it named
a line inside `unittest.nim` before, and names the user's `test`:nim: call now
-- without removing the frame. The message and the `[FAILED]` line are
unchanged; only the traceback grows.

### Repeating the measurement

Copy `lib` twice, replace `lib/pure/unittest.nim` in one copy with
`git show 62751cacf:lib/pure/unittest.nim`, and compile each fixture against
both with the same `bin/nim`, comparing all three of stdout, stderr and exit
status. Verify first that the replaced file still matches the upstream commit
it is supposed to be, since a later merge from upstream will move that baseline:

    git show cc4c7377b:lib/pure/unittest.nim | cmp - <copy>/pure/unittest.nim

### How the divergence splits

Everything the two sections above describe arrived together, but it does not
have to travel together, and a change that treats it as one lump is harder to
review than it needs to be. Measured at e06a98881 against 62751cacf, the whole
divergence is 23 files, +2748/-204, and it separates into four parts that share
no code:

| part | size | touches |
| ---- | ---- | ------- |
| `InstantiationPath` and its two consumers | 10 files, +505/-21 | `system`, `macros`, `assertions`, `unittest`, 3 compiler files |
| the `symBodyDigest` hygiene-counter fix | 3 files, +420/-13 | `sighashes` only |
| the `unittest` runner protocol | 8 files, +1660/-63 | `unittest` only |
| this fork's CI wiring | 4 files, +188/-132 | `.github` only |

The first two stand alone. `InstantiationPath` is a language feature -- a call
site asking for what `--filenames:canonical` produces -- and the compiler side
of it is 29 added lines across `semmagic`, `vm` and `vmgen`, reusing the
existing `foCanonical` rendering rather than adding one. It carries a visible
behaviour change with it, since `assert`'s message under
`--excessiveStackTrace`:option: and `check`'s message move from an absolute
path to a canonical one; that is the part that needs agreement, not the
mechanism. The hygiene-counter fix touches one compiler file and changes no
interface at all, but it does change the value of `macros.symBodyHash`:nim: for
any body containing a hygienic template local, which is the kind of change that
has to be announced rather than slipped in.

The protocol is the part that is genuinely a proposal rather than a fix: it
adds a command line surface and a JSON schema to a standard library module, and
it carries the two unintended differences recorded above. The CI wiring is
fork-only by construction.

The parts are also unevenly documented. `changelog.md` describes
`InstantiationPath` and the canonical rendering and nothing else -- not the
protocol, not the `test`:nim: macro and its five options, not the
`skip(reason)`:nim: signature change, not the `symBodyHash`:nim: values moving.
All four are user-visible.


Runtimes
========

Nim has two different runtimes, the "old runtime" and the "new runtime". The old
runtime supports the old GCs (markAndSweep, refc, Boehm), the new runtime supports
ARC/ORC. The new runtime is active `when defined(nimV2)`.


Coding Guidelines
=================

* We follow Nim's official style guide, see [NEP1](nep1.html).
* Max line length is 100 characters.
* Provide spaces around binary operators if that enhances readability.
* Use a space after a colon, but not before it.
* (deprecated) Start types with a capital `T`, unless they are
  pointers/references which start with `P`.
* Prefer `import package`:nim: over `from package import symbol`:nim:.

See also the [API naming design](apis.html) document.


Porting to new platforms
========================

Porting Nim to a new architecture is pretty easy, since C is the most
portable programming language (within certain limits) and Nim generates
C code, porting the code generator is not necessary.

POSIX-compliant systems on conventional hardware are usually pretty easy to
port: Add the platform to `platform` (if it is not already listed there),
check that the OS, System modules work and recompile Nim.

The only case where things aren't as easy is when old runtime's garbage
collectors need some assembler tweaking to work. The default
implementation uses C's `setjmp`:c: function to store all registers
on the hardware stack. It may be necessary that the new platform needs to
replace this generic code by some assembler code.

Files that may need changed for your platform include:

* `compiler/platform.nim`
  Add os/cpu properties.
* `lib/system.nim`
  Add os/cpu to the documentation for `system.hostOS` and `system.hostCPU`.
* `compiler/options.nim`
  Add special os/cpu property checks in `isDefined`.
* `compiler/installer.ini`
  Add os/cpu to `Project.Platforms` field.
* `lib/system/platforms.nim`
  Add os/cpu.
* `std/private/osseps.nim`
  Add os specializations.
* `lib/pure/distros.nim`
  Add os, package handler.
* `tools/niminst/makefile.nimf`
  Add os/cpu compiler/linker flags.
* `tools/niminst/buildsh.nimf`
  Add os/cpu compiler/linker flags.

If the `--os` or `--cpu` options aren't passed to the compiler, then Nim will
determine the current host os, cpu and endianness from `system.cpuEndian`,
`system.hostOS` and `system.hostCPU`. Those values are derived from
`compiler/platform.nim`.

In order for the new platform to be bootstrapped from the `csources`, it must:

* have `compiler/platform.nim` updated
* have `compiler/installer.ini` updated
* have `tools/niminst/buildsh.nimf` updated
* have `tools/niminst/makefile.nimf` updated
* be backported to the Nim version used by the `csources`
* the new `csources` must be pushed
* the new `csources` revision must be updated in `config/build_config.txt`


Runtime type information
========================

**Note**: This section describes the "old runtime".

*Runtime type information* (RTTI) is needed for several aspects of the Nim
programming language:

Garbage collection
: The old GCs use the RTTI for traversing arbitrary Nim types, but usually
  only the `marker` field which contains a proc that does the traversal.

Complex assignments
: Sequences and strings are implemented as
  pointers to resizable buffers, but Nim requires copying for
  assignments. Apart from RTTI the compiler also generates copy procedures
  as a specialization.

We already know the type information as a graph in the compiler.
Thus, we need to serialize this graph as RTTI for C code generation.
Look at the file ``lib/system/hti.nim`` for more information.


Magics and compilerProcs
========================

The `system` module contains the part of the RTL which needs support by
compiler magic. The C code generator generates the C code for it, just like any other
module. However, calls to some procedures like `addInt` are inserted by
the generator. Therefore, there is a table (`compilerprocs`)
with all symbols that are marked as `compilerproc`. `compilerprocs` are
needed by the code generator. A `magic` proc is not the same as a
`compilerproc`: A `magic` is a proc that needs compiler magic for its
semantic checking, a `compilerproc` is a proc that is used by the code
generator.


Code generation for closures
============================

Code generation for closures is implemented by `lambda lifting`:idx:.


Design
------

A `closure` proc var can call ordinary procs of the default Nim calling
convention. But not the other way round! A closure is implemented as a
`tuple[prc, env]`. `env` can be nil implying a call without a closure.
This means that a call through a closure generates an `if` but the
interoperability is worth the cost of the `if`. Thunk generation would be
possible too, but it's slightly more effort to implement.

Tests with GCC on Amd64 showed that it's really beneficial if the
'environment' pointer is passed as the last argument, not as the first argument.

Proper thunk generation is harder because the proc that is to wrap
could stem from a complex expression:

  ```nim
  receivesClosure(returnsDefaultCC[i])
  ```

A thunk would need to call `returnsDefaultCC[i]` somehow and that would require
an *additional* closure generation... Ok, not really, but it requires to pass
the function to call. So we'd end up with 2 indirect calls instead of one.
Another much more severe problem with this solution is that it's not GC-safe
to pass a proc pointer around via a generic `ref` type.


Example code:

  ```nim
  proc add(x: int): proc (y: int): int {.closure.} =
    return proc (y: int): int =
      return x + y

  var add2 = add(2)
  echo add2(5) #OUT 7
  ```

This should produce roughly this code:

  ```nim
  type
    Env = ref object
      x: int # data

  proc anon(y: int, c: Env): int =
    return y + c.x

  proc add(x: int): tuple[prc, data] =
    var env: Env
    new env
    env.x = x
    result = (anon, env)

  var add2 = add(2)
  let tmp = if add2.data == nil: add2.prc(5) else: add2.prc(5, add2.data)
  echo tmp
  ```


Beware of nesting:

  ```nim
  proc add(x: int): proc (y: int): proc (z: int): int {.closure.} {.closure.} =
    return lambda (y: int): proc (z: int): int {.closure.} =
      return lambda (z: int): int =
        return x + y + z

  var add24 = add(2)(4)
  echo add24(5) #OUT 11
  ```

This should produce roughly this code:

  ```nim
  type
    EnvX = ref object
      x: int # data

    EnvY = ref object
      y: int
      ex: EnvX

  proc lambdaZ(z: int, ey: EnvY): int =
    return ey.ex.x + ey.y + z

  proc lambdaY(y: int, ex: EnvX): tuple[prc, data: EnvY] =
    var ey: EnvY
    new ey
    ey.y = y
    ey.ex = ex
    result = (lambdaZ, ey)

  proc add(x: int): tuple[prc, data: EnvX] =
    var ex: EnvX
    ex.x = x
    result = (lambdaY, ex)

  var tmp = add(2)
  var tmp2 = tmp.fn(4, tmp.data)
  var add24 = tmp2.fn(4, tmp2.data)
  echo add24(5)
  ```


We could get rid of nesting environments by always inlining inner anon procs.
More useful is escape analysis and stack allocation of the environment,
however.


Accumulator
-----------

  ```nim
  proc getAccumulator(start: int): proc (): int {.closure} =
    var i = start
    return lambda: int =
      inc i
      return i

  proc p =
    var delta = 7
    proc accumulator(start: int): proc(): int =
      var x = start-1
      result = proc (): int =
        x = x + delta
        inc delta
        return x

    var a = accumulator(3)
    var b = accumulator(4)
    echo a() + b()
  ```


Internals
---------

Lambda lifting is implemented as part of the `transf` pass. The `transf`
pass generates code to set up the environment and to pass it around. However,
this pass does not change the types! So we have some kind of mismatch here; on
the one hand the proc expression becomes an explicit tuple, on the other hand
the tyProc(ccClosure) type is not changed. For C code generation it's also
important the hidden formal param is `void*`:c: and not something more
specialized. However, the more specialized env type needs to passed to the
backend somehow. We deal with this by modifying `s.ast[paramPos]` to contain
the formal hidden parameter, but not `s.typ`!


Notes on type and AST representation
====================================

To be expanded.


Integer literals
----------------

In Nim, there is a redundant way to specify the type of an
integer literal. First, it should be unsurprising that every
node has a node kind. The node of an integer literal can be any of the
following values:

    nkIntLit, nkInt8Lit, nkInt16Lit, nkInt32Lit, nkInt64Lit,
    nkUIntLit, nkUInt8Lit, nkUInt16Lit, nkUInt32Lit, nkUInt64Lit

On top of that, there is also the `typ` field for the type. The
kind of the `typ` field can be one of the following ones, and it
should be matching the literal kind:

    tyInt, tyInt8, tyInt16, tyInt32, tyInt64, tyUInt, tyUInt8,
    tyUInt16, tyUInt32, tyUInt64

Then there is also the integer literal type. This is a specific type
that is implicitly convertible into the requested type if the
requested type can hold the value. For this to work, the type needs to
know the concrete value of the literal. For example an expression
`321` will be of type `int literal(321)`. This type is implicitly
convertible to all integer types and ranges that contain the value
`321`. That would be all builtin integer types except `uint8` and
`int8` where `321` would be out of range. When this literal type is
assigned to a new `var` or `let` variable, it's type will be resolved
to just `int`, not `int literal(321)` unlike constants. A constant
keeps the full `int literal(321)` type. Here is an example where that
difference matters.


  ```nim
  proc foo(arg: int8) =
    echo "def"

  const tmp1 = 123
  foo(tmp1)  # OK

  let tmp2 = 123
  foo(tmp2) # Error
  ```

In a context with multiple overloads, the integer literal kind will
always prefer the `int` type over all other types. If none of the
overloads is of type `int`, then there will be an error because of
ambiguity.

  ```nim
  proc foo(arg: int) =
    echo "abc"
  proc foo(arg: int8) =
    echo "def"
  foo(123) # output: abc

  proc bar(arg: int16) =
    echo "abc"
  proc bar(arg: int8) =
    echo "def"

  bar(123) # Error ambiguous call
  ```

In the compiler these integer literal types are represented with the
node kind `nkIntLit`, type kind `tyInt` and the member `n` of the type
pointing back to the integer literal node in the ast containing the
integer value. These are the properties that hold true for integer
literal types.

    n.kind == nkIntLit
    n.typ.kind == tyInt
    n.typ.n == n

Other literal types, such as `uint literal(123)` that would
automatically convert to other integer types, but prefers to
become a `uint` are not part of the Nim language.

In an unchecked AST, the `typ` field is nil. The type checker will set
the `typ` field accordingly to the node kind. Nodes of kind `nkIntLit`
will get the integer literal type (e.g. `int literal(123)`). Nodes of
kind `nkUIntLit` will get type `uint` (kind `tyUint`), etc.

This also means that it is not possible to write a literal in an
unchecked AST that will after sem checking just be of type `int` and
not implicitly convertible to other integer types. This only works for
all integer types that are not `int`.
