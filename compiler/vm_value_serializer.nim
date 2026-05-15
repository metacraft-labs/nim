#
#
#           The Nim Compiler
#        (c) Copyright 2024 Metacraft Labs
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## VM register value serialization for CodeTracer.
##
## Converts `TFullReg` values into `ValueRecord` objects suitable for
## emission via the trace writer. CTFS-M1 update: compiles unconditionally
## into `bin/nim`; runtime emission is gated by `--trace:<path>`.
##
## CTFS-M-ComplexTypes (this revision): aggregate values (seq, array,
## tuple, object, variant, set, ref) are walked recursively into nested
## ValueRecord variants (vrkSequence, vrkTuple, vrkStruct, vrkVariant,
## vrkReference) instead of being flattened into opaque renderTree
## strings.  A `depth` counter (capped at `MaxSerializationDepth`)
## guards against cyclic refs and pathologically nested aggregates —
## hitting the cap downgrades that sub-value to `vrkRaw` carrying the
## renderTree fallback.

import vmdef, ast, renderer
import codetracer_trace_types

const
  MaxValueStringLen = 1000  ## Truncate rendered values longer than this
  MaxSerializationDepth = 64
    ## Hard ceiling on recursive ValueRecord construction. Picked
    ## empirically: handles realistic nested data structures with room
    ## to spare while keeping cyclic `ref` graphs from blowing the
    ## stack. Sub-values at the cap fall back to `vrkRaw`.

proc truncateValue(s: string): string =
  if s.len > MaxValueStringLen:
    s[0 ..< MaxValueStringLen] & "..."
  else:
    s

proc rawFromNode(node: PNode): ValueRecord =
  ## Last-resort fallback: render an AST node textually and wrap as vrkRaw.
  var valStr: string
  try:
    valStr = truncateValue(renderTree(node))
  except CatchableError:
    valStr = "<render error>"
  ValueRecord(kind: vrkRaw, rawStr: valStr, rawTypeId: NoneTypeId)

proc enumSymbolName(typ: PType, ordinal: BiggestInt): string =
  ## Look up the enum symbol whose `position` matches `ordinal`. Falls
  ## back to the stringified ordinal when no match is found (e.g. for
  ## holey enums with an out-of-range value).
  result = $ordinal
  if typ != nil and typ.n != nil:
    for i in 0 ..< typ.n.len:
      let child = typ.n[i]
      if child.kind == nkSym and child.sym.position == ordinal.int:
        return child.sym.name.s

proc isCaseObjectType(typ: PType): bool =
  ## Returns true if the object type carries a case-discriminated field.
  ## Walks inherited bases as well.
  result = false
  if typ == nil: return
  var t = typ.skipTypes(abstractInst)
  while t != nil and t.kind == tyObject:
    if t.n != nil:
      for i in 0 ..< t.n.len:
        if t.n[i].kind == nkRecCase:
          return true
    t = t.baseClass

proc findCaseBranchInRecCase(recCase: PNode, discValue: BiggestInt): PNode =
  ## Given an `nkRecCase` node and a discriminator integer value, return
  ## the matching branch (an nkOfBranch or nkElse) whose `lastSon` is
  ## the active fields RecList, or nil if no branch matches.
  if recCase.kind != nkRecCase: return nil
  for i in 1 ..< recCase.len:
    let br = recCase[i]
    case br.kind
    of nkOfBranch:
      # Branch labels are children 0..^2; lastSon is the field record list.
      for j in 0 ..< br.len - 1:
        let lab = br[j]
        case lab.kind
        of nkIntLit..nkUInt64Lit:
          if lab.intVal == discValue: return br
        of nkRange:
          if lab.len >= 2 and
             lab[0].kind in {nkIntLit..nkUInt64Lit} and
             lab[1].kind in {nkIntLit..nkUInt64Lit} and
             discValue >= lab[0].intVal and discValue <= lab[1].intVal:
            return br
        of nkSym:
          if lab.sym.position == discValue.int: return br
        else: discard
    of nkElse:
      return br
    else: discard
  nil

