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
## emission via the trace writer. Gated behind `-d:codetracerTracing`.

when not defined(codetracerTracing):
  {.error: "vm_value_serializer.nim requires -d:codetracerTracing".}

import vmdef, ast, renderer
import codetracer_trace_types

const
  MaxValueStringLen = 1000  ## Truncate rendered values longer than this

proc truncateValue(s: string): string =
  if s.len > MaxValueStringLen:
    s[0 ..< MaxValueStringLen] & "..."
  else:
    s

proc serializeVmValue*(reg: TFullReg, typ: PType = nil): ValueRecord =
  ## Convert a VM register value into a ValueRecord for the trace.
  ## No `ref` types are allocated here — ValueRecord is a plain object.
  case reg.kind
  of rkNone:
    result = ValueRecord(kind: vrkNone, noneTypeId: NoneTypeId)
  of rkInt:
    if typ != nil:
      case typ.kind
      of tyBool:
        result = ValueRecord(kind: vrkBool, boolVal: reg.intVal != 0,
                             boolTypeId: NoneTypeId)
      of tyChar:
        result = ValueRecord(kind: vrkChar, charVal: chr(reg.intVal and 0xFF),
                             charTypeId: NoneTypeId)
      of tyEnum:
        # Render as raw string with the enum type name
        result = ValueRecord(kind: vrkRaw,
                             rawStr: $reg.intVal,
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
    if reg.node.isNil:
      result = ValueRecord(kind: vrkNone, noneTypeId: NoneTypeId)
    else:
      # Render the AST node as a string value
      var valStr: string
      try:
        valStr = truncateValue(renderTree(reg.node))
      except CatchableError:
        valStr = "<render error>"

      if reg.node.typ != nil:
        case reg.node.typ.kind
        of tyString, tyCstring:
          result = ValueRecord(kind: vrkString, text: valStr,
                               strTypeId: NoneTypeId)
        of tyInt..tyInt64, tyUInt..tyUInt64:
          result = ValueRecord(kind: vrkInt,
                               intVal: int64(reg.node.intVal),
                               intTypeId: NoneTypeId)
        of tyFloat..tyFloat128:
          result = ValueRecord(kind: vrkFloat,
                               floatVal: float64(reg.node.floatVal),
                               floatTypeId: NoneTypeId)
        of tyBool:
          result = ValueRecord(kind: vrkBool,
                               boolVal: reg.node.intVal != 0,
                               boolTypeId: NoneTypeId)
        of tyChar:
          result = ValueRecord(kind: vrkChar,
                               charVal: chr(reg.node.intVal and 0xFF),
                               charTypeId: NoneTypeId)
        else:
          result = ValueRecord(kind: vrkRaw, rawStr: valStr,
                               rawTypeId: NoneTypeId)
      else:
        result = ValueRecord(kind: vrkRaw, rawStr: valStr,
                             rawTypeId: NoneTypeId)
  of rkRegisterAddr, rkNodeAddr:
    result = ValueRecord(kind: vrkRaw, rawStr: "<address>",
                         rawTypeId: NoneTypeId)
