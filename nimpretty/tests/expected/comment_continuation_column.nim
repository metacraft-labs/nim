const
  VolatileKeys* = [
    # Each of these changes between two reads on an idle host; none is
    # configuration.
    "kernel.perf_event_max_sample_rate", # lowered by the kernel itself when
                                         # perf interrupts run long
  ]
