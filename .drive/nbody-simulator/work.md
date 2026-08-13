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
| round-01 | `implement-note.md`, 커밋 `473c6ee`·`9671ef5`, `round-01-spec-compare.md` | 5번 칸 증분 1 완료 → 6번 칸 **FAIL** (met 25 / 미충족 24) → 5번 칸으로 되돌아감 |
| round-02 | (착수) | 증분 2 — MCP 제어 채널 |

## round-01 결과 요약

- 커밋 `473c6ee` 시뮬레이션 코어 + 회귀 테스트 **15 PASS / 0 FAIL**
- 커밋 `9671ef5` Win32 + OpenGL + ImGui 앱, 설정 보드 9섹션, HUD, 하단 툴바
- 앱 실행 확인: 창이 뜨고 5초 후에도 생존(pid 48012)
- 6번 칸 대조: **met 25 / 미충족 24** (MCP 4항목 편입 후 이번 범위 49개)

## 추가 판단 기록 (round-01)

- [round-01 · 5번 칸] UI 갈래에서 `/CAP:frontend-design` 을 **건너뜀** — 근거: 그 칸의 일(팔레트·타이포·레이아웃 결정)을 3번 칸에서 이미 했고 시안이 승인까지 났다(`design-mockup.html`). 다시 부르면 확정된 시안을 재설계하게 된다
- [round-01 · 5번 칸] 테스트 파일을 `.cu` → `.cpp` 로 옮김 — 근거: nvcc 전처리가 UTF-8 한글 문자열 리터럴에서 깨진다(x5.cu 에서도 같은 증상). `Sim.h` 가 Pimpl 이라 CUDA 헤더 없이 컴파일된다
- [round-01 · 5번 칸] `tests/sim_tests.cpp` 를 **영구 회귀 테스트로 남김** — 근거: design.md §8 이 물리 정확도·보존량·토글 반응을 상시 검증 항목으로 정했고 spec.md 에 해당 항목이 있다. implement 2단계 9번의 "영구 회귀 테스트 예외"에 해당
- [round-01 · 6번 칸] 사용자가 도중 요청한 **앱 제어 MCP 를 "이번 범위"에 편입** — 근거: GUI 앱은 현재 스크린샷 외에 자동 검증 수단이 없어 8번 칸 QA 정확도가 여기 묶인다. drive 「새 요구 triage」 규칙상 진행이 막히는 쪽이라 편입하고 사용자에게 되묻지 않았다. 편입 사실은 `report-deferred.md` 에도 적는다
- [round-01 · 6번 칸] 힘 오차 판정선 0.15 를 유지 — 근거: 실측 0.0729(256²)·0.1200(512²)로 판정선 안에 들었다
