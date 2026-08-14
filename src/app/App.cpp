#include "app/App.h"

void App::init() {
    cfg.particleCount = 1000000;
    ApplyAutoGrid(cfg);     // 격자와 소프트닝은 알갱이 수를 보고 정한다

    // 첫 장면도 **장면 버튼을 누른 것과 똑같이** 맞춘다.
    // 전에는 preset 만 정하고 나머지는 SimConfig 기본값에 맡겼는데, 그 기본값은 압력이 켜져 있다.
    // 나선 은하는 압력이 없어야 팔이 생기는 장면이라, 처음 켠 사람은 스스로 부풀어 터지는
    // 은하를 보게 됐다 — 프리셋 버튼을 한 번 눌러야만 정상이 되는 상태였다(2026-08-13 실측).
    ApplyPresetDefaults(cfg, Preset::SpiralDisk);
    ApplyAutoGrid(cfg);

    // 이 그래픽카드가 감당할 수 있는 상한을 여기서 한 번 정하고 그 뒤로 바꾸지 않는다.
    //
    // 기준은 두 가지다.
    //  · 메모리 — 가장 큰 격자(2048²)로도 버퍼가 들어가는가
    //  · 계산량 — 알갱이 하나를 한 스텝 옮기는 데 드는 일이 초당 몇 번이나 가능한가
    //
    // 계산량 쪽은 정확히 예측할 수 없어 카드의 멀티프로세서 수로 어림한다. 실측에서
    // 이 카드(SM 46개)가 3000만 개를 60 FPS 로 돌리기는 했지만 그때 드라이버가 깨졌다 —
    // 「프레임이 나온다」와 「카드가 버틴다」는 다른 말이었다. 그래서 어림값을 보수적으로 잡고,
    // 모자라면 아래 guardPerformance 가 도는 중에 더 낮춘다.
    const size_t freeB = Sim::deviceFreeBytes();
    int byMemory = Sim::maxParticlesFor(2048, Boundary::Isolated, freeB);
    int bySpeed  = 30000000;
    {
        const int sm = Sim::deviceMultiProcessors();
        // 멀티프로세서 하나당 20만 개를 상한으로 본다.
        if (sm > 0) bySpeed = sm * 200000;
    }
    int cap = (byMemory < bySpeed) ? byMemory : bySpeed;
    if (cap > 30000000) cap = 30000000;
    if (cap < 100000)   cap = 100000;
    hardMaxParticles = cap;
    if (cfg.particleCount > hardMaxParticles) {
        cfg.particleCount = hardMaxParticles;
        ApplyAutoGrid(cfg);
    }

    sim.init(cfg);

    // 설정 화면 왼쪽 아래에 적을 「이 그림을 그리는 카드」. 한 번 물어 담아 둔다.
    deviceName    = Sim::deviceName();
    driverVersion = Sim::deviceDriver();

    // 새 버전이 나왔는지 배포 저장소에 물어본다. 다른 스레드에서 도므로 창이 뜨는 것을 막지 않는다.
    updater.startCheck();
}

void App::guardPerformance() {
    // 한 화면을 그리는 데 쓸 수 있는 시간. 이 선을 넘으면 카드가 힘겨워하고 있다는 뜻이다.
    constexpr float BUDGET_MS   = 40.0f;   // 25 FPS
    constexpr float PATIENCE_MS = 4000.0f; // 이만큼 이어지면 손을 댄다
    constexpr int   COOLDOWN_FRAMES = 900; // 낮춘 뒤 약 15초는 가만히 둔다

    if (guardCooldown > 0) { --guardCooldown; overBudgetMs = 0.0f; return; }
    if (!running || frameMs <= 0.0f) return;

    if (frameMs > BUDGET_MS) overBudgetMs += frameMs;
    else                     overBudgetMs = 0.0f;
    if (overBudgetMs < PATIENCE_MS) return;

    // 한 번에 30% 씩 덜어낸다. **올리는 쪽은 절대 자동으로 하지 않는다** —
    // 오르내리기를 반복하면 수 GB 버퍼를 초당 여러 번 다시 잡게 되고 드라이버가 그것을
    // 버티지 못한다(2026-08-13 첫 재부팅의 원인).
    int lower = (int)((double)sim.particleCount() * 0.7);
    if (lower < 100000) lower = 100000;
    if (lower < cfg.particleCount) {
        cfg.particleCount = lower;
        ApplyAutoGrid(cfg);
        guardCappedTo = lower;
    }
    overBudgetMs = 0.0f;
    guardCooldown = COOLDOWN_FRAMES;
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

    // 카드가 힘겨워하면 스스로 짐을 던다.
    guardPerformance();
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
            if (firstClick) {
                sim.addShape(u, v, brush.shapeKind, brush.shapeRadius,
                             brush.shapeCount, brush.autoOrbit);
                // 한 번 놓았으면 화면 옮기기로 돌아간다.
                // 놓기를 켠 채로 두면 화면을 옮기려고 누른 것이 또 한 덩어리를 쏟는다 —
                // 되돌릴 방법이 없어서 그때마다 장면을 처음부터 다시 시작해야 했다.
                tool = Tool::Camera;
            }
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
    int g = (cfg.particleCount >= 5000000) ? 2048 : 1024;

    // 알갱이끼리 부딪히게 할 장면이면 격자를 한 단계 더 올려 본다.
    // 알갱이 반지름이 칸의 절반이라, 칸이 크면 알갱이도 커져 금세 판을 가득 채운다 —
    // 100만 개는 1024² 에서 이미 한도(약 80만)를 넘어 접촉이 아예 안 켜진다.
    if (cfg.contactEnabled && !ContactFitsCount(cfg.particleCount, g)) g = 2048;
    cfg.gridSize = g;

    // 소프트닝은 「칸 몇 개」 단위라, 격자를 올리면 칸이 작아진 만큼 실제 길이가 짧아진다.
    // 그대로 두면 가까운 거리의 힘이 두 배가 되어 처음 켜자마자 알갱이가 튀어 나간다
    // (2026-08-13 실측: 초속 80까지 올라 원반이 부풀었다). 격자에 비례해 올려 길이를 지킨다.
    cfg.softeningCells = 3.0f * ((float)cfg.gridSize / 1024.0f);
}

