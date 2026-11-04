# Windows maintenance-prefix qualification

This branch starts at upstream Nim v2.2.10 (`bfeb3146`) and backports the
`vccexe` argument/response-file repair from `92455417` and the native-qualified
Unicode environment capture correction from `c994ccb1`. It is a modified
2.2.10 maintenance build, not an unmodified official archive or a 2.3.1 build.

On top of the accepted prefix source `9bd1e7af` it adds the compiler argument
file transport, `nim --compilerArgsFile:<path>` (`compiler/argsfile.nim`): when
it is the only physical argument, the compiler reads a version-1 JSON file
(`{"version":1,"argv":[...]}`) once, before the first command-line pass, and
uses that logical vector for both passes and for NimScript `paramCount` /
`paramStr`. It lets a build tool pass argument vectors longer than Windows'
32,767-unit `CreateProcessW` limit without changing their meaning.
`tests/misc/tcompilerargsfile.nim` holds its real-compiler controls; the
qualification runs them with the packaged compiler, checks that the official
bootstrap compiler refuses the option, and allows only the enumerated new
prefix members over the accepted 4,820.

From its declared Windows development environment, run one command:

```powershell
pwsh -NoProfile -File ./scripts/qualify-windows-prefix.ps1
```

The existing Packages CI workflow exposes the same operation by manual dispatch
on this branch. Its prior PR/push test matrix and operations are unchanged; they
remain on those events. The added manual event runs the Windows x64 factory job.

The driver uses the repository's normal stable `koch boot` and `koch zip`
commands. It does not run `--latest`, an installer, or `finish.exe`, and does not
replace an installed compiler or helper. Factory dependencies remain pinned by
`koch.nim`. Nim, GCC, Git and 7-Zip come from the declared store tool profiles;
7-Zip uses its normal explicit canonical stdlib package import (it is outside
the curated automatic-import list). The MSVC controls locate an existing
supported platform facility. Actual invoked
image hashes must match the existing standard activation inspection before boot;
a same-version ambient compiler does not satisfy this qualification.

Qualification requires the original bootstrap wrapper's real failing absolute
path case, independent failing Unicode environment control, and passing same-CL
control. It then checks the complete extracted prefix, packaged source hashes, x64 executable headers, compiler version and
compiled Git hash. Both GCC and MSVC must compile and run a standard-library
smoke program from an isolated scratch directory. The packaged wrapper must
pass the existing Unicode, quoted-argument, deep-path, missing-input, long-link
and cleanup controls unchanged, plus the independent Unicode environment control.

`build/windows-prefix-qualification` retains full stage stdout/stderr, the
prefix file manifest, source/tool identities, timings and the original factory
ZIP's SHA-256. Standard ZIP APIs preserve legacy CP437 and flagged UTF-8 names;
qualification requires exact member-name and content equality after extraction.
CI keeps a one-day convenience artifact and attempts the existing
non-blocking durable-store mirror. A skipped or failed mirror is recorded as
such; it is not durable publication.

A successful run qualifies these exact bytes only. It does not publish a
release, select a catalog contributor, or move a global SDK/compiler pin.
