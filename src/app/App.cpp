#include "app/App.h"
#include "app/Forensics.h"

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
    //  · 메모리 — **실제로 쓸 격자**로 버퍼가 들어가는가
    //  · 계산량 — 알갱이 하나를 한 스텝 옮기는 데 드는 일이 초당 몇 번이나 가능한가
    //
    // 재는 격자를 실제 값으로 잡는 것이 중요하다. 2D 시절에는 여기에 가장 큰 격자(2048)를
    // 넣었는데, 3D 로 오면서 그 값이 상한 밖이 되어 계산이 폭발했고 상한이 최소값(10만)까지
    // 떨어졌다(2026-08-14 실측: 200만을 요청했는데 화면에 10만만 떴다).
    //
    // 계산량 쪽은 정확히 예측할 수 없어 카드의 멀티프로세서 수로 어림한다. 실측에서
    // 3000만 개가 60 FPS 로 돌기는 했지만 그때 드라이버가 깨졌다 — 「프레임이 나온다」와
    // 「카드가 버틴다」는 다른 말이었다. 그래서 어림값을 보수적으로 잡고, 모자라면
    // 아래 guardPerformance 가 도는 중에 더 낮춘다.
    const size_t freeB = Sim::deviceFreeBytes();
    const int gridForBudget = Sim::maxGridSize(cfg.boundary);
    int byMemory = Sim::maxParticlesFor(gridForBudget, cfg.boundary, freeB);
    // 3D 는 알갱이 하나가 격자 8칸을 오가므로 2D 보다 한 개당 일이 두 배다.
    int bySpeed  = 10000000;
    {
        const int sm = Sim::deviceMultiProcessors();
        // 멀티프로세서 하나당 10만 개를 상한으로 본다.
        if (sm > 0) bySpeed = sm * 100000;
    }
    int cap = (byMemory < bySpeed) ? byMemory : bySpeed;
    if (cap > 10000000) cap = 10000000;
    if (cap < 200000)   cap = 200000;

    // ── 그 개수가 **부르는 격자**까지 계산에 넣는다 ────────────────────────
    //
    // 여기까지의 두 기준은 알갱이만 본다. 그런데 이 앱에서 한 스텝의 시간을 정하는 것은
    // 알갱이가 아니라 **격자**다 — 푸아송을 푸는 동안 오가는 양이 한 변의 세제곱으로 늘고,
    // 고립 경계는 거기에 여덟 배가 더 붙기 때문이다.
    //
    // 그리고 격자는 따로 고르는 값이 아니라 **알갱이 수가 정한다**(ApplyAutoGrid).
    // 그래서 상한을 400만 위로 열어 두면 그 순간 격자가 256³ 으로 올라가고, 고립 경계에서
    // 실제로 도는 것은 512³ 이 된다. 이 카드에서 그것만으로 한 스텝이 25 ms 다 —
    // 알갱이를 하나도 안 넣어도 그렇다.
    //
    // **왜 그것이 재부팅으로 이어지는가.** 스텝이 이미 무거우면 남는 여유가 없다. 거기서
    // 블랙홀을 놓아 알갱이가 한곳으로 몰리면 격자에 질량을 더하는 원자 연산이 같은 칸에
    // 겹쳐 커널 하나가 수십 배 느려지는데, 그 배수가 드라이버 타임아웃(2초)을 넘기면
    // 드라이버가 강제로 리셋되고 그 과정에서 시스템이 죽는다
    // (2026-08-14 실측: 480만 · 256³ · 블랙홀 질량 100만 — 하루에 여섯 번 재부팅).
    //
    // 그래서 **한 프레임 예산 안에 드는 조합만 허락한다.** 예산을 60 프레임에 맞추면
    // 정상 스텝이 4 ms 언저리가 되어, 몰림으로 백 배가 튀어도 타임아웃 전에 아래
    // guardPerformance 가 손을 댈 수 있다.
    {
        constexpr double kStepBudgetMs = 16.7;   // 60 프레임
        // 규칙을 여기에 옮겨 적지 않는다 — 실제로 그 개수를 넣어 보고 격자를 받아 온다.
        auto gridFor = [&](int count) {
            SimConfig probe = cfg;
            probe.particleCount = count;
            probe.contactEnabled = false;   // 접촉은 격자를 한 단계 더 올린다. 상한 산정에서는 뺀다
            ApplyAutoGrid(probe);
            return probe.gridSize;
        };

        double ms = Sim::estimateStepMs(cap, gridFor(cap), cfg.boundary);
        if (ms > kStepBudgetMs) {
            // 격자가 비용을 쥐고 있으므로, 한 단계 아래 격자를 부르는 개수까지 내리는 것이
            // 가장 크게 듣는다. 이분법으로 예산에 드는 가장 큰 개수를 찾는다.
            int lo = 200000, hi = cap;
            while (lo < hi) {
                const int mid = lo + (hi - lo + 1) / 2;
                if (Sim::estimateStepMs(mid, gridFor(mid), cfg.boundary) <= kStepBudgetMs) lo = mid;
                else hi = mid - 1;
            }
            cap = lo;
        }
    }
    if (cap < 200000) cap = 200000;
    hardMaxParticles = cap;
    if (cfg.particleCount > hardMaxParticles) {
        cfg.particleCount = hardMaxParticles;
        ApplyAutoGrid(cfg);
    }

    // 상한이 어떻게 정해졌는지 남긴다. 사고가 나면 가장 먼저 볼 줄이다 —
    // 「이 카드에 이 개수가 맞았는가」가 여기서 판가름 나기 때문이다.
    fx::mark("카드 %s · %s · SM %d · 대역폭 %.0f GB/s · 여유 VRAM %.0f MB",
             Sim::deviceName().c_str(), Sim::deviceDriver().c_str(),
             Sim::deviceMultiProcessors(), Sim::deviceBandwidthGBs(), freeB / 1048576.0);
    fx::mark("상한 %d = min(메모리 %d, 속도 %d) 를 한 프레임 예산으로 다시 조인 값. "
             "격자 %d, 스텝 어림 %.1f ms, VRAM 어림 %.0f MB",
             hardMaxParticles, byMemory, bySpeed, cfg.gridSize,
             Sim::estimateStepMs(cfg.particleCount, cfg.gridSize, cfg.boundary),
             Sim::estimateBytes(cfg.particleCount, cfg.gridSize, cfg.boundary) / 1048576.0);
    fx::mark("판 열기: 알갱이 %d, 격자 %d, 경계 %s, 장면 %d, 배속 %.2f",
             cfg.particleCount, cfg.gridSize,
             cfg.boundary == Boundary::Isolated ? "고립" : "주기",
             (int)cfg.preset, cfg.timeScale);

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

    // ── 타임아웃 직전 방어 ────────────────────────────────────────────────
    //
    // 아래의 감시는 「4초 동안 계속 느리면」 손을 댄다. 그런데 드라이버 타임아웃은 **2초**다 —
    // 한 스텝이 그것을 넘으면 드라이버가 강제로 리셋되고, 그 과정에서 커널 자료구조가 깨져
    // 시스템이 통째로 재부팅된다. 즉 아래 감시는 원리적으로 이 사고를 막을 수 없다.
    //
    // 그래서 **스텝 하나**를 보고, 위험선을 넘으면 그 자리에서 멈춘다. 이 값은 GPU 가 실제로
    // 쓴 시간이다(cudaEvent 로 잰 것). 250 ms 는 타임아웃까지 여덟 배가 남는 자리라,
    // 다음 스텝이 그보다 몇 배 더 나빠져도 아직 시간이 있다.
    //
    // 멈추는 것을 고른 이유: 알갱이를 줄이는 것은 수 GB 버퍼를 다시 잡는 일이라 그 자체가
    // 위험하고(2026-08-13 첫 재부팅의 원인), 지금은 그럴 여유가 있는 상태가 아니다.
    // 멈추면 GPU 에 아무것도 밀어 넣지 않으므로 즉시 듣는다.
    {
        constexpr float DANGER_STEP_MS = 250.0f;
        const SimTimings t = sim.timings();
        if (running && t.totalMs > DANGER_STEP_MS) {
            running = false;
            guardHaltedMs = t.totalMs;
            const BlackHoleState bh = sim.blackHole();
            // 디스크까지 미는 기록이다. 다음 스텝에서 시스템이 죽어도 이 줄은 남는다 —
            // 그것이 이 줄의 존재 이유다.
            fx::mark("!! 위험: 스텝 %.0f ms (타임아웃 2000 ms) — 멈춤. "
                     "알갱이 %d/%d, 격자 %d, dt %.6g, 최고속도 %.3g, "
                     "블랙홀 %s 질량 %.0f 지평선 %.5f",
                     t.totalMs, sim.activeCount(), cfg.particleCount, cfg.gridSize,
                     t.dtUsed, t.maxSpeed,
                     bh.active ? "있음" : "없음", bh.mass, bh.rs);
            return;
        }
    }

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
        fx::mark("버거워서 낮춤: %d → %d (프레임 %.1f ms 가 %.0f ms 넘게 이어짐)",
                 cfg.particleCount, lower, frameMs, PATIENCE_MS);
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
    // 보는 방향을 먼저 넘긴다 — 이 프레임의 그림이 그 방향으로 투영된다.
    // 구조(개수·격자·경계)와 달리 판을 다시 잡지 않으므로 재시작 중에도 그냥 넘긴다.
    sim.setViewAngles(camYaw, camPitch);

    // 설정 보드·제어 채널이 만진 값을 매 프레임 코어에 넘긴다.
    //
    // 전에는 위젯마다 "이건 바뀌었으니 반영하라"는 표시(needApply)를 손으로 켰는데,
    // 켜야 할 곳 17군데가 빠져 있었다 — 중력 세기·힘 공식·소프트닝·압력·γ·온도·냉각·별 형성·
    // 팽창·시간 배속·정렬 주기가 전부 화면에서만 바뀌고 계산에는 안 갔다(round-06 리뷰 P1 #1).
    // 표시를 빠뜨릴 수 있는 구조 자체를 없애고, 재할당이 필요한지는 코어가 판단하게 둔다
    // (Sim::reconfigure 는 파티클 수·격자·경계가 바뀔 때만 버퍼를 다시 잡는다).
    //
    // **다만 판을 다시 깔아야 하는 셋(알갱이 수·격자·경계)은 여기로 흘려보내지 않는다.**
    //
    // 그 셋은 슬라이더를 끄는 내내 매 프레임 값이 바뀐다. 그대로 넘기면 지나치는 값마다
    // 수백 MB 를 해제하고 다시 잡는데, 그것이 이 프로젝트에서 그래픽 드라이버를 무너뜨린
    // 첫 번째 원인이었다(2026-08-13). 「다시 깔기를 물어보는 중」이라는 표시는 화면에만
    // 있었고 실제 적용은 여기서 매 프레임 일어나고 있었다 — 2026-08-14 사고 기록에
    // 0.21초 동안 다섯 번 다시 잡은 것이 그대로 찍혀 있다.
    //
    // 물어보는 중에는 코어가 지금 쓰고 있는 값을 그대로 돌려주어 구조를 건드리지 않게 하고,
    // 나머지 값(중력·압력·배속 따위)은 평소처럼 즉시 반영한다. 실제 적용은 사용자가
    // 「다시 깔고 적용」을 누를 때 applyConfig() 가 한 번만 한다.
    {
        SimConfig live = cfg;
        if (needsRestart) {
            live.particleCount = sim.particleCount();
            live.gridSize      = sim.gridSize();
            live.boundary      = sim.config().boundary;
        }
        sim.reconfigure(live);
    }

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

    // 무게중심을 화면 가운데에 붙여 둔다.
    //
    // 은하 둘이 서로를 끌면 쌍 전체가 한쪽으로 흘러가 결국 화면 밖으로 나간다. 카메라를
    // 무게중심에 매어 두면 따라다니지 않아도 된다 — 물리는 그대로 두고 보는 자리만 옮긴다.
    // 매 프레임 재면 GPU 리덕션이 그만큼 도므로 여섯 프레임에 한 번만 잰다.
    if (ui.keepCenterOfMass) {
        if (++comTimer >= 6) {
            comTimer = 0;
            double cx = 0.5, cy = 0.5;
            sim.measureCentroid(cx, cy);
            // screenToSim 의 역이다 — 화면 한가운데가 시뮬 좌표 (0.5 - pan) 에 닿는다.
            panX = 0.5f - (float)cx;
            panY = 0.5f - (float)cy;
        }
    }

    // 카드가 힘겨워하면 스스로 짐을 던다.
    guardPerformance();

    // ── 사고 기록에 남기는 상태 ───────────────────────────────────────────
    //
    // 시스템이 통째로 죽는 사고에서는 종료 코드도 예외도 남지 않는다. 남는 것은 죽기 전에
    // **디스크까지 닿은** 줄뿐이다. 그래서 두 가지를 적는다.
    //   · 몇 초에 한 줄 — 평소 상태(느려지는 흐름을 뒤에서 읽을 수 있게)
    //   · 갑자기 나빠진 순간 — 주기와 무관하게, 디스크까지
    {
        const SimTimings t = sim.timings();
        const bool spike = (t.totalMs > 80.0f) && (t.totalMs > fxLastStepMs * 2.0f);
        if (--fxTimer <= 0 || spike) {
            fxTimer = 300;   // 60 프레임이면 5초에 한 줄
            const BlackHoleState bh = sim.blackHole();
            const char* how = spike ? "!! 갑자기 무거워짐" : "상태";
            // 튀는 순간만 디스크까지 민다. 평소 줄까지 밀면 5초마다 수 ms 를 버린다.
            auto put = spike ? &fx::mark : &fx::line;
            put("%s: 스텝 %.1f ms (뿌리기 %.1f 푸아송 %.1f 거두기 %.1f 정렬 %.1f), "
                "프레임 %.1f ms, 알갱이 %d/%d, dt %.6g, 최고속도 %.3g, "
                "블랙홀 %s 질량 %.0f 지평선 %.5f, 여유 VRAM %.0f MB",
                how, t.totalMs, t.scatterMs, t.poissonMs, t.gatherMs, t.sortMs,
                frameMs, sim.activeCount(), cfg.particleCount,
                t.dtUsed, t.maxSpeed,
                bh.active ? "있음" : "없음", bh.mass, bh.rs,
                Sim::deviceFreeBytes() / 1048576.0);
        }
        fxLastStepMs = t.totalMs;
    }
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
                // 놓는 순간을 디스크까지 남긴다. 시스템이 죽는 사고는 거의 언제나 무언가를
                // 놓은 **직후**에 났다 — 그 한 줄이 있어야 「무엇을 놓았을 때인가」를 안다.
                fx::mark("놓기: 모양 %d, 개수 %d, 크기 %.3f, 자리 (%.3f, %.3f) — "
                         "지금 알갱이 %d, 격자 %d",
                         (int)brush.shapeKind, brush.shapeCount, brush.shapeRadius, u, v,
                         sim.activeCount(), cfg.gridSize);
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
    // **3D 라 한 변을 하나 올릴 때마다 칸이 여덟 배가 된다.** 2D 시절에는 1024 와 2048 을
    // 오갔지만 여기서는 64~256 이 실제 범위다. 칸당 알갱이가 대여섯이 되도록 잡는다 —
    // 128³ 은 200만 칸이라 200만 알갱이면 칸당 하나 남짓이다.
    // 아래로는 128 밑으로 내려가지 않는다. 64³ 이면 한 칸이 0.0156 이라 원반 두께(0.012)가
    // 한 칸보다 얇아 z 방향이 아예 표현되지 않는다 — 3D 로 옮긴 의미가 사라진다.
    int g = (cfg.particleCount >= 4000000) ? 256 : 128;

    // 알갱이끼리 부딪히게 할 장면이면 격자를 한 단계 올려 본다.
    // 알갱이 반지름이 칸의 절반이라, 칸이 크면 알갱이도 커져 금세 판을 가득 채운다.
    if (cfg.contactEnabled && !ContactFitsCount(cfg.particleCount, g) && g < 256) g *= 2;

    // 코어가 아는 상한을 넘지 않는다. 고립 경계는 패딩 때문에 실제로 여덟 배를 잡는다.
    const int cap = Sim::maxGridSize(cfg.boundary);
    if (g > cap) g = cap;
    cfg.gridSize = g;

    // 소프트닝은 「칸 몇 개」 단위라, 격자를 올리면 칸이 작아진 만큼 실제 길이가 짧아진다.
    // 그대로 두면 가까운 거리의 힘이 커져 처음 켜자마자 알갱이가 튀어 나간다.
    // 격자에 비례해 올려 길이를 지킨다(기준은 128³).
    cfg.softeningCells = 3.0f * ((float)cfg.gridSize / 128.0f);
}

