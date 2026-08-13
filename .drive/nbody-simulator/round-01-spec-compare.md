# round-01 스펙 대조 (6번 칸)

대상: `.drive/nbody-simulator/spec.md` "이번 범위" **45항목**
코드: 커밋 `473c6ee`(코어+테스트) · `9671ef5`(UI). 브랜치 `feature/nbody-simulator`

**VERDICT: FAIL** — met 25 / 미충족 20

증분 1 범위(앱이 뜨고 파티클이 중력으로 뭉치는 것을 본다)만 구현했으므로 예상된 결과다.

---

## met (25)

### 기반 (6/6)

| 항목 | 근거 |
|---|---|
| 앱을 실행하면 창이 뜨고 파티클이 중력으로 뭉친다 | `src/main.cpp` `WinMain` — `CreateWindowExW(... L"nbody-simulator" ...)` + `app.tick()` → `Sim::step()`. HUD 는 `src/ui/Hud.cpp` `DrawHud` 가 FPS·파티클 수 출력. **화면 확인은 8번 칸 QA** |
| 설정 보드 접기/펼치기 + 9섹션 | `src/ui/Board.cpp` `DrawBoard` — `CollapsingHeader` 9개(시뮬레이션·중력·가스·우주·표시·마우스 도구·프리셋·녹화·성능). 접기 버튼 `if (ImGui::Button("◂ 접기")) boardOpen = false;`, 다시 열기는 `src/main.cpp` `"설정 보드 열기 ▸"` |
| 일시정지·한 스텝·리셋 | `src/ui/Board.cpp` `app.running = !app.running` / `app.stepOnce = true` / `app.sim.reset()`. 소비는 `src/app/App.cpp` `App::tick` |
| 시간 배속 | `src/ui/Board.cpp` `SliderFloat("시간 배속", &app.cfg.timeScale, 0.1f, 4.0f)`, 반영은 `src/sim/Sim.cu` `Sim::step` 의 `const float dt = 0.0016f * d->cfg.timeScale;` |
| 창 크기 조절 | `src/main.cpp` `WndProc` `case WM_SIZE`, 렌더 타깃 재할당은 `src/gfx/RenderField.cu` `RenderField::ensureSize`. 격자와 독립임은 `draw(...)` 가 `viewW/viewH` 로만 텍스처를 잡는 것으로 보장 |
| 성능 섹션 | `src/ui/Board.cpp` 「성능」 — `ProgressBar(frac...)` 예산 막대(70%/100% 경계에서 색 전환), 단계별 `t.scatterMs`·`t.poissonMs`·`t.gatherMs`·`t.gasMs` 출력 |

### 규모와 격자 (3/5)

| 항목 | 근거 |
|---|---|
| 파티클 수 변경 즉시 반영 | `src/ui/Board.cpp` `SliderInt("파티클 수"...)` → `needApply = true` → `src/app/App.cpp` `App::applyConfig` → `Sim::reconfigure`. 재할당 판정은 `src/sim/Sim.cu` `Sim::reconfigure` 의 `needRealloc`. 회귀 테스트 `tests/sim_tests.cpp` `testReconfigure` 가 100만/10만/200만 × 1024²/2048²/4096² 에서 질량 일치 확인(오차 0.0e+00) |
| 격자 해상도 1024²/2048²/4096² | `src/ui/Board.cpp` `Combo("격자 해상도"...)` → `cfg.gridSize` |
| 정렬 주기 조절 | `src/ui/Board.cpp` `SliderInt("정렬 주기", &app.cfg.sortInterval, 1, 120)`, 소비는 `src/sim/Sim.cu` `Sim::step` 의 `if (d->cfg.sortInterval > 0 && (d->steps % d->cfg.sortInterval) == 0)` |

### 중력 (5/5)

| 항목 | 근거 |
|---|---|
| 중력 세기 | `src/ui/Board.cpp` `SliderFloat("중력 세기"...)`, 반영은 `src/sim/Sim.cu` `Sim::step` 의 `potScale`. 회귀 테스트 `testGravityResponds` 가 중력 0 → 최대밀도 52.4, 0.6 → 42653.9 (**814배**) 로 확인 |
| 힘 공식 1/r² ↔ 1/r | `src/ui/Board.cpp` `Combo("힘 공식"...)`. 주기 경계는 `kPoissonPeriodic` 의 `denom = (law == 0) ? sqrtf(k2) : k2`, 고립 경계는 `kGreen` 의 `(law == 0) ? (-1.0f / rr) : logf(rr)` |
| 경계 고립 ↔ 주기 | `src/ui/Board.cpp` `Combo("경계 조건"...)` → 재할당. 분기는 `src/sim/Sim.cu` `Impl::solveGravity` |
| 소프트닝 조절 | `src/ui/Board.cpp` `SliderFloat("소프트닝"...)`, 소비는 `Impl::buildGreen` 의 `eps = cfg.softeningCells * cell` (같은 값이면 그린함수를 다시 만들지 않음) |
| 힘 오차 판정선 0.15 이하 | `tests/sim_tests.cpp` `testForceAccuracy` → **실측 G=256 0.0729 / G=512 0.1200**. 구현은 `Sim::measureForceErrorVsDirect` (직접 O(N²) `kDirectForce` 대비 최소자승 배율 보정 후 RMS) |

### 가스 (2/6)

| 항목 | 근거 |
|---|---|
| 압력 on/off | `src/ui/Board.cpp` `Checkbox("압력", &app.cfg.pressureEnabled)`, 소비는 `src/sim/Sim.cu` `Sim::step` 의 `kPressure` 호출과 `kGridAccel(... usePressure ...)` |
| 단열지수 γ | `src/ui/Board.cpp` `SliderFloat("단열지수 γ"...)` → `kPressure` 의 `powf(rho, gamma)` |

