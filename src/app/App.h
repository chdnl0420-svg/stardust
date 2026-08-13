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
    float      brightness = 1.0f;
    float      gamma      = 1.8f;
    bool       showHud    = true;
};

struct App {
    Sim          sim;
    SimConfig    cfg;          // 설정 보드가 직접 만지는 값
    ViewSettings view;

    bool  running = true;      // 일시정지 여부
    bool  stepOnce = false;    // "한 스텝" 버튼
    Tool  tool = Tool::Camera;

    // 카메라 — 화면 좌표계에서 [0,1]² 시뮬레이션 공간을 어디에 어떻게 놓을지
    float zoom = 1.0f;
    float panX = 0.0f, panY = 0.0f;

    // HUD 표시용
    float fps = 0.0f;
    float frameMs = 0.0f;

    void init();
    // 설정 보드에서 바뀐 값을 코어에 반영한다. 파티클 수·격자·경계가 바뀌면 코어가 재할당한다.
    void applyConfig();
    void tick();
};

// 프리셋이 시나리오에 맞는 경계·압력·팽창을 함께 정한다.
// 설정 보드와 MCP 제어 채널이 같은 규칙을 써야 하므로 한 곳에 둔다.
// 고른 뒤 개별 토글로 덮어쓸 수 있다.
void ApplyPresetDefaults(SimConfig& cfg, Preset preset);
