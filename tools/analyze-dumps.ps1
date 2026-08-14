# 커널 덤프 분석 — **관리자 권한 PowerShell 에서 실행한다.**
#
# C:\WINDOWS\Minidump 는 관리자만 읽을 수 있어서, 일반 권한으로는 kd 가 Win32 error 5 로 막힌다.
# 시스템이 재부팅된 뒤 「무엇이 먼저 무너졌는가」를 가리는 데 쓴다.
#
#   nvlddmkm 이 스택에 보이면    → 그래픽 드라이버가 먼저 타임아웃된 것(우리 커널이 너무 오래 돌았다)
#   Stardust.exe 가 보이면        → 앱이 직접 잘못된 메모리를 건드린 것
#
# 결과는 이 스크립트 옆의 dumps\ 폴더에 남는다.

$ErrorActionPreference = "Stop"

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "관리자 권한이 필요합니다. PowerShell 을 '관리자 권한으로 실행'한 뒤 다시 돌리십시오." -ForegroundColor Red
    exit 1
}

# WinDbg(winget: Microsoft.WinDbg)가 깔려 있어야 한다. 버전이 올라가면 폴더 이름이 바뀌므로 찾아서 쓴다.
$kd = Get-ChildItem "C:\Program Files\WindowsApps\Microsoft.WinDbg_*_x64__8wekyb3d8bbwe\amd64\kd.exe" `
      -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $kd) {
    Write-Host "kd.exe 를 찾지 못했습니다. 먼저 설치하십시오:" -ForegroundColor Red
    Write-Host "  winget install --id Microsoft.WinDbg" -ForegroundColor Yellow
    exit 1
}

$out = Join-Path $PSScriptRoot "dumps"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$sym = "srv*C:\symbols*https://msdl.microsoft.com/download/symbols"

$dumps = @(Get-ChildItem C:\WINDOWS\Minidump\*.dmp -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending)
if ($dumps.Count -eq 0) { Write-Host "미니덤프가 없습니다."; exit 0 }

Write-Host "덤프 $($dumps.Count) 개를 분석합니다. 심볼을 처음 받을 때는 몇 분 걸립니다." -ForegroundColor Cyan

foreach ($d in $dumps) {
    $log = Join-Path $out "$($d.BaseName).txt"
    Write-Host "  $($d.Name)  ($($d.LastWriteTime))"
    & $kd.FullName -z $d.FullName -y $sym -logo $log -c '!analyze -v; q' 2>&1 | Out-Null

    if (Test-Path $log) {
        $txt = Get-Content $log -Raw
        # 원인을 한 줄로 말해 주는 자리만 뽑아 화면에 띄운다. 전체는 파일에 있다.
        foreach ($pat in @('BUGCHECK_CODE', 'MODULE_NAME', 'IMAGE_NAME', 'PROCESS_NAME',
                           'FAILURE_BUCKET_ID', 'BLAME_MODULE')) {
            $m = [regex]::Matches($txt, "^$pat.*$", 'Multiline')
            foreach ($x in $m) { Write-Host "      $($x.Value.Trim())" -ForegroundColor Green }
        }
    }
}

Write-Host ""
Write-Host "전체 결과: $out" -ForegroundColor Cyan