proc activeFieldNamesForVariant(typ: PType, discValue: BiggestInt): seq[string] =
  ## Return the *payload* field names (excluding the discriminator)
  ## active for the given discriminator value. Walks the type's
  ## `nkRecCase` to pick the matching branch.
  result = @[]
  if typ == nil or typ.n == nil: return
  for i in 0 ..< typ.n.len:
    let child = typ.n[i]
    if child.kind == nkRecCase:
      let br = findCaseBranchInRecCase(child, discValue)
      if br != nil:
        let recList = lastSon(br)
        if recList != nil:
          case recList.kind
          of nkRecList:
            for j in 0 ..< recList.len:
              let f = recList[j]
              if f.kind == nkSym:
                result.add f.sym.name.s
          of nkSym:
            result.add recList.sym.name.s
          else: discard

proc serializeNode(node: PNode, typ: PType, depth: int): ValueRecord
  ## Forward declaration — recursive walker that, given a PNode plus a
  ## (possibly nil) PType hint, produces a structured ValueRecord.

proc childType(node: PNode, fallback: PType): PType =
  if node != nil and node.typ != nil: node.typ else: fallback

proc serializeSequenceLike(node: PNode, typ: PType, depth: int): ValueRecord =
  ## Walk an `nkBracket` (seq / array / openArray) into `vrkSequence`.
  let elemTy = if typ != nil and typ.hasElementType: typ.elementType else: nil
  var elems: seq[ValueRecord] = @[]
  for i in 0 ..< node.safeLen:
    elems.add serializeNode(node[i], childType(node[i], elemTy), depth + 1)
  ValueRecord(kind: vrkSequence, seqElements: elems, isSlice: false,
              seqTypeId: NoneTypeId)

proc serializeTupleConstr(node: PNode, typ: PType, depth: int): ValueRecord =
  ## Walk an `nkTupleConstr` into `vrkTuple` (positional order).
  var elems: seq[ValueRecord] = @[]
  for i in 0 ..< node.safeLen:
    let child = node[i]
    # tuple slots may be either bare values or `nkExprColonExpr(field, val)`.
    let val = if child.kind == nkExprColonExpr: child[1] else: child
    # Type of the slot: prefer the tuple type's i-th element if available.
    var slotTy: PType = nil
    if typ != nil and typ.kind == tyTuple and i < typ.len:
      slotTy = typ[i]
    elems.add serializeNode(val, childType(val, slotTy), depth + 1)
  ValueRecord(kind: vrkTuple, tupleElements: elems, tupleTypeId: NoneTypeId)

proc collectObjFields(node: PNode, depth: int,
                      outNames: var seq[string],
                      outVals: var seq[ValueRecord]) =
  ## Walk an `nkObjConstr` and gather `(name, ValueRecord)` pairs in
  ## construction order. Child 0 is the type sentinel; children 1..n are
  ## each `nkExprColonExpr(fieldSym, value)` (or, defensively, a bare
  ## value when produced by a degenerate code path).
  for i in 1 ..< node.safeLen:
    let child = node[i]
    if child.kind == nkExprColonExpr and child.len == 2:
      let fieldSym = child[0]
      let value = child[1]
      let name =
        if fieldSym.kind == nkSym: fieldSym.sym.name.s
        else: ""
      let fieldTy =
        if fieldSym.kind == nkSym: fieldSym.sym.typ
        else: nil
      outNames.add name
      outVals.add serializeNode(value, childType(value, fieldTy), depth + 1)
    else:
      outNames.add ""
      outVals.add serializeNode(child, childType(child, nil), depth + 1)

