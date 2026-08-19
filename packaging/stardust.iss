; Stardust 설치 스크립트 (Inno Setup 6)
;
; 빌드: "%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe" packaging\stardust.iss
; 결과: dist\Stardust-<버전>-setup.exe
;
; 설치 위치를 Program Files 가 아니라 **사용자 폴더**로 잡는다.
; 이 앱은 스스로 새 버전을 받아 실행 파일을 갈아 끼우는데, Program Files 에 깔면 그때마다
; 관리자 권한을 물어야 해서 자동 업데이트가 사실상 못 돈다. 크롬·VS Code 도 같은 이유로
; 사용자 폴더에 깐다.

#define AppName    "Stardust"
; **버전을 담은 자리가 셋이고, 셋이 같아야 한다.**
;   · `src/app/Version.h`      STARDUST_VERSION — 자동 업데이트가 견주는 기준
;   · 여기                     AppVersion       — 설치 프로그램이 말하는 버전
;   · `packaging/stardust.rc`  FILEVERSION      — 탐색기 파일 속성이 보여 주는 버전
; 어긋나면 설치 프로그램이 말하는 버전과 앱이 자기라고 말하는 버전이 달라지고,
; 자동 업데이트가 그 둘 중 어느 것을 기준으로 삼는지 알 수 없게 된다.
; (0.6.1 로 0.6.2 짜리 앱을 담고 있었다 — 2026-08-18 에 맞췄다.)
; **셋째를 빠뜨려 `.rc` 가 0.6.1 에 멈춘 채 0.6.2~0.6.8 이 나갔다** — 2026-08-19 에
; 설치본을 확인하다 발견했다(파일 속성 0.6.1, 레지스트리 0.6.6). `ignoreversion`
; 플래그 덕에 설치는 되고 있어 아무도 안 걸렸다. **버전을 올릴 때 셋을 함께 올린다.**
#define AppVersion "0.6.8"
#define AppExe     "Stardust.exe"
#define AppPublisher "JustKim"

[Setup]
; 이 값은 앱을 식별하는 고유 번호다. **절대 바꾸지 않는다** —
; 바꾸면 윈도우가 다른 앱으로 알아 예전 것이 지워지지 않고 둘이 함께 남는다.
AppId={{8EAE8C06-7491-40A9-A674-5C5E49A3C146}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename={#AppName}-{#AppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
; CUDA 를 쓰므로 64비트 전용이다. 32비트에서 깔리면 실행 순간 죽는다.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
UninstallDisplayIcon={app}\{#AppExe}
; 설치 마법사 아이콘만 작은 크기(48px 이하)로 따로 둔다.
; Inno Setup 은 PNG 로 압축된 256px 항목을 못 읽고 파일 전체를 거부한다.
; 실행 파일에 박는 아이콘(stardust.rc)은 원본을 그대로 쓴다.
SetupIconFile=assets\stardust-setup.ico
; 설치 파일이 250 MB 가까이 된다 — 진행 표시가 있어야 멈춘 것으로 오해하지 않는다.
SetupLogging=yes

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "바탕화면에 바로가기 만들기"; GroupDescription: "추가 작업:"

[Files]
Source: "..\build\Release\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
; cuFFT 는 244 MB 라 설치 때 한 번만 깐다. 자동 업데이트는 실행 파일만 갈아 끼운다.
Source: "..\build\Release\cufft64_*.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\{#AppName} 제거"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "지금 실행"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 자동 업데이트가 남길 수 있는 임시 파일까지 함께 지운다.
Type: files; Name: "{app}\{#AppExe}.new"
Type: files; Name: "{app}\{#AppExe}.update.bat"
