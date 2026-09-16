Unicode true
!include "MUI2.nsh"
!include "x64.nsh"

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
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "Zommi requires 64-bit Windows."
    Abort
  ${EndIf}
FunctionEnd

Section "Zommi"
  SetShellVarContext current
  !include "${INSTALL_FILES}"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Zommi"
  CreateShortcut "$SMPROGRAMS\Zommi\Zommi.lnk" "$INSTDIR\Zommi.exe"
  WriteRegStr HKCU "Software\Zommi" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "DisplayName" "Zommi"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "Publisher" "Zommi"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "DisplayIcon" "$INSTDIR\Zommi.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  !include "${UNINSTALL_FILES}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\Zommi\Zommi.lnk"
  RMDir "$SMPROGRAMS\Zommi"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Zommi"
  DeleteRegKey HKCU "Software\Zommi"
  ; Keep runtime accounts, settings, and chat history in the user's profile.
SectionEnd
