## Tools for the owning Windows maintenance-prefix factory, not an installer.
import repro_project_dsl
import repro_dsl_stdlib/packages/pkg_7zip

package nimMaintenancePrefix:
  defaultToolProvisioning "tarball"
  uses:
    "nim ==2.2.10"
    "gcc >=12"
    "git"
    "7zip"

  devEnv:
    discard
