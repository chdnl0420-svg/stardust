# 스펙 — nbody-simulator

설계: [design.md](design.md) · 시안: [design-mockup.html](design-mockup.html) · 요구사항: [requirements.md](requirements.md)

UI 갈래: **데스크톱 앱** (Win32 + OpenGL + Dear ImGui). 유니티 NGUI 아님, 웹 아님.
→ QA 는 `/CAP:app-qa` 갈래.

**형태는 첫 증분부터 시안대로 놓는다.** 설정 보드 9섹션과 하단 도구 툴바는 기능이 뒤 바퀴여도
자리를 먼저 놓고 아직 안 되는 항목만 비활성으로 둔다.

`[x]` 근거의 상세 파일·라인은 [round-01-spec-compare.md](round-01-spec-compare.md) 에 있다.

---

## 이번 범위

### 기반 — 앱이 뜨고 돌아간다
- [x] 앱을 실행하면 창이 뜨고 파티클이 중력으로 뭉치는 것을 본다 — 확인: `src/main.cpp` `WinMain` + `src/ui/Hud.cpp` `DrawHud`. **화면 스크린샷은 8번 칸 QA 에서**
- [x] 설정 보드를 접기/펼치기하고 9섹션이 시안대로 놓인 것을 본다 — 확인: `src/ui/Board.cpp` `DrawBoard` 의 `CollapsingHeader` 9개
- [x] 일시정지·한 스텝·리셋을 눌러 시뮬레이션을 제어한다 — 확인: `src/ui/Board.cpp` + `src/app/App.cpp` `App::tick`
- [x] 시간 배속을 조절해 시뮬레이션이 빨라지고 느려지는 것을 본다 — 확인: `src/sim/Sim.cu` `Sim::step` 의 `dt = 0.0016f * cfg.timeScale`
- [x] 창 크기를 조절해도 화면이 정상으로 유지된다 — 확인: `src/main.cpp` `case WM_SIZE` + `src/gfx/RenderField.cu` `ensureSize` (격자와 독립)
- [x] 성능 섹션에서 단계별 소요 ms 와 예산 대비 막대를 본다 — 확인: `src/ui/Board.cpp` 「성능」 `ProgressBar`

### 규모와 격자
- [x] 파티클 수를 바꾸면 즉시 반영된다 — 확인: `Sim::reconfigure` + 회귀테스트 `testReconfigure` (오차 0.0e+00)
- [x] 격자 해상도를 1024²/2048²/4096² 로 바꾸면 즉시 반영된다 — 확인: `src/ui/Board.cpp` `Combo("격자 해상도")` → 재할당
- [x] **파티클 1000만 개에서 60 FPS 로 돈다** — 확인: `mcp/bench-10m.js` 실측 — 1024² **136.8 FPS / 7.40 ms**, 2048² **131.3 FPS / 7.66 ms**, 4096² **62.1 FPS / 16.59 ms**. 전 격자 예산 통과. 스크린샷 `build/bench-10m.png` (1000만·4096²·원반이 화면에 보임)
- [x] **정렬 주기를 조절해 성능과 정확도를 맞바꾼다** — 확인: `Sim::step` 의 `steps % cfg.sortInterval`
- [x] VRAM 이 모자라면 최대 가능 수로 잘리고 보드에 안내가 뜬다 — 확인: `Sim::maxParticlesFor` + `clampToVram`. 회귀테스트 [9] **5억 요청 → 8,573만으로 클램프**(가용 7081MB), 잘린 상태로도 정상 동작. 안내는 `src/ui/Board.cpp` 의 `"VRAM 이 모자라 %d 개로 줄였습니다"` + 「최대치로 맞추기」 버튼