bool ContactFitsCount(int particleCount, int gridSize) {
    // 알갱이 반지름은 격자 칸의 절반이다. 그 원들이 판의 60% 를 넘게 채우면
    // 서로 밀어내기만 하다 판이 굳어 버리므로 그 선에서 접촉을 끈다.
    //   N · π · (0.5/G)² ≤ 0.6   →   N ≤ 0.764 · G²
    const double g = (double)(gridSize > 0 ? gridSize : 1);
    return (double)particleCount <= 0.764 * g * g;
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

    // 블랙홀 장면은 **이미 있는** 블랙홀 둘레를 보는 장면이다.
    // 다른 장면에서는 판 어딘가가 무너지면 그때 생긴다 — 물질이 따라가는 길은 둘이 같다.
    //
    // 무너져 생기는 쪽은 알갱이끼리 부딪히게 해 두었을 때만 뜻이 있다. 버티는 힘이 있어야
    // 「중력이 그것을 이겼다」는 말이 성립하기 때문이다. 그래서 접촉과 함께 켜고 끈다.
    cfg.blackHoleEnabled = (preset == Preset::BlackHole);
    cfg.collapseEnabled  = (preset != Preset::BlackHole);

    // 보이지 않는 무게는 은하 장면에서만 켠다.
    //  · 은하 둘 — 판 한가운데 하나를 두어 둘이 그 둘레를 돌게 한다(은하군이 그렇다)
    //  · 우주 거미줄 — 반대편으로 이어지는 우주라 「중심」이 없다
    //  · 블랙홀 — 중심의 휘어진 시공간이 주인공이라 다른 중력을 더하면 궤도 이야기가 흐려진다
    cfg.haloEnabled = (preset == Preset::SpiralDisk || preset == Preset::TidalPair);
    if (cfg.haloEnabled) {
        // 보이지 않는 무게가 회전을 맡으면 원반 자신의 무게는 그만큼 가벼워야 한다.
        // 실제 은하도 원반은 전체 질량의 10~20% 뿐이다. 여기를 안 낮추면 원반이 제 무게로
        // 국소 붕괴해 나선팔이 자라기 전에 조각조각 뭉친다(2026-08-14 실측).
        cfg.gravity = 0.22f;
    }
    if (preset == Preset::BlackHole) {
        // 자기중력을 살려 둔다. 지평선 크기는 이제 삼킨 질량에서 나오고(rs = 2GM/c²),
        // 그 G 가 곧 여기 있는 중력 세기다 — 0 으로 두면 블랙홀도 함께 사라진다.
        // 낮게 잡아 알갱이끼리 뭉치는 것보다 중심이 주인공이 되게 한다.
        cfg.gravity = 0.15f;
        cfg.boundary = Boundary::Isolated;
        cfg.pressureEnabled = false;
        cfg.expansionEnabled = false;
        cfg.temperatureEnabled = true;   // 안쪽으로 갈수록 빨라지는 것을 온도로도 볼 수 있게
        return;
    }
    // 알갱이끼리 부딪히게 할지는 장면이 정하지 않는다 — 어느 장면에서든 체크박스로 켠다.
    // 다만 장면을 갈아탈 때 이전 설정이 따라오면 「왜 갑자기 느리지」가 되므로 끈 상태로 시작한다.
    cfg.contactEnabled = false;
    cfg.coolingEnabled = false;

    // 경계 — 은하 장면은 텅 빈 우주에 홀로 떠 있어야 하고(고립),
    //        우주 구조 형성은 반대편으로 이어지는 우주가 표준이다(주기).
    cfg.boundary = (preset == Preset::CosmicWeb) ? Boundary::Periodic : Boundary::Isolated;

    // 압력 — 나선팔·조석꼬리·구조형성은 전부 무압력 중력계에서 나오는 현상이라 끄는 쪽이 선명하다
    //        (프로토타입 검증에서 확인 — proto/cuda/x5.cu 의 scene 별 pressure 설정).
    cfg.pressureEnabled = false;

    // 팽창 — 주기 경계에서만 물리적 의미가 있고, 켠 상태와 끈 상태를 비교하는 것이 목적이라
    //        프리셋 전환 시에는 항상 꺼 두고 사용자가 직접 켜게 한다.
    cfg.expansionEnabled = false;
}