proc serializeObject(node: PNode, typ: PType, depth: int): ValueRecord =
  ## Emit an `nkObjConstr` as either `vrkStruct` (plain object) or
  ## `vrkVariant` (case object). The materializer pairs vrkStruct field
  ## values with names taken from the TypeRecord; we therefore preserve
  ## construction order so external type-side metadata can re-attach
  ## names when needed.
  var names: seq[string] = @[]
  var vals: seq[ValueRecord] = @[]
  collectObjFields(node, depth, names, vals)

  if not isCaseObjectType(typ):
    return ValueRecord(kind: vrkStruct, fieldValues: vals,
                       structTypeId: NoneTypeId)

  # Case object — locate the discriminator (a field whose type is
  # tyEnum / tyBool / tyChar / int-ish AND is the discriminator-side of
  # an nkRecCase). The simplest robust strategy: pick the first field
  # whose name matches the discriminator-sym name in any nkRecCase.
  var discNames: seq[string] = @[]
  var t = typ.skipTypes(abstractInst)
  while t != nil and t.kind == tyObject:
    if t.n != nil:
      for i in 0 ..< t.n.len:
        if t.n[i].kind == nkRecCase and t.n[i].len > 0 and
           t.n[i][0].kind == nkSym:
          discNames.add t.n[i][0].sym.name.s
    t = t.baseClass

  var discIdx = -1
  for i, n in names:
    if n in discNames:
      discIdx = i
      break

  if discIdx < 0:
    # Couldn't locate a discriminator — fall back to vrkStruct rather
    # than emitting a half-formed vrkVariant.
    return ValueRecord(kind: vrkStruct, fieldValues: vals,
                       structTypeId: NoneTypeId)

  let disc = vals[discIdx]
  var discText = ""
  case disc.kind
  of vrkInt: discText = $disc.intVal
  of vrkRaw:
    # The format library has no dedicated vrkEnum variant; the top-
    # level enum path emits `vrkRaw` carrying the symbol name. If the
    # discriminator already arrived in that shape, use it verbatim.
    discText = disc.rawStr
  of vrkString: discText = disc.text
  of vrkChar: discText = $disc.charVal
  of vrkBool: discText = $disc.boolVal
  else: discText = ""

  # Replace `disc` with the symbolic enum name when we can recover it.
  let discFieldSym =
    block:
      var sym: PSym = nil
      let tn = typ.skipTypes(abstractInst).n
      if tn != nil:
        for i in 0 ..< tn.len:
          if tn[i].kind == nkRecCase and tn[i].len > 0 and
             tn[i][0].kind == nkSym and
             tn[i][0].sym.name.s == names[discIdx]:
            sym = tn[i][0].sym
            break
      sym

  var discOrdinal: BiggestInt = 0
  var haveOrdinal = false
  case disc.kind
  of vrkInt:
    discOrdinal = disc.intVal
    haveOrdinal = true
  else: discard

  if haveOrdinal and discFieldSym != nil and
     discFieldSym.typ != nil and
     discFieldSym.typ.skipTypes(abstractInst).kind == tyEnum:
    discText = enumSymbolName(discFieldSym.typ.skipTypes(abstractInst),
                              discOrdinal)

  # Payload = all *active* non-discriminator fields. For accuracy we
  # restrict to the active branch's field-name set; common fields
  # (declared outside the `case` block) plus the active branch.
  var activeBranchFields: seq[string] = @[]
  if haveOrdinal:
    activeBranchFields = activeFieldNamesForVariant(
      typ.skipTypes(abstractInst), discOrdinal)

  # Common (non-case) fields — anything in `names` whose name is not a
  # discriminator and not declared *only* under a different branch.
  var allCaseFieldNames: seq[string] = @[]
  block collectCaseFields:
    let tn = typ.skipTypes(abstractInst).n
    if tn != nil:
      for i in 0 ..< tn.len:
        if tn[i].kind == nkRecCase:
          for j in 1 ..< tn[i].len:
            let br = tn[i][j]
            let rl = lastSon(br)
            if rl != nil:
              case rl.kind
              of nkRecList:
                for k in 0 ..< rl.len:
                  if rl[k].kind == nkSym:
                    allCaseFieldNames.add rl[k].sym.name.s
              of nkSym:
                allCaseFieldNames.add rl.sym.name.s
              else: discard

  var payloadVals: seq[ValueRecord] = @[]
  for i, n in names:
    if i == discIdx: continue
    if n in discNames: continue
    if n in allCaseFieldNames and n notin activeBranchFields:
      continue  # branch-local field belonging to an inactive branch
    payloadVals.add vals[i]

  # `vrkVariant.contents` is exactly one ValueRecord — wrap the payload
  # in a vrkStruct (the materializer can decode it).
  let payload = ValueRecord(kind: vrkStruct, fieldValues: payloadVals,
                            structTypeId: NoneTypeId)
  ValueRecord(kind: vrkVariant, discriminator: discText,
              contents: @[payload], variantTypeId: NoneTypeId)

