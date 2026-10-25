# Real owned references and native hooks; no mocks or synthetic finalizers.
var finalized*: int
var hooks*: array[2, int]
type TokenData* = object of RootObj
  marker*: string
proc `=destroy`(value: var TokenData) =
  inc finalized
  `=destroy`(value.marker)
type Token* = ref TokenData
when defined(phantomAlias):
  type Secret*[T] = Token
else:
  type Secret*[T] = distinct Token
type
  Base* = ref object of RootObj
  Container*[T] = ref object of Base
    value*: T
  ValueContainer*[T] = object
    value*: T
  Nominal*[T] = object
    marker*: string
proc `=destroy`*[T](value: var Nominal[T]) =
  when T is string: inc hooks[0]
  else: inc hooks[1]
  `=destroy`(value.marker)
proc secret*[T](value: T): Secret[T] = Secret[T](Token(marker: "owned"))
proc create*[T](value: T): Container[T] = Container[T](value: value)
