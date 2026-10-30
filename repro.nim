## Keep the normal POSIX flake environment. The Windows job selects tarballs
## through REPRO_TOOL_PROVISIONING and builds an internal wrapper test subject.
import repro_project_dsl
import repro_dsl_stdlib/foreign_env

package codetracernimEnvironment:
  defaultToolProvisioning "path"
  uses:
    "nim >=2.2 <3"
    "gcc >=12"

  devEnv:
    when not defined(windows):
      useFlakeDevShell()

  build:
    when defined(windows):
      let wrapper = nim.c(source = "tools/vccexe/vccexe.nim",
                          binary = "build/test-tools/vccexe-under-test")
      discard collect("test-builds", @[wrapper])