proc serializeSet(node: PNode, typ: PType, depth: int): ValueRecord =
  ## Walk an `nkCurly` set literal. Each element is either a bare
  ## literal or an `nkRange(a, b)`. We flatten ranges into their
  ## member values for `vrkSequence` representation; for large ranges
  ## we cap at a defensive limit to avoid explosion.
  const RangeExpandCap = 1024
  let elemTy = if typ != nil and typ.hasElementType: typ.elementType else: nil
  var elems: seq[ValueRecord] = @[]
  for i in 0 ..< node.safeLen:
    let child = node[i]
    if child.kind == nkRange and child.len == 2 and
       child[0].kind in {nkIntLit..nkUInt64Lit, nkCharLit} and
       child[1].kind in {nkIntLit..nkUInt64Lit, nkCharLit}:
      let lo = child[0].intVal
      let hi = child[1].intVal
      var v = lo
      var n = 0
      while v <= hi and n < RangeExpandCap:
        # Synthesize a literal node of the matching kind so
        # serializeNode picks vrkChar/vrkInt correctly.
        let synth = newIntTypeNode(v, childType(child[0], elemTy))
        elems.add serializeNode(synth, childType(synth, elemTy), depth + 1)
        inc v
        inc n
    else:
      elems.add serializeNode(child, childType(child, elemTy), depth + 1)
  # vrkSequence is the closest match — there is no vrkSet variant in
  # the current format-library ValueRecord enum. The materializer
  # treats it the same as a sequence; the TypeRecord-side type id
  # disambiguates set vs seq for renderers that care.
  ValueRecord(kind: vrkSequence, seqElements: elems, isSlice: false,
              seqTypeId: NoneTypeId)

proc serializeRef(node: PNode, typ: PType, depth: int): ValueRecord =
  ## tyRef: either nil (vrkNone) or an aggregate-allocating wrapper.
  if node.isNil or node.kind == nkNilLit:
    return ValueRecord(kind: vrkNone, noneTypeId: NoneTypeId)
  # In the VM, an allocated ref is represented as the underlying
  # PNode with `nfIsRef` set on its flags. The "address" is best
  # represented by the node's pointer cast (stable within a run).
  let address = cast[uint64](node)
  # The dereferenced sub-value carries the underlying type without the
  # ref wrapper.
  var derefTy = typ
  if derefTy != nil:
    derefTy = derefTy.skipTypes(abstractInst)
    if derefTy != nil and derefTy.kind == tyRef and derefTy.hasElementType:
      derefTy = derefTy.elementType
  let inner = serializeNode(node, childType(node, derefTy), depth + 1)
  ValueRecord(kind: vrkReference, dereferenced: @[inner],
              address: address, mutable: true, refTypeId: NoneTypeId)