### 우주 (1/2)

| 항목 | 근거 |
|---|---|
| 고립 경계면 팽창 토글 자동 잠김 | `src/ui/Board.cpp` 「우주」 — `ImGui::BeginDisabled(!periodic)` + 잠김 시 `cfg.expansionEnabled = false` 강제 |

### 표시 (3/5)

| 항목 | 근거 |
|---|---|
| 컬러맵 천체/흑백/열화상 | `src/ui/Board.cpp` `Combo("컬러맵"...)` → `src/gfx/RenderField.cu` `kShade` 의 `cmapKind` 분기 (`cmapAstro` / 흑백 / `cmapThermal`) |
| 밝기·대비 | `src/ui/Board.cpp` 두 슬라이더 → `kShade` 의 `__logf(1.f + d * bright)` 와 `__powf(..., invGamma)` |
| HUD 끄고 켜기 | `src/ui/Board.cpp` `Checkbox("HUD 표시"...)` → `src/ui/Hud.cpp` `if (!app.view.showHud) return;` |

### 마우스 개입 (1/7)

| 항목 | 근거 |
|---|---|
| 카메라 줌·팬 | `src/main.cpp` `WM_MOUSEWHEEL`(zoom 0.25~64 클램프) · `WM_LBUTTONDOWN`/`WM_MOUSEMOVE`(pan, 짧은 변 기준 정규화). 적용은 `kShade` 의 `u = (u - 0.5f) / zoom + 0.5f - panX` |

### 프리셋 (4/5)

| 항목 | 근거 |
|---|---|
| 나선팔 | `src/sim/Sim.cu` `kPlace` `case 0` + `reset()` 의 `kSetOrbit`(fudge 0.97). 테스트 `testPresets` 점유셀 8488 |
| 조석 꼬리 | `kPlace` `case 1`(두 원반) + `kSetOrbit` 의 가까운 중심 선택(fudge 0.90). 테스트 점유셀 3226 |
| 충격파 | `kPlace` `case 2`(정면 접근속도 0.055). 테스트 점유셀 2870 |
| 구조 형성 | `kPlace` `case 3`(균일+요동) + 프리셋 선택 시 주기 경계 전환. 테스트 점유셀 65337 (= 256² 격자를 거의 다 채움) |

---

## 미충족 (20)

| # | 항목 | 상태 |
|---|---|---|
| 1 | **파티클 1000만에서 60 FPS** | 미측정. 앱은 뜨지만 성능 실측을 하지 않았다 |
| 2 | VRAM 부족 시 최대 가능 수로 클램프 + 안내 | 미구현. `Sim::deviceFreeBytes()` 는 있으나 할당 전 검사·클램프 경로가 없다 |
| 3 | **충격파 전선이 서는 것을 본다** | 미충족. 압력계수를 중력 스케일에 맞춰 보정하는 작업(design.md §9-3)이 남아 있다 |
| 4 | 온도 추적을 색으로 본다 | 코어에 온도 적분은 있으나(`kIntegrate` 의 `trackTemp`) 「색 기준」 UI 가 비활성이고 `kShade` 가 밀도만 읽는다 |
| 5 | 복사 냉각 | UI 비활성. 코어에 `coolingEnabled` 분기는 있으나 검증 안 됨 |
| 6 | 별 형성 | 미구현 (UI 비활성) |
| 7 | 우주 팽창 | 미구현 — 코어에 스케일 팩터 적분이 없다 |
| 8 | 밀도 필드 ↔ 파티클 점 전환 | 점 렌더 미구현. UI 비활성 |
| 9 | 색 기준 밀도/온도/속도 | 미구현 (UI 비활성) |
| 10 | 빈 판에서 마우스로 형태 추가 | 미구현 |
| 11 | 형태 3종(회전원반·정지덩어리·가스고리) | 미구현 |
| 12 | 여러 번 추가해도 개수가 정확 | 미구현 (자유 슬롯 커서 필요 — design.md §9-1) |
| 13 | 가스 뿌리기 | 미구현 |
| 14 | 중력 우물 | 미구현 |
| 15 | 지우개 | 미구현 |
| 16 | **프리셋이 경계·압력·팽창을 함께 바꾼다** | **부분 미충족** — `src/ui/Board.cpp` 프리셋 버튼이 **경계만** 바꾼다. 압력·팽창은 그대로 남는다 |
| 17 | 스냅샷 PNG 저장 | 미구현 (UI 비활성) |
| 18 | 녹화 시작·정지 | 미구현 (UI 비활성) |
| 19 | **CFL 클램프** | 미구현. `Sim::step` 의 dt 가 `0.0016f * timeScale` 고정이다. 구현 중 실측으로 필요성이 확인됐다(중력 1.5에서 오히려 덜 뭉침 — implement-note.md 3번) |
| 20 | 장시간(1만 스텝) 질량 보존 | 미검증. 회귀 테스트는 50스텝까지만 본다 |

---

## 스펙 밖 징후

**앱 제어용 MCP 서버** — 사용자가 이번 라운드 도중 요청("mcp도 만들어서 테스트할때 사용해").
`spec.md` 의 세 구획 어디에도 없다. GUI 앱은 현재 스크린샷 외에 자동 검증 수단이 없어
8번 칸 QA 의 정확도가 여기 묶인다. **편입 여부는 drive 가 정한다.**

그 밖에 스펙에 없는 미구현 징후는 발견되지 않았다.

---

SPEC-COMPARE: FAIL
