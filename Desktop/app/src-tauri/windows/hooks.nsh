; Removes this app's MCP registration before its files disappear.
; Other MCP servers and the user's saved data are left in place.
!macro NSIS_HOOK_PREUNINSTALL
  nsExec::Exec '"$INSTDIR\sudo-interns-engine.exe" disconnect'
  Pop $0
!macroend