bool ContactFitsCount(int particleCount, int gridSize) {
    // 알갱이 반지름은 격자 칸의 절반이다. 그 공들이 판의 40% 를 넘게 채우면
    // 서로 밀어내기만 하다 판이 굳어 버리므로 그 선에서 접촉을 끈다.
    //
    // **3D 라 넓이가 아니라 부피로 센다.**
    //   N · (4/3)π · (0.5/G)³ ≤ 0.4   →   N ≤ 0.764 · G³
    // 2D 공식(G²)을 그대로 두었더니 128 격자에서 상한이 1만 2천이라, 100만 알에서
    // 접촉을 아예 켤 수 없었다(2026-08-14 실측). 실제 상한은 160만이다.
    const double g = (double)(gridSize > 0 ? gridSize : 1);
    return (double)particleCount <= 0.764 * g * g * g;
}

void ApplyLook(App& app) {
    // 색은 밀도 하나로 굳혔다. 온도는 그 계산을 하지 않아 값이 없었고, 속도는 점으로 그릴
    // 때만 뜻이 있었다 — 고를 것이 하나뿐이라 고르는 자리도 없앴다.
    app.look = App::Look::Density;
    app.view.colorBy = ColorBy::Density;
    app.view.cmap    = ColorMap::Astro;
    app.view.brightness = app.brightDensity;
    app.view.gamma      = app.gammaDensity;
}

