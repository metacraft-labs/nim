# Statement blocks that open inside an expression, and continuation lines
# around them, must keep the indentation that gives them their meaning.

# The body of a proc passed as an object field stays deeper than the field.
proc install() =
  setService(Service(
    pollIntervalMs: 10,
    start: proc(config: Config): string =
      let rawSpec =
        if config.peerCacheSpec.len > 0: config.peerCacheSpec
        else: getEnv("PEER_CACHE")
      if rawSpec.len == 0 or rawSpec == "none":
        return ""
      result = rawSpec))

# No split goes before the `)` of an empty call, even when the next line
# could be rejoined.
proc branch() =
  if recordedBranch.isSome:
    workspaceBranch = recordedBranch.get()
  elif workspaceLocal.isSome and workspaceLocal.get().workspace.branch.isSome and
      workspaceLocal.get().workspace.branch.get().len > 0:
    workspaceBranch = workspaceLocal.get().workspace.branch.get()
  else:
    workspaceBranch = defaultBranch

# A line that starts with a closing bracket continues the expression; the
# block after it stays a block.
proc closing() =
  if recordedBranch.isSome:
    discard
  elif workspaceLocal.isSome and workspaceLocal.get(
      ).workspace.branch.isSome:
    workspaceBranch = workspaceLocal.get().workspace.branch.get()
  else:
    discard

# An element that follows a comment inside a bracket is still an element, and
# the lines of that comment keep their own alignment.
proc typecheck() =
  let (code, output) = runCapturing(nim,
    ["check", "--hints:off", "--warnings:off",
     # The full DSL: without a mode define the import is the thin mode,
     # which does not type-check build bodies.
     "--define:evalMode",
     "--nimcache:" & nimcache, projectFile],
    repoRoot)

# A parameter list that nimpretty splits keeps the body of its proc where the
# first pass put it.
when true:
  const pipeInput = InputStreamVTable(
    readSync: proc (s: InputStream, dst: pointer,
        dstLen: Natural): Natural {.iocall.} =
      translateErrors "Failed to read from pipe":
        return waitFor pipeRead(s, dst, dstLen),
    closeSync: proc (s: InputStream) =
      discard)

# A split nimpretty makes inside the bracket that holds a proc does not move
# the body of that proc on the next pass.
proc mount() =
  discard r.mountPropertyRow(hostEl, propertyRowText(
    name = "Dash pattern", value = dashPattern,
    wiring = InspectorRowWiring(commitMessage: createSignal(""),
        readOnlyReason: proc(): string =
      "Dash patterns cannot be edited in the inspector yet.")))
