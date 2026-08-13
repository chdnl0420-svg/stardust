# round-06 리뷰 (7번 칸)

대상: `code` 모드 — 베이스라인 `35bf7cd` 이후 전체 소스 24파일 197,069 바이트
(`CMakeLists.txt` · `src/**` 17파일 · `tests/sim_tests.cpp` · `mcp/*.js` 5파일)
리뷰어: **codex `gpt-5.6-sol` · `model_reasoning_effort=xhigh`** (1차 교차 리뷰, fallback 없음)
경로 검증: 인용된 11개 파일 전부 `$PATHS` 안 — 폐기 0건

**VERDICT: FAIL** — P1 17 / P2 21

---

## [발견] P1 — 게이트를 막는 것

### 검증 완료 (drive 가 코드로 직접 확인)

| # | 위치 | 요지 |
|---|---|---|
| 1 | `src/ui/Board.cpp:34` `bool needApply` | **설정 보드의 물리 슬라이더 대부분이 코어에 전달되지 않는다.** `needApply` 는 파티클 수(61)·격자(79)·경계(99) 세 곳에서만 켜진다. 중력 세기(88)·소프트닝(101)·압력(106~108)·온도·냉각·별형성·팽창·시간배속(81)·정렬주기(82)는 `app.cfg` 만 바꾸고 `Sim` 은 옛 값으로 계속 계산한다 |
| 2 | `src/app/ControlBridge.cpp:258` `if (needApply) app.applyConfig();` | 같은 결함이 MCP 경로에도 있다. `set` 으로 중력만 바꾸면 코어에 안 가는데 `statusBody` 는 `app.cfg` 의 새 값을 돌려줘 **적용된 것처럼 보인다** |
| 3 | `src/ui/Board.cpp:194` | 보드에서 프리셋 버튼을 누르면 `needApply=true` 를 세운 뒤 **그 자리에서 `app.sim.reset()`** 을 부른다. `applyConfig()` 는 `DrawBoard` 가 반환한 뒤(main.cpp:244)라 **옛 프리셋으로 리셋된다.** MCP 경로(ControlBridge.cpp:270-272)는 순서가 반대라 정상 |

**왜 여태 안 걸렸나** — 회귀테스트 24건은 `Sim` 을 직접 쓰므로 UI·브릿지 경로를 안 탄다. MCP 시나리오는 전부 `set → preset` 순서라 `nbody_preset` 이 부르는 `applyConfig()` 가 뒤늦게 모든 값을 반영해 줬다. round-05 에서 "프리셋 리셋 뒤에 설정" 순서 오류를 고칠 때 **증상만 피하고 원인을 안 봤다.**

### codex 보고 (미검증 — 5번 칸에서 확인하며 고친다)

| # | 위치 | 요지 |
|---|---|---|
| 4 | `src/sim/Sim.cu:909` | 부분 점유 상태에서 정렬하면 `allocN` 전체가 섞여 `[0, activeN)` 불변식이 깨진다 |
| 5 | `src/sim/Sim.cu:913` | 정렬이 `isStar` 를 함께 옮기지 않아 별 표식이 다른 파티클에 붙는다 |
| 6 | `src/sim/Sim.cu:1123` | 지우개 압축이 `isStar` 를 압축하지 않아 지운 별이 계속 집계되고 새 형태가 별 표식을 물려받는다 |
| 7 | `src/sim/Sim.cu:34` | CUDA 오류를 찍고 계속 진행한다 — null 디바이스 포인터로 커널을 띄운다 |
| 8 | `src/sim/Sim.cu:669` | cuFFT 계획 생성 실패를 무시하고 준비됨으로 표시한다 |
| 9 | `src/sim/Sim.cu:911` | CUB radix sort 반환값 미확인 — 실패 시 미정의 인덱스로 배열을 읽는다 |
| 10 | `src/sim/Sim.cu:815` | VRAM 추정에 `fieldNum`·`fieldOut`·선택/별 버퍼·cuFFT/CUB 작업공간이 빠졌다 |
| 11 | `src/sim/Sim.cu:845` | `maxN == 0`(격자만으로 예산 초과)이면 클램프를 건너뛰고 그대로 할당한다 |
| 12 | `src/gfx/RenderField.cu:156` | `devAccum_` 할당 실패를 확인하지 않아 다음 프레임에 null 로 커널을 띄운다 |
| 13 | `src/app/ControlBridge.cpp:223` | 외부 설정의 유한성·범위 미검증 — `softeningCells=0` 이 그린함수 원점에서 NaN 을 만든다 |
| 14 | `mcp/server.js:40` | key=value 값에 줄바꿈을 이스케이프하지 않아 **명령 주입**이 된다(`\ncmd=quit`) |
| 15 | `mcp/server.js:41` | 동시 호출이 공용 `cmd.txt`·`resp.txt` 를 덮어써 응답이 뒤섞인다 |
| 16 | `mcp/server.js:188` | `nbody_step` 이 완료를 확인하지 않고 `count*4ms` 만 기다린 뒤 성공으로 응답한다 |
| 17 | `mcp/server.js:200` | 스크린샷 출력 경로 제한이 없어 임의 파일을 PNG 로 덮어쓴다 |

## [발견] P2 — 게이트를 막지 않는 것

18 `Sim.cu:850` 격자 크기 양수·2의 거듭제곱 미검증 /
19 `Sim.cu:731` 주기 경계에서 소프트닝이 아예 안 쓰인다 /
20 `Sim.cu:963` CFL 이 가속 전 속도만 본다 /
21 `Sim.cu:765` 최대속력이 숨은 슬롯까지 포함한다 /
22 `Sim.cu:998` 별 온도를 0 으로 고정하지 않아 같은 스텝에 다시 가열된다 /
23 `Sim.cu:1044` 최대밀도·점유셀 측정이 `rho` 를 갱신하지 않는다 /
24 `Sim.cu:1257` 일시정지 중 편집이 화면에 즉시 안 보인다 /
25 `Sim.cu:1010` 정렬 시간이 항상 0 으로 보고된다 /
26 `RenderField.cu:100` **점 렌더가 컬러맵 선택을 무시한다** /
27 `Hud.cpp:35` `substeps>1` 이 항상 거짓이라 CFL 경고가 안 뜬다 /
28 `main.cpp:168` ImGui 백엔드 초기화 실패 무시 /
29 `PngWriter.cpp:93` 쓰기 실패를 성공으로 반환 /
30 `main.cpp:273` 저장 실패해도 녹화 카운터가 증가 /
31 `ControlBridge.cpp:177` raw 단축 쓰기를 성공 처리 /
32 `ControlBridge.cpp:104` 응답 파일 교체 실패 무시 /
33 `ControlBridge.cpp:94` 제어 디렉터리 생성 실패 후에도 준비 상태 /
34 `server.js:17` 인스턴스가 같은 제어 디렉터리를 공유 /
35 `server.js:135` spawn `error` 이벤트 미처리 /
36 `CMakeLists.txt:46` 테스트가 CTest 에 등록되지 않아 `ctest` 가 0개로 통과 /
37 `bench-10m.js:54` 클램프로 1000만 미달이면 예산 실패를 판정에서 제외 /
38 `gas-demo.js:92` 온도 검증이 `check(true, ...)` 무조건 통과

---

## 줄인 것

없음 — 24파일 전부 본문을 담아 넘겼다. 바이너리·자동생성 제외 대상 0건.

---

GATE: FAIL
