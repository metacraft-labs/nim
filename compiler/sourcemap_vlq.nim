## Base64 VLQ encoder for Source Map V3.
##
## Inverse of the decoder in `tests/js/tsourcemap.nim` (lines 47-57):
## the decoder reads continuation bits from the high bit of each
## base64 digit and shifts a 5-bit-at-a-time magnitude into place,
## with the bottom bit of the *first* digit serving as the sign bit.
## This encoder produces the same byte sequence in reverse.
##
## Used by `c_sourcemap.nim` to build the `mappings` field of the
## Source Map V3 JSON sidecar that the C backend emits next to each
## generated `.c` file when `--sourcemap:on` is set.

const
  alphabet* = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  continuationBit* = 1 shl 5
  valueMask* = continuationBit - 1   # 0b11111 — bottom 5 bits per digit

proc encodeVLQ*(n: int): string =
  ## Encode a signed integer as base64 VLQ.
  ##
  ## Layout of the first digit's 5 value bits:
  ##   bit 0: sign (1 = negative)
  ##   bits 1..4: low 4 magnitude bits
  ## Subsequent digits carry 5 magnitude bits each.
  ## The high bit (`continuationBit`) of every non-final digit is set.
  result = ""
  var value =
    if n < 0: ((-n) shl 1) or 1
    else: n shl 1
  while true:
    var digit = value and valueMask
    value = value shr 5
    if value > 0:
      digit = digit or continuationBit
    result.add alphabet[digit]
    if value == 0: break

proc encodeSegment*(generatedCol, sourceIdx, originalLine, originalCol: int;
                    nameIdx: int = -1): string =
  ## Encode one Source Map V3 mapping segment.
  ##
  ## All five fields are RELATIVE to the previous segment's values
  ## (or to zero for the first segment in the file), except
  ## `generatedCol` which resets to zero at every `;` line boundary.
  ## Pass `nameIdx = -1` to omit the optional 5th VLQ.
  result = encodeVLQ(generatedCol)
  result.add encodeVLQ(sourceIdx)
  result.add encodeVLQ(originalLine)
  result.add encodeVLQ(originalCol)
  if nameIdx >= 0:
    result.add encodeVLQ(nameIdx)

# ---------------------------------------------------------------------------
# Self-test: round-trip the encoder against an in-module decoder, exercising
# zero / single-digit / negative / multi-digit / large boundaries. This runs
# at compile time when the module is imported with `-d:nimSourcemapVlqTest`
# (or via the dedicated test in `tests/sourcemap/tc_sourcemap.nim`).

when defined(nimSourcemapVlqTest):
  import std/assertions

  proc decodeVLQ*(s: string): seq[int] =
    ## Reference decoder, byte-for-byte equivalent to the one in
    ## `tests/js/tsourcemap.nim:47-57`. Kept here only so the encoder
    ## can be self-tested without depending on the JS-backend tests.
    result = @[]
    var b64Table: array[128, int] = default(array[128, int])
    for i, c in alphabet:
      b64Table[c.ord] = i
    var
      shift = 0
      value = 0
    for c in s:
      let v = b64Table[c.ord]
      value += (v and valueMask) shl shift
      if (v and continuationBit) != 0:
        shift += 5
        continue
      result.add((value shr 1) * (if (value and 1) != 0: -1 else: 1))
      shift = 0
      value = 0

  static:
    # zero
    doAssert encodeVLQ(0) == "A"
    # 1..15 fit in one digit (single base64 char)
    doAssert encodeVLQ(1) == "C"
    doAssert encodeVLQ(15) == "e"
    # 16 spans two digits
    doAssert encodeVLQ(16).len == 2
    # round-trip a representative spread
    for n in [0, 1, -1, 15, 16, -16, 17, 100, -100, 1_000, -1_000,
              1_000_000, -1_000_000]:
      let encoded = encodeVLQ(n)
      let decoded = decodeVLQ(encoded)
      doAssert decoded.len == 1
      doAssert decoded[0] == n,
        "VLQ round-trip failed for " & $n & ": " & encoded &
        " decoded to " & $decoded
    # multi-VLQ segment round-trip
    let seg = encodeSegment(10, 0, 5, 7)
    let decoded = decodeVLQ(seg)
    doAssert decoded == @[10, 0, 5, 7], "segment round-trip failed: " &
      $decoded
    let segNamed = encodeSegment(2, 1, -3, 4, 0)
    let decodedNamed = decodeVLQ(segNamed)
    doAssert decodedNamed == @[2, 1, -3, 4, 0],
      "named segment round-trip failed: " & $decodedNamed
