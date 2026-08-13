// 앱 상태 — 조립 지점.
// 설정 보드가 만지는 값과 시뮬레이션 코어를 여기서 연결한다.
// 물리 계산은 하지 않는다(그건 Core 인 Sim 의 몫).
#pragma once

#include "sim/Sim.h"

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

    // 최대 파티클 수 슬라이더가 끌리는 동안 들고 있는 값(만 단위).
    // 슬라이더는 끄는 내내 매 프레임 값이 바뀌는데, 그걸 그대로 적용하면 지나치는 값마다
    // 수 GB 버퍼를 해제하고 다시 잡는다 — 손을 뗐을 때 한 번만 적용하려고 따로 둔다.
    int   particleSlider = -1;

    // 화면을 가리는 것을 전부 감춘다(설정 보드·HUD·도구 막대). Tab 키로 켜고 끈다.
    // 녹화하거나 그림만 보고 싶을 때 쓴다.
    bool  uiHidden = false;

    // 「보기」가 고르는 표현 방식. 나머지 색 설정(컬러맵·온도 추적)은 여기에 맞춰 자동으로 정한다.
    enum class Look { Density, Temperature };
    Look  look = Look::Density;

    // 「점으로 그리기」 체크박스. view.mode 와 짝인데, 체크박스가 bool 을 직접 받아야 해서 따로 둔다.
    bool  pointsMode = false;

    // 「한 번에 놓을 개수」 슬라이더가 끌리는 동안 들고 있는 값(만 단위).
    int   shapeCountSlider = -1;

    // 화면에 그릴 천체 목록. 프레임마다 코어에서 한 번 가져온다 —
    // 그리는 쪽이 직접 GPU 를 읽으면 매 프레임 여러 번 동기화가 걸린다.
    static constexpr int MAX_DRAW_BODIES = 2048;
    BodyView bodyList[MAX_DRAW_BODIES];
    int      bodyListCount = 0;

    void init();
    // 설정 보드에서 바뀐 값을 코어에 반영한다. 파티클 수·격자·경계가 바뀌면 코어가 재할당한다.
    void applyConfig();
    void tick();

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

// 「보기」에서 고른 표현 방식에 맞춰 색과 온도 설정을 함께 맞춘다.
// 사용자가 만지는 것은 밀도/온도 둘 중 하나뿐이고, 컬러맵·색 기준·온도 추적은 여기서 정한다.
void ApplyLook(App& app);