### 중력
- [x] 중력 세기를 조절해 뭉치는 정도가 달라지는 것을 본다 — 확인: 회귀테스트 `testGravityResponds` 실측 52.4 → 42653.9 (814배)
- [x] 중력 공식을 1/r² ↔ 1/r 로 바꿔 그림이 달라지는 것을 본다 — 확인: `kPoissonPeriodic` 의 `denom` 분기, `kGreen` 의 `-1/r` ↔ `log(r)`
- [x] 경계 조건을 고립 ↔ 주기로 바꾼다 — 확인: `Impl::solveGravity` 의 두 경로
- [x] 소프트닝을 조절해 근거리 거동이 달라지는 것을 본다 — 확인: `Impl::buildGreen` 의 `eps = softeningCells * cell`
- [x] 격자 중력이 직접 O(N²) 대비 허용 오차 안에 있다 — 확인: `testForceAccuracy` **실측 0.0729(256²) / 0.1200(512²)**, 판정선 0.15

### 가스
- [x] 압력을 켜고 꺼서 뭉침 정도가 달라지는 것을 본다 — 확인: `Sim::step` 의 `kPressure` + `kGridAccel(usePressure)`
- [ ] **두 가스 덩어리를 충돌시켜 충격파 전선(밀도 불연속)이 서는 것을 본다** — 확인: 충돌면 확대 스크린샷
- [ ] 온도 추적을 켜서 충돌면이 달아오르는 것을 색으로 본다 — 확인: 색 기준=온도 스크린샷
- [ ] 복사 냉각을 켜서 가스가 식으며 더 뭉치는 것을 본다 — 확인: 냉각 on/off 스크린샷 + 최대밀도 비교
- [ ] 별 형성을 켜서 조밀·차가운 가스가 별로 바뀌는 것을 본다 — 확인: 별 개수 표시 + 스크린샷
- [x] 단열지수 γ 를 조절해 압력 반응이 달라지는 것을 본다 — 확인: `kPressure` 의 `powf(rho, gamma)`

### 우주
- [ ] 우주 팽창을 켜서 구조 형성이 팽창과 경쟁하는 것을 본다 — 확인: 팽창 on/off 같은 스텝 수 스크린샷 비교
- [x] 고립 경계를 고르면 팽창 토글이 자동으로 잠긴다 — 확인: `src/ui/Board.cpp` 「우주」 `BeginDisabled(!periodic)`

### 표시
- [ ] 밀도 필드와 파티클 점을 전환해 본다 — 확인: 두 모드 스크린샷
- [ ] 색 기준을 밀도/온도/속도로 바꾼다 — 확인: 세 기준 스크린샷
- [x] 컬러맵을 천체/흑백/열화상으로 바꾼다 — 확인: `src/gfx/RenderField.cu` `kShade` 의 `cmapKind` 분기
- [x] 밝기와 대비를 조절해 어두운 구조를 드러낸다 — 확인: `kShade` 의 `__logf(1+d*bright)` · `__powf(., invGamma)`
- [x] HUD 를 끄고 켠다 — 확인: `src/ui/Hud.cpp` `if (!app.view.showHud) return;`

### 마우스 개입
- [x] 카메라를 줌·팬해 원하는 곳을 확대해 본다 — 확인: `src/main.cpp` `WM_MOUSEWHEEL` · `WM_MOUSEMOVE` → `kShade` 의 zoom/pan
- [x] 빈 판에서 마우스로 형태(회전 원반)를 추가해 초기조건을 직접 만든다 — 확인: `Sim::addShape` + `App::applyToolAt`. `build/shots/01-empty.png`(activeCount=0) → `02-add-disk.png`. 회귀테스트 [10]
- [x] 형태 종류를 회전원반·정지덩어리·가스고리 중에서 골라 추가한다 — 확인: `kFillShape` 의 `kind` 분기(고리는 바깥 테두리만). `build/shots/05-running.png` 에 세 형태가 동시에 보인다. 회귀테스트 [10] 원반 점유셀 12145 vs 고리 5250
- [x] 형태를 여러 번 추가해도 요청한 개수만큼 정확히 나온다 — 확인: 살아있는 파티클을 항상 `[0, activeCount)` 에 모으는 불변식(`Sim::eraseAt` 의 compaction). 회귀테스트 [10] **120000×3 이 각각 정확히 들어감**, MCP 시나리오 600000×3 → activeCount 1800000
- [x] 돌아가는 중에 가스를 뿌려 흐름을 흔든다 — 확인: `Sim::sprayAt` + `kBrushPush`. `build/shots/06-spray.png`, 최대속력 4.21 → 4.41
- [x] 중력 우물을 놓아 물질을 끌어모은다 — 확인: `Sim::wellAt`. `build/shots/07-well.png`, 질량중심이 우물 쪽으로 0.3777 → 0.3735 이동
- [x] 지우개로 파티클을 지운다 — 확인: `Sim::eraseAt` (CUB DeviceSelect 로 살아남은 것을 앞으로 모은다). `build/shots/08-erase.png`, 525,522개 지움(1800000 → 1274478). 지운 뒤 재추가도 정확 — `09-readd.png`

