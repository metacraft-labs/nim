## Native compiler-wrapper regression: build the actual owning source through
## the existing typed Nim/GCC tool graph. The resulting image is a test subject,
## never a replacement for the installed compiler's wrapper.
import repro_project_dsl

package vccexe_regression:
  defaultToolProvisioning "tarball"
  uses:
    "nim >=2.2 <3"
    "gcc >=12"

  build:
    # Internal test subject, not a new published package executable/API.
    let wrapper = nim.c(source = "../../tools/vccexe/vccexe.nim",
                        binary = "vccexe-under-test")
    discard collect("test-builds", @[wrapper])
