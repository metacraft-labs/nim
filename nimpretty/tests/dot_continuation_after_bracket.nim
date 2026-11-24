    for argv in [
        @["system", "adopt", "--profile", "p"]]:           # address missing
      for line in stateRestoreUnitText("/usr/local/repro/bin/repro").
          splitLines():
        if line.startsWith("ExecStart="):
          execStart = line["ExecStart=".len .. ^1]
