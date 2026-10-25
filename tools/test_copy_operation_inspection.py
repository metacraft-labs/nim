#!/usr/bin/env python3
"""Executing sensitivity controls for the attached Copy inspection tests.

Run inside the compiler development shell, with Python 3 available, after
building the actual engine. No mocks: mutations compile isolated owner sources
and execute unchanged assertions. State injection is confined to the explicitly
documented compiler metadata unit test; public API controls use the real VM.
Example: python3 tools/test_copy_operation_inspection.py --nim bin/nim_copy_inspection
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--nim", type=Path, required=True)
parser.add_argument("--bootstrap", type=Path, default=Path("bin/nim_constructor"))
parser.add_argument("--artifacts", type=Path)
args = parser.parse_args()
nim = args.nim.resolve()
bootstrap = args.bootstrap.resolve()
artifacts = args.artifacts or Path(tempfile.mkdtemp(prefix="copy-inspection-controls-"))
artifacts.mkdir(parents=True, exist_ok=True)
receipts = []
source_files = subprocess.check_output(
    ["git", "ls-files", "-m", "-o", "--exclude-standard"], cwd=ROOT, text=True).splitlines()
source_hashes = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                 for name in source_files if (ROOT / name).is_file()}
mutant_engines = {}


def invoke(name, command, *, succeeds=True, contains=None):
    run = subprocess.run([str(x) for x in command], cwd=ROOT,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log = artifacts / f"{name}.log"
    log.write_text(run.stdout)
    assert (run.returncode == 0) == succeeds, (name, run.returncode, log)
    if contains is not None:
        assert contains in run.stdout, (name, contains, log)
    receipts.append({"name": name, "command": [str(x) for x in command],
                     "exit": run.returncode, "log_sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
    print(f"{name} PASS", flush=True)
    return run.stdout


def compile_run(name, fixture, *, engine=nim, flags=(), backend="c", succeeds=True,
                contains=None):
    return invoke(name, [engine, backend, f"--lib:{ROOT / 'lib'}", "--hints:off",
                        *flags, f"--nimcache:{artifacts / (name + '-cache')}",
                        f"--out:{artifacts / (name + '.out')}", "-r", fixture],
                  succeeds=succeeds, contains=contains)


# Real executions pair query-enabled and baseline code under each target/manager.
for fixture, output in [("tgetcopyoperation", "CDD"),
                        ("tgetcopyoperationidentity", "C"),
                        ("tgetcopyoperationearly", "1"),
                        ("tgetcopyoperationlifetimes", "CCDDDEFD")]:
    for backend in ("c", "js"):
        for manager in ("arc", "orc"):
            for arm in ("baseline", "query"):
                name = f"{fixture}-{backend}-{manager}-{arm}"
                flags = [f"--mm:{manager}"]
                if arm == "baseline": flags.append("-d:copyInspectionBaseline")
                actual = compile_run(name, ROOT / "tests/macros" / f"{fixture}.nim",
                                     flags=flags, backend=backend)
                assert actual.strip() == output, (name, repr(actual))

# The old engine with the NEW library must leave the API undeclared, not parse
# an unknown magic. This also verifies that bootstrap compilation needs no
# suppression of unsupported-magic warnings.
for backend in ("c", "js"):
    output = compile_run(f"old-capability-{backend}", ROOT / "tests/macros/tgetcopyoperation.nim",
                         engine=bootstrap, backend=backend, succeeds=False,
                         contains="copy inspection capability is unavailable")
    assert "unknown magic" not in output.lower()

# Negative API inputs have ordinary typed-macro twins. Refusal is not credited
# to an invalid Nim program (for example, an uninferable standalone empty array).
for fixture in ("invalid", "unresolved", "disabled", "untyped", "generic", "missing", "inprogress"):
    source = (ROOT / f"tests/macros/tgetcopyoperation{fixture}.nim").read_text()
    source = source.replace("discard x.getCopyOperation", "discard x.kind")
    source = source.replace('discard newIdentNode("untypedInput").getCopyOperation',
                            'discard newIdentNode("untypedInput").kind')
    twin = artifacts / f"ordinary_{fixture}.nim"
    twin.write_text(source)
    for backend in ("c", "js"):
        compile_run(f"ordinary-{fixture}-{backend}", twin, backend=backend)


def isolated_owner(name, path, old, new):
    directory = artifacts / name
    shutil.copytree(ROOT / "compiler", directory / "compiler")
    (directory / "dist").symlink_to(ROOT / "dist", target_is_directory=True)
    source = directory / path
    original = source.read_text()
    assert original.count(old) == 1, (name, original.count(old))
    source.write_text(original.replace(old, new))
    return directory


# Compile the actual owner graph code as a library into the unchanged state
# test. These mutations must reach runtime assertions, not fail to compile.
graph_mutations = {
    "removed-completion": ("g.copyBindings.getOrDefault(t.itemId) != op or", "false or"),
    "provisional-dependency": ("not g.operationDependenciesComplete(op):", "false:"),
    "unverified-cache": ("g.config.symbolFiles != disabledSf or g.config.cmd in {cmdNifC, cmdM} or",
                         "false or"),
    "stale-replacement": ("g.operationBodies.del(previous.itemId)", "discard"),
    "false-absence": ("result = op\n", 'failure = "copy operation is not resolved"\n'),
}
for name, (old, new) in graph_mutations.items():
    directory = isolated_owner(name, "compiler/modulegraphs.nim", old, new)
    fixture = directory / "state.nim"
    fixture.write_bytes((ROOT / "tests/compiler/tcopyinspectionstate.nim").read_bytes())
    output = compile_run(name, fixture,
                         flags=("-d:nimKochBootstrap", f"--path:{directory}"),
                         succeeds=False, contains="AssertionDefect")
    expected = ("g.inspectCopyBinding(typ, failure) == selected" if name == "false-absence"
                else "g.inspectCopyBinding(typ, failure) == nil")
    assert expected in output and "execution of an external program failed" in output, \
        (name, "mutation must reach its actual runtime binding assertion")

# Rebuild actual engines for public-VM symbol and default-body mutations. Each
# build uses the new engine/library contract and the same genuine bootstrap.
vm_mutations = {
    "wrong-dup": 'regs[ra].node = newSymNode(getAttachedOp(c.graph, t, attachedDup), a.info)',
    "wrong-overload": '''var inspected = op
      for _, candidate in c.graph.attachedOps[attachedAsgn]:
        if candidate != nil and candidate != op and sfOverridden in candidate.flags and
            candidate.ast != nil and candidate.ast[genericParamsPos].kind == nkEmpty:
          inspected = candidate
          break
      regs[ra].node = newSymNode(inspected, a.info)''',
    "default-body": '''op.ast[bodyPos] = newNode(nkStmtList)
      regs[ra].node = newSymNode(op, a.info)''',
}
for name, replacement in vm_mutations.items():
    directory = isolated_owner(name, "compiler/vm.nim",
                               "regs[ra].node = newSymNode(op, a.info)", replacement)
    engine = directory / "nim-mutant"
    invoke(f"build-{name}", [bootstrap, "c", f"--lib:{ROOT / 'lib'}", "--hints:off",
                             "-d:release", "-d:nimKochBootstrap", f"--out:{engine}",
                             f"--nimcache:{directory / 'build-cache'}", directory / "compiler/nim.nim"])
    mutant_engines[name] = hashlib.sha256(engine.read_bytes()).hexdigest()
    fixture = "tgetcopyoperationlifetimes" if name == "default-body" else "tgetcopyoperationidentity"
    for backend in ("c", "js"):
        if name == "default-body":
            output = compile_run(f"{name}-{backend}", ROOT / f"tests/macros/{fixture}.nim",
                                 engine=engine, backend=backend, succeeds=False,
                                 contains="AssertionDefect")
            assert "scenario" in output and "value.read == source.read" in output, \
                "default body mutation must reach the real runtime value assertion"
        else:
            output = compile_run(f"{name}-{backend}", ROOT / f"tests/macros/{fixture}.nim",
                                 engine=engine, backend=backend, succeeds=False,
                                 contains="AssertionDefect")
            assert "actual == expected" in output and "wrong same-spelled Copy overload" in output, \
                "mutation must reach the independent selected-overload identity assertion"

assert source_hashes == {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                         for name in source_hashes}, "owner source changed during the gate"
(artifacts / "receipts.json").write_text(json.dumps({
    "source_base": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
    "engine_sha256": hashlib.sha256(nim.read_bytes()).hexdigest(),
    "source_sha256": source_hashes,
    "mutant_engine_sha256": mutant_engines,
    "receipts": receipts,
}, indent=2) + "\n")
print(f"Artifacts: {artifacts}")
