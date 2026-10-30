## Keep the normal POSIX flake environment. The Windows-only internal target
## builds the wrapper regression's test subject, never an installed replacement.
import repro_project_dsl
import repro_dsl_stdlib/foreign_env

package codetracernimEnvironment:
  when defined(windows):
    defaultToolProvisioning "tarball"
    uses:
      "nim >=2.2 <3"
      "gcc >=12"

    build:
      let wrapper = nim.c(source = "tools/vccexe/vccexe.nim",
                          binary = "build/test-tools/vccexe-under-test")
      discard collect("test-builds", @[wrapper])
  else:
    devEnv:
      useFlakeDevShell()
