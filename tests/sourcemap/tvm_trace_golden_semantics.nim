discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""
## No mocks: real compiler, CTFS materializer and Testament snapshot comparator.
## Independent semantic checks prevent blindly regenerated goldens blessing a
## call-order or post-return attribution regression. Mutations use private copies.
import std/[os, osproc, json, strutils, tables]
import ../../testament/ctfs_snapshot

proc main() =
  let work = currentSourcePath.parentDir / "build_golden_semantics"
  createDir(work)
  defer: removeDir(work)
  for name in ["tvm_trace_call_key_order", "tvm_trace_function_attr_template"]:
    let source = currentSourcePath.parentDir / (name & ".nim")
    let trace = work / (name & ".ct")
    let (output, code) = execCmdEx(quoteShell(getCurrentCompilerExe()) &
      " e --trace:" & quoteShell(trace) & " " & quoteShell(source))
    doAssert code == 0, output
    let materialized = materializeTrace(trace)
    doAssert materialized.ok, materialized.detail
    var entries = initTable[int, JsonNode]()
    var exits = initTable[int, JsonNode]()
    var lastKey = -1
    var postReturnOwners: seq[string]
    var integerValues = 0
    for event in materialized.json["events"]:
      case event["kind"].getStr
      of "call_entry":
        let key = event["call_key"].getInt
        doAssert key > lastKey, "call keys must increase at entry"
        lastKey = key
        let parent = event["parent_call_key"].getInt
        if parent >= 0:
          doAssert entries.hasKey(parent) and parent < key
          doAssert event["depth"].getInt == entries[parent]["depth"].getInt + 1
        entries[key] = event
      of "call_exit":
        let key = event["call_key"].getInt
        doAssert entries.hasKey(key)
        doAssert event["function"] == entries[key]["function"]
        doAssert event["return_value"]["kind"].getStr == "Void"
        exits[key] = event
      of "step":
        doAssert event["path"].getStr.endsWith(name & ".nim")
        for key, returned in exits:
          let parent = entries[key]["parent_call_key"].getInt
          if parent >= 0 and not exits.hasKey(parent):
            doAssert event["function"] == entries[parent]["function"],
              "post-return source step lost its enclosing function"
            doAssert event["depth"] == entries[parent]["depth"]
            let owner = event["function"].getStr
            if owner notin postReturnOwners: postReturnOwners.add(owner)
        for variable in event["vars"]:
          doAssert variable["type_name"].getStr == "int"
          doAssert variable["value"]["kind"].getStr == "Int"
          inc integerValues
      else: discard
    doAssert entries.len == exits.len and entries.len > 0
    if name == "tvm_trace_call_key_order":
      doAssert entries.len == 2
      doAssert entries[0]["function"].getStr == "outer"
      doAssert entries[1]["function"].getStr == "inner"
    else:
      doAssert "directCallSite" in postReturnOwners and "pg" in postReturnOwners
      doAssert integerValues >= 4
    let golden = work / (name & ".json")
    copyFile(source & ".evaltrace.json", golden)
    let positive = runSnapshotCheck(source, golden, trace)
    doAssert positive.outcome == snapPass, positive.detail
    var corrupted = parseFile(golden)
    var changed = false
    for event in corrupted["events"]:
      if event["kind"].getStr == "call_entry":
        event["call_key"] = %999
        changed = true
        break
    doAssert changed
    writeFile(golden, renderJsonStable(corrupted))
    let negative = runSnapshotCheck(source, golden, trace)
    doAssert negative.outcome == snapMismatch, negative.detail
    doAssert "call_key" in negative.detail
    echo "PASS: semantics and corrupted-golden control: ", name

main()
