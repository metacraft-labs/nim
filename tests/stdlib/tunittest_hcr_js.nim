discard """
  targets: "js"
  matrix: "--hotCodeReloading:on"
  output: '''

[Suite] unittest under JS hot-code reloading
JS HCR unittest case executed
'''
"""

import std/unittest

proc expectEqual(a, b: int) =
  check a == b

suite "unittest under JS hot-code reloading":
  test "executes a passing helper check":
    expectEqual(1, 1)
    echo "JS HCR unittest case executed"