### 프리셋
- [x] 나선팔 프리셋에서 회전 원반이 구조를 만드는 것을 본다 — 확인: `kPlace case 0` + `kSetOrbit`, 테스트 점유셀 8488
- [x] 조석 꼬리 프리셋에서 두 원반이 스치며 꼬리가 뻗는 것을 본다 — 확인: `kPlace case 1` + 가까운 중심 선택, 테스트 점유셀 3226
- [x] 충격파 프리셋에서 정면충돌로 전선이 서는 것을 본다 — 확인: `kPlace case 2`, 테스트 점유셀 2870
- [x] 구조 형성 프리셋에서 우주 거미줄이 자라는 것을 본다 — 확인: `kPlace case 3` + 주기 경계 전환, 테스트 점유셀 65337
- [x] 프리셋을 고르면 경계·압력·팽창이 함께 바뀐다 — 확인: `src/app/App.cpp` `ApplyPresetDefaults` (설정 보드와 MCP 가 같은 함수를 쓴다). MCP 테스트 [3-b] — 나선팔 pressure=0 / 충격파 pressure=1, 구조형성 boundary=periodic·expansion=0

### 녹화
- [ ] 스냅샷 버튼으로 현재 화면을 PNG 로 저장한다 — 확인: 저장된 파일
- [ ] 녹화를 시작·정지해 PNG 시퀀스를 얻는다 — 확인: 연속 프레임 파일 목록 + 녹화 중 배지 스크린샷

### 안정성
- [x] 강한 중력에서도 파티클이 튕겨 나가지 않는다 (CFL 클램프) — 확인: `Sim::step` 의 CFL 절 + `Impl::measureMaxSpeed`. 회귀테스트 [7] 중력 2.0(최대)에서 400스텝 — **질량변화 0.00e+00, 질량중심 이동 0.0014**. MCP 테스트 [3-c] dtUsed=6.2e-5, 최대속력 5.49
- [x] 장시간(1만 스텝) 돌려도 총 질량이 보존된다 — 확인: 회귀테스트 [8] — 시작 200000 → 1만 스텝 후 200000, **상대변화 0.00e+00**

### QA 자동화 (round-01 도중 편입)
- [x] MCP 로 앱을 띄우고 종료한다 — 확인: `mcp/test-client.js` [1]·[7] PASS. `nbody_launch` → `particleCount=500000 grid=1024`, `nbody_quit` → `ok=1`
- [x] MCP 로 설정 값(파티클 수·격자·중력·프리셋 등)을 바꾸고 반영을 확인한다 — 확인: [2]·[3] PASS. gravity 0.6→1.4, sortInterval 40→12, N/G 재할당 후 총질량 2000000, 프리셋 web→주기경계(점유셀 1,680,785)
- [x] MCP 로 현재 상태(FPS·프레임 ms·파티클 수·격자·최대밀도·점유셀)를 읽는다 — 확인: `src/app/ControlBridge.cpp` `statusBody` 가 26개 필드 반환. [5] 에서 중력 0 → 최대밀도 10.93, 0.8 → 110437.66 으로 물리 반응까지 확인
- [x] MCP 로 화면을 PNG 로 캡처한다 — 확인: [6] PASS. `build/mcp-shot.png` 1600×900. 앱이 RGBA raw 로 저장하고 `mcp/server.js` `rawToPng` 가 zlib 으로 PNG 인코딩(외부 라이브러리 0)

