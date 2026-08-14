#include "app/App.h"

void App::init() {
    cfg.particleCount = 1000000;
    ApplyAutoGrid(cfg);     // 격자와 소프트닝은 알갱이 수를 보고 정한다

    // 첫 장면도 **장면 버튼을 누른 것과 똑같이** 맞춘다.
    // 전에는 preset 만 정하고 나머지는 SimConfig 기본값에 맡겼는데, 그 기본값은 압력이 켜져 있다.
    // 나선 은하는 압력이 없어야 팔이 생기는 장면이라, 처음 켠 사람은 스스로 부풀어 터지는
    // 은하를 보게 됐다 — 프리셋 버튼을 한 번 눌러야만 정상이 되는 상태였다(2026-08-13 실측).
    ApplyPresetDefaults(cfg, Preset::SpiralDisk);

    sim.init(cfg);
}

void App::applyConfig() {
    // 재할당이 필요한지는 코어가 판단한다. 여기서 미리 비교하면 판정이 두 곳으로 갈린다.
    sim.reconfigure(cfg);
}

void App::tick() {
    // 설정 보드·제어 채널이 만진 값을 매 프레임 코어에 넘긴다.
    //
    // 전에는 위젯마다 "이건 바뀌었으니 반영하라"는 표시(needApply)를 손으로 켰는데,
    // 켜야 할 곳 17군데가 빠져 있었다 — 중력 세기·힘 공식·소프트닝·압력·γ·온도·냉각·별 형성·
    // 팽창·시간 배속·정렬 주기가 전부 화면에서만 바뀌고 계산에는 안 갔다(round-06 리뷰 P1 #1).
    // 표시를 빠뜨릴 수 있는 구조 자체를 없애고, 재할당이 필요한지는 코어가 판단하게 둔다
    // (Sim::reconfigure 는 파티클 수·격자·경계가 바뀔 때만 버퍼를 다시 잡는다).
    sim.reconfigure(cfg);

    stepsLastFrame = 0;
    if (stepOnce) {                 // "한 스텝" 은 배속과 무관하게 정확히 한 번이다
        sim.step();
        stepsLastFrame = 1;
        stepOnce = false;
    } else if (running) {
        // 배속 > 1 은 시간 간격을 늘려서는 못 낸다(CFL 안정성 한계 — Sim::step 의 주석 참조).
        // 대신 한 프레임에 스텝을 여러 번 돌린다. 계산량이 그 배수만큼 늘어 프레임 예산을
        // 넘길 수 있다는 뜻이라, 상한을 8 로 막아 슬라이더 최대값(4.0)에서도 안전하게 둔다.
        int reps = 1;
        if (cfg.timeScale > 1.0f) {
            reps = (int)(cfg.timeScale + 0.5f);
            if (reps < 1) reps = 1;
            if (reps > 16) reps = 16;
        }
        for (int i = 0; i < reps; ++i) sim.step();
        // 코어가 실패 상태면 step 은 아무것도 안 하고 돌아온다 — 그때까지 돈 것으로 세면
        // 제어 채널이 멈춘 시뮬레이션을 정상 진행으로 보고한다(round-08 리뷰 A12).
        stepsLastFrame = Sim::failed() ? 0 : reps;
    }

    // 화면에 그릴 천체를 프레임에 한 번만 가져온다. 멈춰 있을 때도 가져와야 일시정지 중에
    // 천체가 사라지지 않는다.
    bodyListCount = cfg.bodiesEnabled ? sim.readBodies(bodyList, MAX_DRAW_BODIES) : 0;
}

void App::screenToSim(int px, int py, int viewW, int viewH, float& u, float& v) const {
    if (viewW <= 0 || viewH <= 0) { u = v = 0.5f; return; }
    const float aspect = (float)viewW / (float)viewH;
    u = ((float)px + 0.5f) / (float)viewW;
    v = ((float)py + 0.5f) / (float)viewH;
    // 짧은 변을 [0,1] 에 맞춘다 — 렌더 셰이더와 같은 규칙이라야 클릭 위치가 어긋나지 않는다.
    if (aspect > 1.0f) u = (u - 0.5f) * aspect + 0.5f;
    else               v = (v - 0.5f) / aspect + 0.5f;
    u = (u - 0.5f) / zoom + 0.5f - panX;
    v = (v - 0.5f) / zoom + 0.5f - panY;
}

void App::applyToolAt(float u, float v, bool firstClick) {
    switch (tool) {
        case Tool::Spray:
            sim.sprayAt(u, v, brush.radius, brush.strength);
            break;
        case Tool::Well:
            sim.wellAt(u, v, brush.radius, brush.strength);
            break;
        case Tool::AddShape:
            // 형태는 누를 때 한 번만 넣는다. 드래그로 계속 쏟아지면 순식간에 슬롯이 바닥난다.
            if (firstClick)
                sim.addShape(u, v, brush.shapeKind, brush.shapeRadius,
                             brush.shapeCount, brush.autoOrbit);
            break;
        case Tool::Erase:
            sim.eraseAt(u, v, brush.radius);
            break;
        case Tool::Camera:
        default:
            break;
    }
}

