// 앱 상태 — 조립 지점.
// 설정 보드가 만지는 값과 시뮬레이션 코어를 여기서 연결한다.
// 물리 계산은 하지 않는다(그건 Core 인 Sim 의 몫).
#pragma once

#include <string>

#include "sim/Sim.h"
#include "app/Updater.h"

// 마우스 도구. 증분 1 에서는 카메라만 동작하고 나머지는 자리만 잡아 둔다.
enum class Tool { Camera, Spray, Well, AddShape, Erase };

// 화면에 무엇을 어떻게 그릴지.
enum class RenderMode { DensityField, Points };
enum class ColorBy    { Density, Temperature, Speed };
enum class ColorMap   { Astro, Gray, Thermal };

struct ViewSettings {
    RenderMode mode    = RenderMode::DensityField;
    ColorBy    colorBy = ColorBy::Density;
    ColorMap   cmap    = ColorMap::Astro;
    float      brightness = 2.0f;   // 1.0 은 바깥쪽 구조가 안 보일 만큼 어둡다(실측)
    float      gamma      = 1.8f;
    bool       showHud    = true;
};

// 마우스 도구 설정. 설정 보드와 MCP 가 같은 값을 만진다.
struct BrushSettings {
    float     radius       = 0.028f;  // 뿌리기·우물·지우개 브러시 반지름(시뮬 좌표)
    float     strength     = 0.35f;   // 뿌리기·우물 세기
    ShapeKind shapeKind    = ShapeKind::Galaxy;
    float     shapeRadius  = 0.12f;
    int       shapeCount   = 150000;
    bool      autoOrbit    = true;    // 형태를 넣을 때 그 자리 중력을 재서 궤도속도를 준다
};

struct App {
    Sim          sim;
    SimConfig    cfg;          // 설정 보드가 직접 만지는 값
    ViewSettings view;
    BrushSettings brush;

    bool  running = true;      // 일시정지 여부
    bool  stepOnce = false;    // "한 스텝" 버튼
    Tool  tool = Tool::Camera;

    // 카메라 — 화면 좌표계에서 [0,1]² 시뮬레이션 공간을 어디에 어떻게 놓을지
    float zoom = 1.0f;
    float panX = 0.0f, panY = 0.0f;

    // HUD 표시용
    float fps = 0.0f;
    float frameMs = 0.0f;
    // 직전 프레임에 실제로 돈 스텝 수. 배속을 1보다 올리면 한 프레임에 여러 번 돈다.
    // 화면에 보여주기도 하지만, 배속이 정말 먹었는지 밖에서 확인할 유일한 신호이기도 하다
    // — 벽시계 시간당 진행량으로는 프레임 수가 함께 줄어 상쇄돼 안 보인다(round-07 실측).
    int   stepsLastFrame = 0;

    // 녹화 — 켜면 매 프레임(또는 간격마다) PNG 를 저장한다.
    bool  recording = false;
    int   recordEvery = 1;      // 몇 프레임에 하나를 저장할지
    int   recordedFrames = 0;
    int   frameCounter = 0;
    bool  snapshotRequested = false;   // 스냅샷 버튼이 눌렸다
    // 마지막 저장이 실패했다(디스크 부족·권한 등). 조용히 넘어가면 사용자는 파일이 생긴 줄 안다.
    bool  lastSaveFailed = false;

    // ── 그래픽카드를 지키는 두 겹의 방어 ──────────────────────────────────
    //
    // 이 앱은 알갱이 수를 올리면 수 GB 버퍼를 잡고 초당 수억 번의 계산을 GPU 에 밀어 넣는다.
    // 그 부담이 카드가 감당할 선을 넘으면 화면은 멀쩡해 보이는 채로 드라이버가 서서히 무너지고,
    // 한참 뒤에 시스템이 통째로 재부팅된다(2026-08-13~14 사이 네 번 실측).
    // 「돌아가는 것처럼 보인다」는 안전의 근거가 되지 못하므로 스스로 선을 긋는다.

    // 앱을 켤 때 한 번 계산해 고정하는 상한. 슬라이더는 이 수를 넘지 못한다.
    // **매 프레임 다시 재지 않는다** — 남은 VRAM 은 다른 프로그램 때문에 매 순간 오르내리고,
    // 그 값으로 상한을 흔들면 요청이 그대로인데도 버퍼를 계속 다시 잡는다(1차 재부팅의 원인).
    int   hardMaxParticles = 30000000;

    // 자동 업데이트. 앱을 켤 때 한 번 배포 저장소를 확인하고, 새 버전이 있으면 알린다.
    // 받는 것은 사용자가 눌렀을 때만 한다 — 받아 온 것을 바로 실행하는 일이라
    // 모르는 사이에 프로그램이 바뀌어 있으면 안 된다.
    Updater updater;
    bool    updateBusy = false;   // 내려받는 중
    std::string updateError;      // 마지막 실패 사유(비어 있으면 없음)

