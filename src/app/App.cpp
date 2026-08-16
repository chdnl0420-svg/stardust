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
    // 계산량 쪽은 **아래 프레임 예산이 혼자 본다.** 전에는 여기서 멀티프로세서 수로도
    // 한 번 어림했는데(`SM 개수 × 10만`), 그 숫자에는 근거가 없었다 — 카드의 SM 수는
    // 한 스텝의 시간을 정하는 여러 값 중 하나일 뿐이고, 이 앱에서 실제로 시간을 쥐고 있는
    // 것은 격자다. 게다가 예산 계산이 이미 `estimateStepMs` 로 속도를 재고 있어
    // 같은 것을 두 번 자르는 꼴이었다. 근거 없는 쪽을 지운다.
    const size_t freeB = Sim::deviceFreeBytes();
    const int gridForBudget = Sim::maxGridSize(cfg.boundary);
    int byMemory = Sim::maxParticlesFor(gridForBudget, cfg.boundary, freeB);
    int cap = byMemory;
    // 최후의 그물. 메모리와 예산이 이미 자르고 있으므로 평소에는 안 걸리고, 두 계산이
    // 동시에 이상한 값을 내놓았을 때만 듣는다.
    //
    // **1000만에서 3000만으로 올렸다(2026-08-16).** 격자를 128 로 고정하고 예산을 30 프레임으로
    // 늘리자 1000만이 예산 안에 들어왔는데(실측: 스텝 16.7 ms, 프레임 23.4 ms, VRAM 여유 5.6 GB),
    // 이 줄이 그 위를 잘라 **메모리도 예산도 아닌 셋째 제한**이 되어 있었다.
    // 상한을 정하는 것은 메모리와 프레임 예산 둘뿐이어야 한다.
    if (cap > 30000000) cap = 30000000;
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
    // 그래서 **한 프레임 예산 안에 드는 조합만 허락한다.**
    //
    // **예산을 30 프레임으로 늘렸다(2026-08-16).** 60 프레임일 때는 정상 스텝이 4 ms 언저리라
    // 드라이버 타임아웃(2초)까지 512배의 여유가 있었는데, 그 여유를 알갱이 수로 바꾼다 —
    // 별의 한살이를 보려면 알갱이가 더 필요하고, 은하가 도는 것은 30 프레임으로도 충분히 보인다.
    //
    // **대신 잃는 것이 있다.** 정상 스텝이 26 ms 언저리로 오르면 타임아웃까지의 여유가
    // 512배에서 77배로 줄어든다. 그래서 아래 워치독의 문턱을 「정상 스텝의 배수」로 바꾸되
    // **250 ms 절대 상한을 함께 건다** — 배수만 두면 26 ms × 64 = 2131 ms 가 되어
    // 워치독이 손을 대기도 전에 드라이버가 먼저 죽는다(타임아웃이 2000 ms 다).
    {
        constexpr double kStepBudgetMs = 33.3;   // 30 프레임
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
    fx::mark("상한 %d = 메모리 한계 %d 를 한 프레임 예산(33.3 ms)으로 다시 조인 값. "
             "격자 %d, 스텝 어림 %.1f ms, VRAM 어림 %.0f MB",
             hardMaxParticles, byMemory, cfg.gridSize,
             Sim::estimateStepMs(cfg.particleCount, cfg.gridSize, cfg.boundary),
             Sim::estimateBytes(cfg.particleCount, cfg.gridSize, cfg.boundary) / 1048576.0);
    fx::mark("판 열기: 알갱이 %d, 격자 %d, 경계 %s, 장면 %d, 배속 %.2f",
             cfg.particleCount, cfg.gridSize,
             cfg.boundary == Boundary::Isolated ? "고립" : "주기",
             (int)cfg.preset, cfg.timeScale);

    sim.init(cfg);

    // 워치독 문턱을 이 설정의 정상 스텝에 맞춰 처음 잡는다. `init` 은 `applyConfig` 를
    // 거치지 않으므로 여기서 직접 부르지 않으면 첫 판이 기본값(250 ms) 그대로 돈다.
    UpdateDangerStepMs(*this);
    fx::mark("워치독 문턱 %.0f ms = min(정상 스텝 %.1f ms × 64, 250 ms). "
             "드라이버 타임아웃 2000 ms 안쪽이어야 한다",
             dangerStepMs,
             Sim::estimateStepMs(cfg.particleCount, cfg.gridSize, cfg.boundary));

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
    // 쓴 시간이다(cudaEvent 로 잰 것).
    //
    // **문턱은 고정값이 아니라 `dangerStepMs` 다**(applyConfig 가 정한다). 정상 스텝의 64배로
    // 잡되 **250 ms 를 절대 넘지 않는다.** 프레임 예산을 30 프레임으로 늘린 뒤 정상 스텝이
    // 26 ms 가 되었는데, 배수만 두면 2131 ms 라 타임아웃(2000 ms) 밖으로 나간다 —
    // 그러면 이 방어가 있으나 마나다.
    //
    // 멈추는 것을 고른 이유: 알갱이를 줄이는 것은 수 GB 버퍼를 다시 잡는 일이라 그 자체가
    // 위험하고(2026-08-13 첫 재부팅의 원인), 지금은 그럴 여유가 있는 상태가 아니다.
    // 멈추면 GPU 에 아무것도 밀어 넣지 않으므로 즉시 듣는다.
    {
        const SimTimings t = sim.timings();
        if (running && t.totalMs > dangerStepMs) {
            running = false;
            guardHaltedMs = t.totalMs;
            const BlackHoleState bh = sim.blackHole();
            // 디스크까지 미는 기록이다. 다음 스텝에서 시스템이 죽어도 이 줄은 남는다 —
            // 그것이 이 줄의 존재 이유다.
            fx::mark("!! 위험: 스텝 %.0f ms > 문턱 %.0f ms (타임아웃 2000 ms) — 멈춤. "
                     "알갱이 %d/%d, 격자 %d, dt %.6g, 최고속도 %.3g, "
                     "블랙홀 %s 질량 %.0f 지평선 %.5f",
                     t.totalMs, dangerStepMs, sim.activeCount(), cfg.particleCount, cfg.gridSize,
                     t.dtUsed, t.maxSpeed,
                     bh.active ? "있음" : "없음", bh.mass, bh.rs);
            return;
        }
    }

    // ── 광속에 눌어붙는 것을 본다 ─────────────────────────────────────────
    //
    // **위의 감시는 스텝 시간만 본다. 그것으로는 이번 사고를 못 잡았다.**
    //
    // 2026-08-14 23:48, 알갱이가 이 우주의 광속(17.3)에 3분 넘게 붙어 있는 채로 스텝은
    // 10 ms 였다 — 위 감시에는 아무 일도 없는 판으로 보였고, 그러다 커널 자료구조가 깨져
    // 시스템이 재부팅됐다(BugCheck 0x139, 같은 서명이 세 번째다).
    //
    // 속력이 상한에 오래 눌어붙는 것은 그 자체가 「힘이 폭주하고 있다」는 신호다. CFL 이
    // dt 를 깎아 격자를 건너뛰는 것은 막지만, 그만큼 시간이 안 흐르고 같은 자리에 원자
    // 연산이 계속 몰린다. 잠깐 닿는 것은 정상이므로(지평선 가까이서는 늘 그렇다) 5초는
    // 두고 보다가 기록만 남기고, 30초를 넘기면 멈춘다.
    {
        const SimTimings t = sim.timings();
        const float c = sqrtf(cfg.lightSpeedSq > 0.0f ? cfg.lightSpeedSq : 1.0f);
        if (running && t.maxSpeed > c * 0.98f) ++speedPinnedFrames;
        else                                    speedPinnedFrames = 0;

        if (speedPinnedFrames == 300) {          // 5초 — 기록만 남긴다
            fx::mark("!! 최고속도가 광속(%.3g)에 5초째 붙어 있다 — 힘이 폭주하는 중이다. "
                     "스텝 %.1f ms, dt %.6g, 알갱이 %d, 격자 %d",
                     c, t.totalMs, t.dtUsed, sim.activeCount(), cfg.gridSize);
        }
        if (running && speedPinnedFrames > 1800) {   // 30초 — 멈춘다
            running = false;
            speedPinnedFrames = 0;
            fx::mark("!! 위험: 최고속도가 광속(%.3g)에 30초째 붙어 있다 — 멈춤. "
                     "이 상태가 이어지면 커널 자료구조가 깨진다(2026-08-14 BugCheck 0x139). "
                     "스텝 %.1f ms, dt %.6g, 알갱이 %d/%d",
                     c, t.totalMs, t.dtUsed, sim.activeCount(), cfg.particleCount);
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
    UpdateDangerStepMs(*this);
}

void UpdateDangerStepMs(App& app) {
    // 워치독 문턱을 지금 설정의 정상 스텝에 맞춘다.
    //
    // `estimateStepMs` 는 산술 몇 줄이라 싸지만, 매 프레임 부를 이유가 없어 설정이 바뀔 때만
    // 다시 잡는다. 알갱이 수나 격자가 바뀌면 정상 스텝이 통째로 달라지므로 그 자리가 맞다.
    const double normalMs = Sim::estimateStepMs(app.cfg.particleCount, app.cfg.gridSize,
                                                app.cfg.boundary);

    // **250 ms 는 절대 상한이고 넘지 않는다.** 드라이버 타임아웃이 2000 ms 라, 문턱이 그보다
    // 크면 워치독이 손을 대기 전에 드라이버가 먼저 리셋되고 그 과정에서 시스템이 죽는다
    // (이 프로젝트에서 여섯 번 일어난 일이다). 30 프레임 예산의 정상 스텝 26 ms 에
    // 64배를 곱하면 2131 ms 라 그 선을 넘는다 — 그래서 min 이 필요하다.
    constexpr float kAbsoluteCeilMs = 250.0f;
    // 아래로도 바닥을 둔다. 알갱이를 최소로 줄이면 정상 스텝이 1 ms 아래로 내려가는데,
    // 그 64배(64 ms)를 문턱으로 삼으면 로딩 직후의 첫 몇 프레임처럼 원래 무거운 순간에
    // 워치독이 오발동한다.
    constexpr float kFloorMs = 60.0f;

    float threshold = (float)(normalMs * 64.0);
    if (threshold > kAbsoluteCeilMs) threshold = kAbsoluteCeilMs;
    if (threshold < kFloorMs)        threshold = kFloorMs;
    app.dangerStepMs = threshold;
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
            // **한 칸 점유를 함께 남긴다(2026-08-16 사고 뒤 추가).**
            //
            // 그날 시스템이 죽었을 때 남은 줄에 이 값이 없어서 「원자 연산이 한 칸에
            // 몰렸나」를 뒤에서 확인할 수 없었다. 스텝 시간은 죽기 직전까지 10~14 ms 로
            // 멀쩡했고 `nvlddmkm` 경고도 0 건이라, 남은 단서가 하나도 없었다.
            //
            // 이 값은 격자 칸 수만큼만 도는 커널이라 알갱이가 몇이든 비용이 같다.
            // 5초에 한 번이면 부담이 없고, 튀는 순간에는 그 줄이 디스크까지 간다.
            const int peak = sim.peakCellCount();
            put("%s: 스텝 %.1f ms (뿌리기 %.1f 푸아송 %.1f 거두기 %.1f 정렬 %.1f), "
                "프레임 %.1f ms, 알갱이 %d/%d, dt %.6g, 최고속도 %.3g, "
                "한칸최대 %d, 별 %d, "
                "블랙홀 %s 질량 %.0f 지평선 %.5f, 여유 VRAM %.0f MB",
                how, t.totalMs, t.scatterMs, t.poissonMs, t.gatherMs, t.sortMs,
                frameMs, sim.activeCount(), cfg.particleCount,
                t.dtUsed, t.maxSpeed,
                peak, sim.starCount(),
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
    // 오갔지만 여기서는 64~256 이 실제 범위다.
    // 아래로는 128 밑으로 내려가지 않는다. 64³ 이면 한 칸이 0.0156 이라 원반 두께(0.012)가
    // 한 칸보다 얇아 z 방향이 아예 표현되지 않는다 — 3D 로 옮긴 의미가 사라진다.
    //
    // **위로도 128 에서 멈춘다(2026-08-16).** 전에는 알갱이가 400만을 넘으면 256 으로 올렸는데,
    // 고립 경계에서 256 은 패딩까지 **512³ = 1억 3400만 칸**이라 알갱이를 하나도 안 넣어도
    // 한 스텝이 25 ms 다. 30 프레임 예산(33.3 ms)을 격자 혼자 거의 다 먹는다.
    //
    // 그 문턱이 있는 한 알갱이 상한은 400만에서 벽에 부딪힌다 — 400만을 넘기려는 순간
    // 격자가 뛰어 예산을 넘고, 예산 계산이 다시 400만 아래로 내려보내기 때문이다.
    // 별의 한살이는 **알갱이가 많아야** 보이는 것이지 격자가 세밀해야 보이는 것이 아니다.
    // 한 칸(판의 0.78%)보다 작은 구조를 못 보는 것은 그대로 감수한다.
    int g = 128;

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
    // 오래 밀도 하나로 굳어 있었다 — 온도는 그 계산을 하지 않아 값이 없었고, 속도는 점으로
    // 그릴 때만 뜻이 있었다. **이제 「빛」이 생겨 고를 것이 둘이다.**
    //
    // 빛은 별이 실제로 내는 밝기(L = M^3.5)로 그린다. 밀도로 보면 알갱이 스무 개일 뿐인
    // 무거운 별이 빛으로 보면 주변 수만 개보다 밝다 — 그것이 실제 밤하늘이 보이는 방식이다.
    //
    // **여기서 `app.look` 을 덮어쓰지 않는다.** 전에는 무조건 Density 로 되돌려,
    // 밖에서 보기를 바꿔도 다음 프레임에 지워졌다(2026-08-16 실측: `colorBy=light` 를
    // 넣어도 status 가 계속 density 였다).
    if (app.look == App::Look::Light) {
        app.view.colorBy = ColorBy::Light;
        // **빛으로 볼 때는 흑체 색을 쓴다.** 별이 실제로 내는 색이고, 밝기와 온도가 같은 축
        // (질량)에서 나오므로 밝기 격자 하나로 색까지 정해진다 — 무거운 별은 밝고 푸르게,
        // 가벼운 별은 어둡고 붉게 나온다.
        app.view.cmap = ColorMap::Blackbody;
    } else {
        app.look = App::Look::Density;
        app.view.colorBy = ColorBy::Density;
        app.view.cmap = ColorMap::Astro;
    }
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

    // **연출과 근사를 끈 채로 시작한다(2026-08-16).**
    //
    //  · `spiralWave` — 회전하는 밀도파로 **나선팔을 직접 그리는** 장치다. 팔이 나오는지
    //    보려고 팔을 그려 넣으면 그건 창발이 아니라 연출이다
    //  · `halo` — 암흑물질을 알갱이가 아니라 **배경 힘**으로 때우는 근사다. 없는 것을
    //    있는 척하는 쪽이 아니라 빠진 현실을 알갱이로 넣는 쪽이 이 판의 방향이다
    //
    // 둘 다 설정에서 켤 수는 있게 남긴다 — 켠 것과 끈 것을 견주는 것이 이 판의 방법이다.
    //
    // **중력을 0.9 로 되돌린다.** 전에는 헤일로를 켠 장면에서 0.22 로 낮췄다 — 보이지 않는
    // 무게가 회전을 맡으면 원반 자신은 가벼워야 했기 때문이다. 그 헤일로가 없어졌으므로
    // 원반이 제 무게로 돌아야 한다. 이 값을 안 되돌리면 아무것도 자라지 않는다
    // (2026-08-14 실측: 거미줄 장면이 0.22 를 물려받아 끝까지 밋밋했다).
    cfg.haloEnabled = false;
    cfg.spiralWaveEnabled = false;
    cfg.gravity = 0.9f;
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

    // 압력 — **켠다(2026-08-16).**
    //
    // 옛 주석은 "무압력 중력계에서 나오는 현상이라 끄는 쪽이 선명하다"였는데, 그때
    // `pressureEnabled` 는 **코어에서 한 번도 안 쓰이는 플래그**였다(2026-08-16 실측: 사용 0회).
    // 즉 「끈 쪽이 선명하다」는 것은 미구현 플래그를 끈 것이고, 실제로 압력 노릇을 하던 것은
    // `orbitDispersion` 이라는 손으로 정한 숫자였다.
    //
    // 이제 속도 분산 텐서가 실제로 돌고 `orbitDispersion` 은 0 이다. **둘은 한 몸이라
    // 같이 바뀌어야 한다** — 압력을 끈 채 난수만 빼면 원반을 붙잡는 것이 아무것도 없다.
    cfg.pressureEnabled = true;

    // 별 형성 — **켠다(2026-08-16).**
    //
    // 코어 기본값이 `false` 라(`Sim.h` `starFormationEnabled`) 프리셋이 안 켜면 **앱을 열어
    // 그냥 두었을 때 별이 하나도 안 생긴다.** 2026-08-16 실측에서 100초를 돌려도 `starCount`
    // 가 0 이었다 — 이 판이 만든 것(별의 한살이·초신성·재 사슬·흑체 색)이 통째로 안 보인다.
    // 스물다섯 바퀴 동안 못 봤던 것은 측정 스크립트가 매번 `starFormation=1` 을 명시해
    // 켜고 잰 탓이다. **스크립트가 켜 주는 것은 사용자가 보는 것이 아니다.**
    //
    // 우주 구조 형성 장면은 예외로 둔다 — 거기서 보려는 것은 격자 규모의 필라멘트이지
    // 개별 별이 아니고, 별이 되면 그 알갱이는 더 안 뭉쳐 구조가 흐려진다.
    cfg.starFormationEnabled = (preset != Preset::CosmicWeb);

    // 팽창 — 주기 경계에서만 물리적 의미가 있고, 켠 상태와 끈 상태를 비교하는 것이 목적이라
    //        프리셋 전환 시에는 항상 꺼 두고 사용자가 직접 켜게 한다.
    cfg.expansionEnabled = false;
}