---

## 미룬 것

- 초신성 피드백 — 미룬 이유: 별 형성까지가 이번 범위. 피드백은 물리 모델이 한 겹 더 깊고 튜닝 항목이 크게 는다
- 동영상 인코딩 내장 — 미룬 이유: 외부 의존성을 늘리지 않기로 했다. PNG 시퀀스로 뽑고 합치기는 외부 도구
- 냉각 테이블(실제 원소별 냉각률) — 미룬 이유: 단순 멱함수로 시작. 외부 데이터 파일 의존이 생긴다
- 설정 저장·불러오기(프리셋 파일) — 미룬 이유: 기본 프리셋 5종으로 충분. 사용해 보고 필요하면 추가
- Unity 컴퓨트 셰이더 스택 측정 — 미룬 이유: CUDA 로 확정돼 비교 실익이 없다. 이식이 필요해지면 그때
- B3(PM+SPH)에 대한 「결과의 그림」 측정 — 미룬 이유: 승자가 정해져 순위 재확인의 실익이 낮다. 단 이 미측정이 순위를 갈랐다는 사실은 scorecard.md 에 기록돼 있다
- 후보 6종 실측(TreePM·FMM·WCSPH·PBF·X2·X4) — 미룬 이유: 같은 계열이 이미 큰 격차로 탈락했다. 판단 근거는 추정이며 scorecard.md 「줄인 것」에 명시
- CUDA↔OpenGL interop 으로 렌더 전송 최적화 — 미룬 이유: 증분 1 은 호스트 경유로 화면 크기(약 5.8 MB)만 옮긴다. 예산의 6% 수준이라 급하지 않고, 교체는 `RenderField` 안에서 끝난다

---

## 버린 것

- **3D** — 버린 이유: 사용자가 2D 를 선택. 3D 면 옥트리·27셀 순회로 비용이 몇 배가 되고 격자 해상도를 못 올린다
- **파티클 두 종류(암흑물질/별 + 가스 분리)** — 버린 이유: 사용자가 "전부 가스로" 선택
- **강체 충돌 판정** — 버린 이유: 사용자가 명시적으로 배제("실제 부딪히는건아니고"). 격자 압력 방식은 애초에 충돌 판정이 없다
- **Barnes-Hut 쿼드트리** — 버린 이유: 실측 탈락. 문헌 500만 바디 1509 ms 로 목표 대비 45배 이상. GPU 에서 트리는 워프 발산·포인터 추적으로 불리
- **멀티그리드 포아송** — 버린 이유: FFT 실측 2.36 ms 가 멀티그리드 문헌값 93 ms 를 40배 앞서 존재 이유가 사라짐
- **B3 (PM + SPH)** — 버린 이유: X1 의 약 10배 비용(23.1 vs 2.3 ms). 3000만에서 예산 초과
- **1/k² 커널(진짜 2D 중력)을 기본값으로 쓰는 것** — 버린 이유: 힘이 1/r 이라 판 전체가 한 덩어리로 붕괴한다. 전환 옵션으로만 남긴다
- **GLFW/vcpkg 스택** — 버린 이유: Windows 전용이라 크로스플랫폼 이점이 없고 설치·빌드 부담만 는다
- **Direct3D 11 스택** — 버린 이유: 초기화 코드가 OpenGL 의 3배라 시뮬레이션에 쓸 시간을 잡아먹는다
- **WebGPU 를 최종 스택으로 쓰는 것** — 버린 이유: f32 atomic 부재로 산란이 CUDA 의 3배 느리다. 단 시안 검증용으로는 계속 쓴다
- **OpenGL 3.3 코어 컨텍스트** — 버린 이유: `wglCreateContextAttribsARB` 배선이 첫 증분 동작 확인을 지연시킨다. GL 1.1 + ImGui OpenGL2 백엔드로 충분하다
