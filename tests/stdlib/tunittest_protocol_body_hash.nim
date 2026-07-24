discard """
  targets: "c"
  joinable: false
"""

import std/[assertions, json, os, osproc, strutils, syncio, tables, tempfiles]

const
  affectedName = "body hash fixture::affected"
  unrelatedName = "body hash fixture::unrelated"
  baselineHelper = """
proc affectedValue*(value: int): int =
  value + 1

proc unrelatedValue*(): int =
  42
"""
  changedHelper = """
proc affectedValue*(value: int): int =
  value + 2

proc unrelatedValue*(): int =
  42
"""

type
  CommandResult = tuple[output: string, exitCode: int]
  ProtocolSnapshot = object
    listHashes: Table[string, string]
    catalogHashes: Table[string, string]

proc runCommand(command: string): CommandResult =
  execCmdEx(command)

proc runBinary(binary: string; args: openArray[string]): CommandResult =
  var command = quoteShell(binary)
  for arg in args:
    command.add " "
    command.add quoteShell(arg)
  runCommand(command)

proc compileFixture(nim, libDir, source, buildDir, name: string): string =
  let nimcache = buildDir / (name & "_nimcache")
  result = buildDir / addFileExt(name, ExeExt)
  let command = quoteShell(nim) & " c --hints:off --verbosity:0" &
    " --lib:" & quoteShell(libDir) &
    " --nimcache:" & quoteShell(nimcache) &
    " -o:" & quoteShell(result) & " " & quoteShell(source)
  let compiled = runCommand(command)
  doAssert compiled.exitCode == 0, command & "\n" & compiled.output
  doAssert fileExists(result), "compiler did not produce " & result

proc hashesFromList(binary: string): Table[string, string] =
  let listed = runBinary(binary, ["--list-json"])
  doAssert listed.exitCode == 0, listed.output
  let document = parseJson(listed.output)
  doAssert document["summary"]["total"].getInt == 2, listed.output
  for item in document["tests"]:
    let name = item["name"].getStr
    doAssert not result.hasKey(name), "duplicate test in --list-json: " & name
    result[name] = item["bodyHash"].getStr

proc hashesFromCatalog(binary: string): Table[string, string] =
  let catalog = runBinary(binary, ["--catalog", "-"])
  doAssert catalog.exitCode == 0, catalog.output
  let document = parseJson(catalog.output)
  doAssert document["version"].getInt == 1, catalog.output
  for name, bodyHash in document["tests"]:
    result[name] = bodyHash.getStr

proc snapshot(binary: string): ProtocolSnapshot =
  result.listHashes = hashesFromList(binary)
  result.catalogHashes = hashesFromCatalog(binary)
  doAssert result.listHashes.len == 2
  doAssert result.catalogHashes.len == 2
  for name in [affectedName, unrelatedName]:
    doAssert result.listHashes.hasKey(name),
      "--list-json omitted expected test " & name
    doAssert result.catalogHashes.hasKey(name),
      "--catalog omitted expected test " & name
    doAssert result.listHashes[name].len > 0,
      "--list-json returned an empty bodyHash for " & name
    doAssert result.catalogHashes[name] == result.listHashes[name],
      "protocol endpoints disagree about bodyHash for " & name

proc checkDirectCompatibility(binary: string) =
  let direct = runBinary(binary, [])
  doAssert direct.exitCode == 0, direct.output
  doAssert direct.output.contains("affected body"), direct.output
  doAssert direct.output.contains("unrelated body"), direct.output

  let filtered = runBinary(binary, [affectedName])
  doAssert filtered.exitCode == 0, filtered.output
  doAssert filtered.output.contains("affected body"), filtered.output
  doAssert not filtered.output.contains("unrelated body"), filtered.output

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  let sourceFixture = currentSourcePath().parentDir /
    "munittest_protocol_body_hash_fixture.nim"
  let libDir = sourceFixture.parentDir.parentDir.parentDir / "lib"
  doAssert dirExists(libDir), "Nim library directory not found at: " & libDir
  let buildDir = createTempDir("tunittest_protocol_body_hash_", "")
  let source = buildDir / sourceFixture.extractFilename
  let helper = buildDir / "munittest_protocol_body_hash_helper.nim"
  try:
    writeFile(source, readFile(sourceFixture))
    writeFile(helper, baselineHelper)
    let baseline = compileFixture(nim, libDir, source, buildDir, "baseline")
    let repeated = compileFixture(nim, libDir, source, buildDir, "repeated")
    let baselineSnapshot = snapshot(baseline)
    let repeatedSnapshot = snapshot(repeated)

    for name in [affectedName, unrelatedName]:
      doAssert repeatedSnapshot.listHashes[name] ==
        baselineSnapshot.listHashes[name],
        "unchanged rebuild altered bodyHash for " & name
      doAssert repeatedSnapshot.catalogHashes[name] ==
        baselineSnapshot.catalogHashes[name],
        "unchanged rebuild altered catalog bodyHash for " & name

    writeFile(helper, changedHelper)
    let changed = compileFixture(nim, libDir, source, buildDir, "changed")
    let changedSnapshot = snapshot(changed)

    doAssert changedSnapshot.listHashes[affectedName] !=
      baselineSnapshot.listHashes[affectedName],
      "transitive helper change did not alter the affected test bodyHash"
    doAssert changedSnapshot.catalogHashes[affectedName] !=
      baselineSnapshot.catalogHashes[affectedName],
      "transitive helper change did not alter the affected catalog bodyHash"
    doAssert changedSnapshot.listHashes[unrelatedName] ==
      baselineSnapshot.listHashes[unrelatedName],
      "transitive helper change altered the unrelated test bodyHash"
    doAssert changedSnapshot.catalogHashes[unrelatedName] ==
      baselineSnapshot.catalogHashes[unrelatedName],
      "transitive helper change altered the unrelated catalog bodyHash"

    checkDirectCompatibility(baseline)
  finally:
    removeDir(buildDir)

main()