proc serializeNode(node: PNode, typ: PType, depth: int): ValueRecord =
  ## Recursive PNode → ValueRecord walker. Used both as the top-level
  ## entry (from `serializeVmValue` when `reg.kind == rkNode`) and to
  ## recurse into aggregate sub-values.
  if node.isNil:
    return ValueRecord(kind: vrkNone, noneTypeId: NoneTypeId)
  if depth > MaxSerializationDepth:
    return rawFromNode(node)

  # Atom-style nodes: dispatch by node kind first so we never call
  # renderTree on a primitive literal.
  case node.kind
  of nkNilLit:
    return ValueRecord(kind: vrkNone, noneTypeId: NoneTypeId)
  of nkStrLit..nkTripleStrLit:
    return ValueRecord(kind: vrkString, text: truncateValue(node.strVal),
                       strTypeId: NoneTypeId)
  of nkCharLit:
    return ValueRecord(kind: vrkChar,
                       charVal: chr(node.intVal and 0xFF),
                       charTypeId: NoneTypeId)
  of nkFloatLit..nkFloat128Lit:
    return ValueRecord(kind: vrkFloat, floatVal: float64(node.floatVal),
                       floatTypeId: NoneTypeId)
  of nkIntLit..nkUInt64Lit:
    # Bool / char / enum disguised as nkIntLit when the type is
    # available.
    let nodeTy =
      if typ != nil: typ.skipTypes(abstractInst)
      elif node.typ != nil: node.typ.skipTypes(abstractInst)
      else: nil
    if nodeTy != nil:
      case nodeTy.kind
      of tyBool:
        return ValueRecord(kind: vrkBool, boolVal: node.intVal != 0,
                           boolTypeId: NoneTypeId)
      of tyChar:
        return ValueRecord(kind: vrkChar,
                           charVal: chr(node.intVal and 0xFF),
                           charTypeId: NoneTypeId)
      of tyEnum:
        # Encode enum-as-int; consumers map ordinal back through the
        # TypeRecord. The discriminator path in serializeObject does
        # its own symbol-name lookup.
        return ValueRecord(kind: vrkInt, intVal: int64(node.intVal),
                           intTypeId: NoneTypeId)
      else: discard
    return ValueRecord(kind: vrkInt, intVal: int64(node.intVal),
                       intTypeId: NoneTypeId)
  else: discard

  # Aggregate-shaped nodes: dispatch on node.kind directly. Falling
  # back to the type hint when the node kind is generic.
  case node.kind
  of nkBracket:
    return serializeSequenceLike(node, typ, depth)
  of nkTupleConstr:
    return serializeTupleConstr(node, typ, depth)
  of nkObjConstr:
    return serializeObject(node, typ, depth)
  of nkCurly:
    return serializeSet(node, typ, depth)
  else: discard

  # Type-driven dispatch for nodes whose kind alone doesn't reveal the
  # shape (e.g. nkSym pointing at a global aggregate).
  if typ != nil:
    let t = typ.skipTypes(abstractInst)
    case t.kind
    of tyString, tyCstring:
      # Defensive: if the node happens to be a string-shaped node
      # we didn't catch above (rare), fall through to renderTree.
      discard
    of tyRef:
      return serializeRef(node, typ, depth)
    of tySequence, tyArray, tyOpenArray:
      return serializeSequenceLike(node, typ, depth)
    of tyTuple:
      return serializeTupleConstr(node, typ, depth)
    of tyObject:
      return serializeObject(node, typ, depth)
    of tySet:
      return serializeSet(node, typ, depth)
    else: discard

  rawFromNode(node)

proc serializeVmValue*(reg: TFullReg, typ: PType = nil): ValueRecord =
  ## Convert a VM register value into a ValueRecord for the trace.
  ## No `ref` types are allocated here — ValueRecord is a plain object.
  case reg.kind
  of rkNone:
    result = ValueRecord(kind: vrkNone, noneTypeId: NoneTypeId)
  of rkInt:
    if typ != nil:
      case typ.skipTypes(abstractInst).kind
      of tyBool:
        result = ValueRecord(kind: vrkBool, boolVal: reg.intVal != 0,
                             boolTypeId: NoneTypeId)
      of tyChar:
        result = ValueRecord(kind: vrkChar, charVal: chr(reg.intVal and 0xFF),
                             charTypeId: NoneTypeId)
      of tyEnum:
        # Enums in registers carry the ordinal in `intVal`. We surface
        # the *symbolic* name in `vrkRaw.rawStr` (the format library
        # has no vrkEnum variant) so downstream consumers and the
        # existing tests can read it directly. The numeric ordinal is
        # recoverable via the TypeRecord.
        let t = typ.skipTypes(abstractInst)
        result = ValueRecord(kind: vrkRaw,
                             rawStr: enumSymbolName(t, reg.intVal),
                             rawTypeId: NoneTypeId)
      else:
        result = ValueRecord(kind: vrkInt, intVal: int64(reg.intVal),
                             intTypeId: NoneTypeId)
    else:
      result = ValueRecord(kind: vrkInt, intVal: int64(reg.intVal),
                           intTypeId: NoneTypeId)
  of rkFloat:
    result = ValueRecord(kind: vrkFloat, floatVal: float64(reg.floatVal),
                         floatTypeId: NoneTypeId)
  of rkNode:
    result = serializeNode(reg.node, typ, 0)
  of rkRegisterAddr, rkNodeAddr:
    result = ValueRecord(kind: vrkRaw, rawStr: "<address>",
                         rawTypeId: NoneTypeId)
