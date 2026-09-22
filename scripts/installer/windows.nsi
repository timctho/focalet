Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "nsDialogs.nsh"
!include "FileFunc.nsh"

Var RemoveData
Var RemoveDataCheckbox

Name "Zommi"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\Zommi"
InstallDirRegKey HKCU "Software\Zommi" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey "ProductName" "Zommi"
VIAddVersionKey "FileDescription" "Zommi Setup"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "LegalCopyright" "Zommi contributors"
!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\Zommi.exe"
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
    MessageBox MB_OK|MB_ICONSTOP "Zommi requires 64-bit Windows."
    Abort
  ${EndIf}
FunctionEnd

!macro RequireClosed Prefix
Function ${Prefix}RequireClosed
retry:
  System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "Local\Zommi.Desktop.SingleInstance") p.r0'
  StrCmp $0 0 done
  System::Call 'kernel32::CloseHandle(p r0)'
  IfSilent fail
  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "Close Zommi (including its tray icon) before continuing. This prevents an incomplete update or reset." IDRETRY retry
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
  ${NSD_CreateLabel} 0 0 100% 36u "Choose whether to keep Zommi ready for a future reinstall or start fresh. Agent accounts and agent-owned conversations are kept in either case."
  Pop $0
  ${NSD_CreateCheckbox} 0 48u 100% 32u "Remove all Zommi settings, cached agent detection and local session metadata"
  Pop $RemoveDataCheckbox
  ${NSD_SetState} $RemoveDataCheckbox $RemoveData
  nsDialogs::Show
FunctionEnd

Function un.DataOptionsLeave
  ${NSD_GetState} $RemoveDataCheckbox $RemoveData
FunctionEnd

Section "Zommi"
  SetShellVarContext current
  !include "${INSTALL_FILES}"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Zommi"
  CreateShortcut "$SMPROGRAMS\Zommi\Zommi.lnk" "$INSTDIR\Zommi.exe" "" "$INSTDIR\${APP_ICON_RELATIVE}"
  WriteRegStr HKCU "Software\Zommi" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "DisplayName" "Zommi"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "DisplayVersion" "${APP_DISPLAY_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "Publisher" "Zommi"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "DisplayIcon" "$INSTDIR\${APP_ICON_RELATIVE}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "NoRepair" 1
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  ${If} $RemoveData == 1
    ClearErrors
    ${If} ${FileExists} "$APPDATA\Zommi\*.*"
      RMDir /r "$APPDATA\Zommi"
    ${EndIf}
    ${If} ${FileExists} "$LOCALAPPDATA\Zommi\*.*"
      RMDir /r "$LOCALAPPDATA\Zommi"
    ${EndIf}
    ${If} ${FileExists} "$TEMP\zommi-tray-*.ico"
      Delete "$TEMP\zommi-tray-*.ico"
    ${EndIf}
    ${If} ${Errors}
      IfSilent +2
      MessageBox MB_OK|MB_ICONSTOP "Some Zommi data is still in use. Close Zommi and retry uninstall. The reset is not complete."
      SetErrorLevel 3
      Abort
    ${EndIf}
  ${EndIf}
  !include "${UNINSTALL_FILES}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\Zommi\Zommi.lnk"
  RMDir "$SMPROGRAMS\Zommi"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi"
  DeleteRegKey HKCU "Software\Zommi"
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
  ; Agent-owned data outside Zommi's two profile directories is never removed.
SectionEnd
