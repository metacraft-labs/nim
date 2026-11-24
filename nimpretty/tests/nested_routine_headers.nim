proc tickEventLogEnabled*(): bool =
  proc winRegQueryValueEx(key: WinHkey; name: ptr uint16; reserved: ptr WinDword;
      source: ptr uint16): WinHandle
  proc winReportEvent(handle: WinHandle; eventType, category: uint16;
      rawData: pointer): WinBool
