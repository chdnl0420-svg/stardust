# 후보 목록 — 알고리즘 × 스택

후보 단위는 (알고리즘 × 스택) 한 쌍. 채점 규칙은 [scoring.md](scoring.md).

## 병목이 어디인지 — 조사로 확정된 것

문헌 조사 결과 **병목은 중력이 아니라 유체(SPH) 쪽 이웃 탐색이다.**

| 근거 | 수치 | 출처 |
|---|---|---|
| GPU Barnes-Hut 중력 | 500만 바디 **1509 ms/스텝** | [Hsin-Hung/N-body-simulation](https://github.com/Hsin-Hung/N-body-simulation) |
| GPU SPH 현실적 한계 | 5만~10만 인터랙티브, 최적 공간해싱으로 **100만**. 1000만은 "극도로 도전적" | [MDPI 15/17/9706](https://www.mdpi.com/2076-3417/15/17/9706) |
| 자기중력 멀티그리드 단일 GPU | **1.8×10⁸ cells/s** → 4096²(1.68×10⁷셀) 기준 **93 ms** | [SFUMATO# arXiv:2604.21438](https://arxiv.org/pdf/2604.21438) |
| 균일 격자 + 부드러운 소스 | **FFT가 FMM·멀티그리드보다 우세** | [FFT/FMM/Multigrid 비교 arXiv:1408.6497](https://arxiv.org/pdf/1408.6497) |
| WebGPU 컴퓨트 상한 | GTX 1060에서 1000만 파티클 63 FPS (**상호작용 없음**), 상호작용 100만/60FPS | [Codrops WebGPU fluid](https://tympanus.net/codrops/2025/02/26/webgpu-fluid-simulations-high-performance-real-time-rendering/) |
| Stockham FFT | bit-reversal 제거 + ping-pong 버퍼 → GPU에 유리 | [Microsoft Research FFT on GPU](https://www.microsoft.com/en-us/research/wp-content/uploads/2008/01/FftGpuSC08.pdf) |

→ 중력을 아무리 빠르게 해도 SPH 이웃 탐색이 1000만에서 무너진다. **이웃 탐색을 없애는 것이 이 문제의 핵심.**

## 기준선 (기존 공개 방법)

| ID | 알고리즘 | 중력 | 유체 | 비고 |
|---|---|---|---|---|
| B1 | 직접 O(N²) | 전수 | — | **정확도 정답지**. N=20K까지만 |
| B2 | Barnes-Hut + 공간해싱 SPH | 쿼드트리 | SPH | 사용자가 언급한 정석. GPU에서 트리 순회 워프 발산 |
| B3 | PM + 공간해싱 SPH | 격자+FFT | SPH | 우주론 표준 하이브리드. **주 비교 대상** |
| B4 | TreePM + SPH | 격자+트리 | SPH | 근거리를 트리로 보정. B3보다 정확·느림 |
| B5 | FMM + SPH | 다극전개 | SPH | 이론상 O(N), GPU 구현 난이도 최상 |
| B6 | PM + WCSPH | 격자+FFT | 약압축성 SPH | 시간스텝이 음속에 묶여 더 잘게 쪼갬 |
| B7 | PM + PBF | 격자+FFT | Position Based Fluids | 큰 스텝 가능, 물리 충실도 낮음 |

## 새 후보 (이 조건에 맞춰 고안)

### X1 — 단일 격자 융합 (Unified Grid: PM-gravity + PIC/FLIP-hydro)

**착상**: 중력(PM)과 유체(PIC/FLIP)가 **같은 격자**를 쓴다. 이웃 탐색·정렬이 파이프라인에서 완전히 사라진다.

한 스텝:
1. 파티클 → 격자 산란(CIC): 질량, 운동량 — `O(N)`, atomic add
2. 격자 밀도 → FFT 포아송 → 중력 퍼텐셜 → 중력 가속도 — `O(M log M)`
3. **같은 격자 밀도** → 상태방정식으로 압력 → 압력 구배 → 압력 가속도 — `O(M)`
4. 격자 가속도 → 파티클 보간(gather) — `O(N)`
5. 파티클 적분 — `O(N)`

**왜 이게 새로운가**: PM(우주론)과 PIC/FLIP(그래픽스 유체)은 각각 표준이지만, **둘을 하나의 격자에 얹어 자기중력 가스를 푸는 조합은 검색에서 사례가 안 나왔다.** 천체물리 hybrid PIC는 플라즈마(전자를 유체로)용이고 자기중력이 아니다. 격자 유체 + PM 중력은 있으나(ENZO·RAMSES) 그건 Eulerian 유체라 파티클을 유지하지 않는다.

**예산 추정 `[추정]`** (4096² 격자, N=1000만, 3070 Ti 608 GB/s 기준):
- 2D FFT 왕복: 2~6 ms (문헌상 cuFFT 4096² C2C 1~3 ms)
- CIC 산란: 1000만 × 4셀 atomic → 2~5 ms
- 보간 gather: 1000만 × 4셀 읽기 320 MB → ~1 ms
- 적분 + 기타: ~1 ms
- **합계 6~13 ms → 75~160 FPS**

**약점(미리 적어 둠)**: 격자 셀보다 작은 중력·압력 구조가 뭉개짐. PIC는 수치 감쇠가 심함. FFT는 주기 경계를 강제(고립 경계를 원하면 2배 zero-padding → 4배 비용).

### X2 — X1 + FLIP 블렌딩

X1의 PIC 감쇠를 FLIP(격자에서 **증분**만 받아옴)으로 완화. 블렌딩 계수 α로 PIC↔FLIP 사이를 조절. 노이즈와 감쇠의 트레이드오프.

### X3 — X1의 멀티그리드 변형

FFT 대신 기하 멀티그리드로 포아송을 푼다. 고립 경계가 자연스럽고 zero-padding 4배 비용이 없다. 대신 반복 수렴이라 정확도-속도 트레이드오프. 문헌 수치상 4096²에서 93 ms `[추정]` — X1보다 크게 불리할 가능성.

### X4 — X1 + 근거리 SPH 보정 (하이브리드)

격자로 못 잡는 근거리만 **선택적으로** SPH로 보정. 밀도가 높은 셀에서만 이웃 탐색을 돌려 비용을 국소화. B4(TreePM)의 아이디어를 유체에 적용.

## 스택 후보

| ID | 스택 | 현재 상태 | 장점 | 걸림돌 |
|---|---|---|---|---|
| S1 | 네이티브 CUDA | **툴킷 미설치** | cuFFT·CUB 성숙, 성능 천장 최고 | 설치 필요(사용자 승인), CUDA↔GL interop |
| S2 | Unity 컴퓨트 셰이더 | 3버전 설치됨 | 렌더링·카메라·UI 공짜 | FFT 자작, 워프 인트린식 못 씀 |
| S3 | WebGPU (Chrome 151) | **즉시 가능** | 셋업 0, 브라우저에서 바로 측정 | 성능 천장 낮음, FFT 자작 |
| S4 | 네이티브 OpenGL/Vulkan 컴퓨트 | MSVC만 있음 | 천장 높음 | CMake·Vulkan SDK 미설치 |

## 측정 계획

같은 스택에서 알고리즘을 비교해야 공정하다. 셋업 비용이 0인 **S3(WebGPU)를 공통 측정대**로 삼는다.

1. **1단계** — S3에서 X1 · B3 · B2를 같은 조건으로 실측 → 알고리즘 승자
2. **2단계** — 승자 알고리즘을 S2(Unity)로 올려 실측 → 스택 비교
3. **3단계** — S1(CUDA)은 툴킷 설치가 필요하므로 사용자 승인을 받은 뒤에만

## 진행 기록

- 2026-08-13 문헌 기준선 수집 완료. 병목이 SPH 이웃 탐색임을 확인.
- 다음: S3(WebGPU) 환경 프로브 → X1 프로토타입 실측
