type
  FixtureRun* = object
    payload*: JsonNode      ## nil when the process died before printing
    crashed*: bool          ## exitCode == CrashExitCode and a CRASH line present
    ## `HCR-M4-CRASH` line, and the publication window it announced before the

let Gates = @[
  GateSpec(
    envVar: "REPRO_M69_PASSWD_VM",      # REUSES the existing M69 env var
    needsRoot: true,                    # dscl + sysadminctl are system-scope
    # sysadminctl -addUser on a fresh macOS guest is the slow step
    timeoutSec: 600)]
