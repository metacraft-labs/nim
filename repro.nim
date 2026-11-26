## Keep the normal POSIX flake environment. The Windows job selects tarballs
## through REPRO_TOOL_PROVISIONING and builds an internal wrapper test subject.
import repro_project_dsl
import repro_dsl_stdlib/foreign_env

package codetracernimEnvironment:
  defaultToolProvisioning "path"
  # CI clones these siblings beside the checkout (.github/sibling-repos),
  # and clone-siblings resolves each one from the committed lock, so the
  # lock must pin them. No build edge declares them with `uses:`: the dev
  # shell links them into dist/, so they are pinned, not used.
  pinned:
    "codetracer-trace-format-nim"
    "nim-stew"

  uses:
    "nim >=2.2 <3"
    "gcc >=12"

  devEnv:
    when not defined(windows):
      useFlakeDevShell()