void RememberLook(App& app) {
    // 슬라이더로 방금 맞춘 값을 지금 보고 있는 쪽에 담아 둔다. 이게 없으면 밀도↔움직임을
    // 오갈 때마다 ApplyLook 이 예전 값으로 되돌려 방금 맞춘 것이 사라진다.
    if (app.look == App::Look::Dispersion) {
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
    // 3D 로 오면서 기본을 끔으로 돌렸다.
    //
    // 밀도의 대비가 2D 와 완전히 다르다. 원반은 위아래로 얇아(두께가 지름의 1/50) 그 칸들의
    // 밀도가 평균의 백몇십 배로 뜬다 — 아무것도 무너지지 않았는데도 그렇다. 2D 문턱을 그대로
    // 쓰면 판을 열자마자 블랙홀이 생긴다(2026-08-14 실측). 3D 에 맞는 문턱을 실측으로 정하기
    // 전까지는 사용자가 설정에서 켜는 것으로 둔다.
    cfg.collapseEnabled  = false;

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
        // 나선 밀도파도 은하 장면에서만 켠다. 팔이 감겨 사라지지 않게 붙잡는 것이 이 힘이고,
        // 중심이 없는 장면(거미줄)이나 중심이 주인공인 장면(블랙홀)에는 뜻이 없다.
        cfg.spiralWaveEnabled = true;
    } else {
        cfg.spiralWaveEnabled = false;
        // **헤일로가 없는 장면은 중력을 반드시 되돌린다.**
        //
        // 이 한 줄이 없어서 우주 거미줄이 끝까지 밋밋했다. 나선 은하에서 거미줄로 갈아타면
        // 0.22 가 그대로 남는데, 그 장면은 알갱이 자신의 무게만으로 구조를 만들어야 하므로
        // 그 값으로는 아무것도 자라지 않는다(2026-08-14 실측).
        cfg.gravity = 0.9f;
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
    // 식히기는 켠 채로 시작한다. 꺼 두면 중력으로 모인 것이 그 자리에서 데워져 도로
    // 흩어지기만 해 **어느 장면에서도 아무것도 뭉치지 않는다** — 모였다 흩어졌다만
    // 되풀이한다(2026-08-14 실측: 켜면 최대밀도 6771 → 94483, 점유 셀 273876 → 15440).
    // 접촉과 달리 값이 싸다(스텝 4 → 6 ms).
    cfg.coolingEnabled = true;

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
