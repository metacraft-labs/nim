import std/unittest
import munittest_protocol_body_hash_helper

suite "body hash fixture":
  test "affected":
    echo "affected body"
    check affectedValue(5) > 5

  test "unrelated":
    echo "unrelated body"
    check unrelatedValue() == 42
