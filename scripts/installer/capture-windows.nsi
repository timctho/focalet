Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
Name "Focalet Capture"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\Focalet Capture"
InstallDirRegKey HKCU "Software\Focalet Capture" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey "ProductName" "Focalet Capture"
VIAddVersionKey "FileDescription" "Focalet Capture Setup"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "LegalCopyright" "Focalet contributors"
!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\Focalet.Capture.exe"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
!macro RequireClosed Prefix
Function ${Prefix}RequireClosed
retry:
  System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "Local\Focalet.CaptureTool") p.r0'
  StrCmp $0 0 done
  System::Call 'kernel32::CloseHandle(p r0)'
  IfSilent fail
  MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "Quit Focalet Capture from its tray menu before continuing." IDRETRY retry
fail:
  SetErrorLevel 2
  Abort
done:
FunctionEnd
!macroend
!insertmacro RequireClosed ""
!insertmacro RequireClosed "un."
Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "Focalet Capture requires 64-bit Windows."
    Abort
  ${EndIf}
  Call RequireClosed
FunctionEnd
Function un.onInit
  Call un.RequireClosed
FunctionEnd
Section "Focalet Capture"
  SetShellVarContext current
  Call RequireClosed
  !include "${INSTALL_FILES}"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Focalet"
  CreateShortcut "$SMPROGRAMS\Focalet\Focalet Capture.lnk" "$INSTDIR\Focalet.Capture.exe" "" "$INSTDIR\app.ico"
  WriteRegStr HKCU "Software\Focalet Capture" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet Capture" "DisplayName" "Focalet Capture"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet Capture" "DisplayVersion" "${APP_DISPLAY_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet Capture" "Publisher" "Focalet"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet Capture" "DisplayIcon" "$INSTDIR\app.ico"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet Capture" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet Capture" "QuietUninstallString" '$\"$INSTDIR\Uninstall.exe$\" /S'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet Capture" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet Capture" "NoRepair" 1
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
SectionEnd
Section "Uninstall"
  SetShellVarContext current
  Call un.RequireClosed
  !include "${UNINSTALL_FILES}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\Focalet\Focalet Capture.lnk"
  RMDir "$SMPROGRAMS\Focalet"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet Capture"
  DeleteRegKey HKCU "Software\Focalet Capture"
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
SectionEnd
