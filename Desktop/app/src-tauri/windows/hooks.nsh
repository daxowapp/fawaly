; Removes this app's MCP registration once the uninstall can no longer be cancelled.
; The installed files are gone by now, so this uses the launcher in the data folder,
; which exists whenever a registration does. An upgrade keeps the connection.
; Other MCP servers and the user's saved data are left in place.
!macro NSIS_HOOK_POSTUNINSTALL
  ${If} $UpdateMode <> 1
    SetShellVarContext current
    nsExec::Exec '"$APPDATA\SudoInterns\bin\sudo-interns-engine.exe" disconnect'
    Pop $0
  ${EndIf}
!macroend