void ApplyAutoGrid(SimConfig& cfg) {
    // 격자는 알갱이 수에 맞춰 고른다.
    //
    // 칸당 알갱이가 너무 많으면 밀도장이 뭉개져 화면이 뿌옇게 보인다 — 3000만 개를 1024² 에
    // 뿌리면 칸당 28개라 구조가 죄다 번진다(2026-08-14 실측). 칸당 대여섯 개가 되도록 올린다.
    // 4096 은 고립 경계에서 패딩이 8192² 라 VRAM 을 몇 GB 더 먹으므로 여기서는 쓰지 않는다.
    cfg.gridSize = (cfg.particleCount >= 5000000) ? 2048 : 1024;

    // 소프트닝은 「칸 몇 개」 단위라, 격자를 올리면 칸이 작아진 만큼 실제 길이가 짧아진다.
    // 그대로 두면 가까운 거리의 힘이 두 배가 되어 처음 켜자마자 알갱이가 튀어 나간다
    // (2026-08-13 실측: 초속 80까지 올라 원반이 부풀었다). 격자에 비례해 올려 길이를 지킨다.
    cfg.softeningCells = 3.0f * ((float)cfg.gridSize / 1024.0f);
}

void ApplyLook(App& app) {
    // 사용자가 고르는 것은 「밀도로 볼까 온도로 볼까」 하나뿐이다.
    // 색 기준·컬러맵·온도 추적은 그 선택에 딸려 오는 것이라 여기서 함께 맞춘다 —
    // 따로 두면 온도로 바꿔 놓고 온도 추적이 꺼져 있어 화면이 새까맣게 보이는 일이 생긴다.
    if (app.look == App::Look::Temperature) {
        app.view.colorBy = ColorBy::Temperature;
        app.view.cmap    = ColorMap::Thermal;
        app.cfg.temperatureEnabled = true;   // 온도를 안 재면 보여줄 값이 없다
        app.view.brightness = app.brightTemp;
        app.view.gamma      = app.gammaTemp;
    } else {
        app.view.colorBy = ColorBy::Density;
        app.view.cmap    = ColorMap::Astro;
        app.view.brightness = app.brightDensity;
        app.view.gamma      = app.gammaDensity;
    }
}

void RememberLook(App& app) {
    // 슬라이더로 방금 맞춘 값을 지금 보고 있는 쪽에 담아 둔다. 이게 없으면 밀도↔온도를
    // 오갈 때마다 ApplyLook 이 예전 값으로 되돌려 방금 맞춘 것이 사라진다.
    if (app.look == App::Look::Temperature) {
        app.brightTemp = app.view.brightness;
        app.gammaTemp  = app.view.gamma;
    } else {
        app.brightDensity = app.view.brightness;
        app.gammaDensity  = app.view.gamma;
    }
}

void ApplyPresetDefaults(SimConfig& cfg, Preset preset) {
    cfg.preset = preset;

    // 블랙홀 장면은 중심의 휘어진 시공간이 주인공이라, 파티클끼리 끌어당기는 힘은 꺼 둔다.
    // 켜 두면 원반이 스스로 뭉쳐 덩어리가 되면서 궤도 이야기가 묻힌다.
    cfg.blackHoleEnabled = (preset == Preset::BlackHole);
    if (preset == Preset::BlackHole) {
        cfg.gravity = 0.0f;          // 자기중력 끔 — 중심 블랙홀만 남긴다
        cfg.boundary = Boundary::Isolated;
        cfg.pressureEnabled = false;
        cfg.expansionEnabled = false;
        cfg.temperatureEnabled = true;   // 안쪽으로 갈수록 빨라지는 것을 온도로도 볼 수 있게
        return;
    }
    // 천체 만들기는 이 장면에서만 켠다. 다른 장면에서 켜면 나선팔이 생기기도 전에
    // 팔을 이루던 가스가 전부 덩어리로 먹혀 그 장면의 주인공이 사라진다.
    cfg.bodiesEnabled = (preset == Preset::Accretion);
    if (preset == Preset::Accretion) {
        cfg.boundary = Boundary::Isolated;
        cfg.gravity = 0.6f;
        cfg.pressureEnabled = false;     // 압력이 있으면 뭉치는 것을 그만큼 밀어낸다
        cfg.expansionEnabled = false;
        cfg.temperatureEnabled = true;
        cfg.coolingEnabled = true;       // 식어야 뭉친다 — 뜨거운 가스는 스스로 흩어진다
        cfg.starFormationEnabled = false;// 별은 천체 등급이 대신한다
        return;
    }
    cfg.coolingEnabled = false;

    // 경계 — 은하 장면은 텅 빈 우주에 홀로 떠 있어야 하고(고립),
    //        우주 구조 형성은 반대편으로 이어지는 우주가 표준이다(주기).
    cfg.boundary = (preset == Preset::CosmicWeb) ? Boundary::Periodic : Boundary::Isolated;

    // 압력 — 충격파는 가스가 부딪혀 서는 현상이라 압력이 있어야 나온다.
    //        나선팔·조석꼬리·구조형성은 무압력 중력계에서 나오는 현상이라 끄는 쪽이 선명하다
    //        (프로토타입 검증에서 확인 — proto/cuda/x5.cu 의 scene 별 pressure 설정).
    cfg.pressureEnabled = (preset == Preset::HeadOnShock);

    // 팽창 — 주기 경계에서만 물리적 의미가 있고, 켠 상태와 끈 상태를 비교하는 것이 목적이라
    //        프리셋 전환 시에는 항상 꺼 두고 사용자가 직접 켜게 한다.
    cfg.expansionEnabled = false;
}