    // 도는 동안의 감시. 프레임이 예산을 계속 넘으면 알갱이 수를 스스로 낮춘다.
    float overBudgetMs = 0.0f;   // 예산을 넘긴 채 흘러간 시간
    int   guardCooldown = 0;     // 이 프레임 수만큼은 다시 낮추지 않는다(진동 방지)
    int   guardCappedTo = 0;     // 자동으로 낮춘 결과. 0 이면 낮춘 적 없다

    // 최대 파티클 수 슬라이더가 끌리는 동안 들고 있는 값(만 단위).
    // 슬라이더는 끄는 내내 매 프레임 값이 바뀌는데, 그걸 그대로 적용하면 지나치는 값마다
    // 수 GB 버퍼를 해제하고 다시 잡는다 — 손을 뗐을 때 한 번만 적용하려고 따로 둔다.
    int   particleSlider = -1;

    // 화면을 가리는 것을 전부 감춘다(하단 막대·상태줄). Tab 키로 켜고 끈다.
    // 녹화하거나 그림만 보고 싶을 때 쓴다.
    bool  uiHidden = false;

    // 장면 서랍이 열려 있는가. 평소에는 닫혀 있고 하단 막대의 장면 칩을 누르면 올라온다 —
    // 화면에 상주하는 것을 막대 하나로 줄이는 것이 이 화면 설계의 핵심이다.
    bool  drawerOpen = false;

    // 놓기 서랍. 도구의 「놓기」를 누르면 모양을 고르는 서랍이 같은 자리에 올라온다.
    // 고르면 한 번만 놓이고 도구는 화면 옮기기로 돌아간다.
    bool  shapeDrawerOpen = false;

    // 블랙홀의 지평선·광자 구면·최소 안정 궤도를 원으로 겹쳐 그릴지.
    // 계산 결과가 아니라 설명하려고 얹는 그림이라 기본은 꺼 둔다 — 물질이 그리는 모양만으로도
    // 어디가 중심인지는 보인다.
    bool  showHorizon = false;


    // 「보기」가 고르는 표현 방식. 나머지 색 설정(컬러맵·온도 추적)은 여기에 맞춰 자동으로 정한다.
    enum class Look { Density, Temperature };
    Look  look = Look::Density;

    // 밀도와 온도는 값의 범위가 달라 보기 좋은 밝기·세기가 서로 다르다.
    // 하나를 공유하면 전환할 때마다 다시 맞춰야 하므로 각자 기억한다.
    float brightDensity = 2.0f, brightTemp = 2.0f;
    float gammaDensity  = 1.8f, gammaTemp  = 1.8f;

    // 「점으로 그리기」 체크박스. view.mode 와 짝인데, 체크박스가 bool 을 직접 받아야 해서 따로 둔다.
    bool  pointsMode = false;

    // 「한 번에 놓을 개수」 슬라이더가 끌리는 동안 들고 있는 값(만 단위).
    int   shapeCountSlider = -1;


    void init();
    // 설정 보드에서 바뀐 값을 코어에 반영한다. 파티클 수·격자·경계가 바뀌면 코어가 재할당한다.
    void applyConfig();
    void tick();
    // 프레임이 예산을 계속 넘으면 알갱이 수를 스스로 낮춘다. 매 프레임 부른다.
    void guardPerformance();

    // 화면 픽셀 좌표를 시뮬레이션 좌표([0,1]²)로 바꾼다.
    // 렌더 셰이더(kShade)와 같은 변환을 써야 클릭한 자리와 보이는 자리가 일치한다.
    void screenToSim(int px, int py, int viewW, int viewH, float& u, float& v) const;
    // 지금 선택된 도구를 그 자리에 적용한다. 카메라 도구면 아무것도 하지 않는다.
    void applyToolAt(float u, float v, bool firstClick);
};

// 프리셋이 시나리오에 맞는 경계·압력·팽창을 함께 정한다.
// 설정 보드와 MCP 제어 채널이 같은 규칙을 써야 하므로 한 곳에 둔다.
// 고른 뒤 개별 토글로 덮어쓸 수 있다.
void ApplyPresetDefaults(SimConfig& cfg, Preset preset);

// 알갱이 수에 맞는 격자 해상도와 소프트닝을 정한다. 최대 개수를 바꿀 때마다 부른다.
void ApplyAutoGrid(SimConfig& cfg);

// 이 개수·격자에서 알갱이끼리 부딪히게 할 수 있는가(판에 움직일 공간이 남는가).
bool ContactFitsCount(int particleCount, int gridSize);

// 「보기」에서 고른 표현 방식에 맞춰 색과 온도 설정을 함께 맞춘다.
// 사용자가 만지는 것은 밀도/온도 둘 중 하나뿐이고, 컬러맵·색 기준·온도 추적은 여기서 정한다.
void ApplyLook(App& app);

// 밝기·세기 슬라이더를 만진 직후에 부른다. 지금 보고 있는 쪽(밀도 또는 온도)에 그 값을 담아 둔다.
void RememberLook(App& app);
