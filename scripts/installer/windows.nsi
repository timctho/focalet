Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "nsDialogs.nsh"
!include "FileFunc.nsh"

Var RemoveData
Var RemoveDataCheckbox

Name "Focalet"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\Focalet"
InstallDirRegKey HKCU "Software\Focalet" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey "ProductName" "Focalet"
VIAddVersionKey "FileDescription" "Focalet Setup"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "LegalCopyright" "Focalet contributors"
!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\Focalet.exe"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
UninstPage custom un.DataOptions un.DataOptionsLeave
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  Call RequireClosed
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "Focalet requires 64-bit Windows."
    Abort
  ${EndIf}
FunctionEnd

!macro RequireClosed Prefix
Function ${Prefix}RequireClosed
retry:
  System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "Local\Focalet.Desktop.SingleInstance") p.r0'
  StrCmp $0 0 checkFile
  System::Call 'kernel32::CloseHandle(p r0)'
  Goto busy
checkFile:
  ; Earlier desktop versions did not own the current single-instance mutex.
  IfFileExists "$INSTDIR\Focalet.exe" 0 done
  ClearErrors
  FileOpen $0 "$INSTDIR\Focalet.exe" a
  IfErrors busy
  FileClose $0
  Goto done
busy:
  IfSilent fail
  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "Close Focalet (including its tray icon) before continuing. This prevents an incomplete update or reset." IDRETRY retry
fail:
  SetErrorLevel 2
  Abort
done:
FunctionEnd
!macroend
!insertmacro RequireClosed ""
!insertmacro RequireClosed "un."

Function un.onInit
  Call un.RequireClosed
  StrCpy $RemoveData 0
  ${GetParameters} $0
  ${GetOptions} $0 "/PURGE=" $1
  StrCmp $1 "1" 0 +2
  StrCpy $RemoveData 1
FunctionEnd

Function un.DataOptions
  nsDialogs::Create 1018
  Pop $0
  ${NSD_CreateLabel} 0 0 100% 36u "Choose whether to keep Focalet ready for a future reinstall or start fresh. Agent accounts and agent-owned conversations are kept in either case."
  Pop $0
  ${NSD_CreateCheckbox} 0 48u 100% 32u "Remove all Focalet settings, cached agent detection and local session metadata"
  Pop $RemoveDataCheckbox
  ${NSD_SetState} $RemoveDataCheckbox $RemoveData
  nsDialogs::Show
FunctionEnd

Function un.DataOptionsLeave
  ${NSD_GetState} $RemoveDataCheckbox $RemoveData
FunctionEnd

Section "Focalet"
  SetShellVarContext current
  Call RequireClosed
  !include "${INSTALL_FILES}"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Focalet"
  CreateShortcut "$SMPROGRAMS\Focalet\Focalet.lnk" "$INSTDIR\Focalet.exe" "" "$INSTDIR\${APP_ICON_RELATIVE}"
  ; Refresh shortcuts created by earlier installers without adding new ones.
  ${If} ${FileExists} "$SMPROGRAMS\Focalet.lnk"
    CreateShortcut "$SMPROGRAMS\Focalet.lnk" "$INSTDIR\Focalet.exe" "" "$INSTDIR\${APP_ICON_RELATIVE}"
    WriteRegDWORD HKCU "Software\Focalet" "LegacyStartShortcut" 1
  ${EndIf}
  ${If} ${FileExists} "$DESKTOP\Focalet.lnk"
    CreateShortcut "$DESKTOP\Focalet.lnk" "$INSTDIR\Focalet.exe" "" "$INSTDIR\${APP_ICON_RELATIVE}"
    WriteRegDWORD HKCU "Software\Focalet" "DesktopShortcut" 1
  ${EndIf}
  WriteRegStr HKCU "Software\Focalet" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet" "DisplayName" "Focalet"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet" "DisplayVersion" "${APP_DISPLAY_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet" "Publisher" "Focalet"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet" "DisplayIcon" "$INSTDIR\${APP_ICON_RELATIVE}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet" "NoRepair" 1
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  ${If} $RemoveData == 1
    DetailPrint "Stopping Focalet background connections before reset..."
    ClearErrors
    StrCpy $0 4
    nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\support\stop-focalet-relays.ps1" -DataDirectory "$LOCALAPPDATA\Focalet"'
    Pop $0
    Pop $1
    ${If} ${Errors}
      StrCpy $0 4
    ${EndIf}
    ${If} $0 != 0
      DetailPrint "$1"
      IfSilent +2
      MessageBox MB_OK|MB_ICONSTOP "Could not stop a Focalet background connection. Close Focalet and retry uninstall. Your data was kept.$\r$\n$\r$\n$1"
      SetErrorLevel 4
      Abort
    ${EndIf}
    ClearErrors
    ${If} ${FileExists} "$APPDATA\Focalet\*.*"
      RMDir /r "$APPDATA\Focalet"
    ${EndIf}
    ${If} ${FileExists} "$LOCALAPPDATA\Focalet\*.*"
      RMDir /r "$LOCALAPPDATA\Focalet"
    ${EndIf}
    ${If} ${FileExists} "$TEMP\focalet-tray-*.ico"
      Delete "$TEMP\focalet-tray-*.ico"
    ${EndIf}
    ${If} ${Errors}
      IfSilent +2
      MessageBox MB_OK|MB_ICONSTOP "Some Focalet data is still in use. Close Focalet and retry uninstall. The reset is not complete."
      SetErrorLevel 3
      Abort
    ${EndIf}
  ${EndIf}
  !include "${UNINSTALL_FILES}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\Focalet\Focalet.lnk"
  RMDir "$SMPROGRAMS\Focalet"
  ReadRegDWORD $0 HKCU "Software\Focalet" "LegacyStartShortcut"
  ${If} $0 == 1
    Delete "$SMPROGRAMS\Focalet.lnk"
  ${EndIf}
  ReadRegDWORD $0 HKCU "Software\Focalet" "DesktopShortcut"
  ${If} $0 == 1
    Delete "$DESKTOP\Focalet.lnk"
  ${EndIf}
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet"
  DeleteRegKey HKCU "Software\Focalet"
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
  ; Agent-owned data outside Focalet's two profile directories is never removed.
SectionEnd
