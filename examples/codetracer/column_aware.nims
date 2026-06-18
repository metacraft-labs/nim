## Column-aware step demo. The first line packs three `var` statements
## onto a single source line; the column-aware Nim VM tracer in this
## fork surfaces each one (and each sub-expression) as a distinct step
## instead of collapsing them all to one "line 1" event.
##
## This is a `.nims` script — run it through the VM via `ct run` (or
## record it with `ct record`) and watch the step counter on line 1
## advance multiple times.

var a = 1; var b = 2; var c = 3
echo a, " ", b, " ", c
