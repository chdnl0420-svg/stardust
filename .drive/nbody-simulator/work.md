# 작업 기록 — nbody-simulator

DRIVE_STATUS: in_progress
resume_cron: 11f0e0cb (17,47)
resume_idle_count: 0

## VCS · 베이스라인

| 항목 | 값 |
|---|---|
| 모드 | **Git** (P4 아님) |
| 저장소 | `D:\Project\Nbody` — 이 판에서 새로 `git init` 함 |
| 작업 브랜치 | `feature/nbody-simulator` |
| 베이스라인 커밋 | `35bf7cd` "chore: 설계 산출물과 프로토타입 베이스라인" (추적 25파일) |
| 진입 시 작업 트리 | CLEAN |

`git init` 은 이 판에서 스스로 정했다 — 아래 판단 기록 참조.
푸시·PR 은 하지 않는다(`/CAP:submit` 의 몫). 로컬 커밋까지만 한다.

## permissions_preflight (0번 칸)

`~/.claude/settings.json` 의 `permissions.allow` 대조 결과 **4종 전부 이미 존재**해 추가한 규칙 없음:
`Edit` · `Write` · `mcp__nx3-unity-mcp` · `mcp__Claude_Browser`.
거절된 규칙 없음. `defaultMode: bypassPermissions`.

## 칸 실행 위치

| 칸 | 위치 | 사유 |
|---|---|---|
| 4 spec-trace | **메인 실행** | 이 세션은 사용자 요청 없이 서브에이전트를 띄우지 않는 설정. drive 예외 조항("서브를 쓸 수 없는 세션이면 메인에서 돌고 「메인 실행」으로 적는다") 적용 |
| 6 spec-compare | 메인 실행 예정 | 위와 같음 |
| 7 external-review | 메인 실행 예정 | 위와 같음 |
| 8 app-qa | 메인 실행 | 원래 메인이 원칙 |

## 판단 기록

- [5번 칸 진입 · VCS] git 도 P4 도 아닌 폴더였다 → **`git init` + `feature/nbody-simulator` 브랜치 생성**을 스스로 정함 — 근거: 구현 루프가 여러 바퀴 돌며 되돌릴 일이 생기고, CLAUDE.md 9번(가설 검증 시 파일 원상 복구)이 VCS 없이는 `.bak` 물리 복사에 의존해야 한다. `p4` 실행파일은 있으나 이 폴더는 P4 워크스페이스가 아님(`git rev-parse` NOT_A_GIT_REPO, 트리에 P4 흔적 없음)
- [5번 칸 진입 · .gitignore] 빌드 산출물·`proto/out*`·`*.raw`·`extern/` 을 무시 대상으로 정함 — 근거: 프로토타입 출력이 raw 16개 × 4MB 로 크고 재생성 가능. `.drive/` 는 **커밋한다**(이 프로젝트에서는 작업 기록이 산출물)
- [4번 칸] spec-trace 1회차 FAIL(누락 4건) → 출처를 직접 열어 확인하고 전부 "이번 범위"로 되돌림, 2회차 PASS — 근거: `spec-trace.md` 2회차 수선 내역 표
- [4번 칸] 역방향 미추적으로 올라온 힘 오차 기준 0.15 → 폐기하지 않고 **근거를 design.md §8 에 명시**하는 쪽을 택함 — 근거: 512² 실측 0.134(measurements.md 라운드5)에 여유를 얹은 값이며, 기준 자체는 QA 판정선으로 필요하다

## 바퀴 기록

| 바퀴 | 산출물 | 상태 |
|---|---|---|
| — | `spec-trace.md` 1·2회차 | 4번 칸 PASS |
| round-01 | (진행 중) | 5번 칸 구현 착수 |
