#include "app/App.h"
#include "app/Forensics.h"

void App::init() {
    cfg.particleCount = 1000000;
    ApplyAutoGrid(cfg);     // 격자와 소프트닝은 알갱이 수를 보고 정한다

    // 첫 장면도 **장면 버튼을 누른 것과 똑같이** 맞춘다.
    // 전에는 preset 만 정하고 나머지는 SimConfig 기본값에 맡겼는데, 그러면 처음 켠 사람이
    // 프리셋 버튼을 한 번 눌러야만 정상인 상태를 보게 된다(2026-08-13 실측).
    ApplyPresetDefaults(cfg, Preset::Filament);
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

    // **보기와 색을 짝지어 둔다.** 전에는 `ApplyLook` 이 「설정 초기화」 버튼에서만 불려서,
    // `look` 기본값을 바꿔도 `view.colorBy`·`view.cmap` 이 안 따라왔다 — 2026-08-17 실측:
    // `look` 을 빛으로 바꿨는데 화면은 그대로 밀도 색이었다. 짝을 여기서 한 번 맞춘다.
    ApplyLook(*this);
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
                     "블랙홀 %s 질량 %.0f 지평선 %.3e",
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
    // 2026-08-14 23:48, 알갱이가 이 우주의 광속(100)에 3분 넘게 붙어 있는 채로 스텝은
    // 10 ms 였다 — 위 감시에는 아무 일도 없는 판으로 보였고, 그러다 커널 자료구조가 깨져
    // 시스템이 재부팅됐다(BugCheck 0x139, 같은 서명이 세 번째다).
    //
    // 속력이 상한에 오래 눌어붙는 것은 그 자체가 「힘이 폭주하고 있다」는 신호다. CFL 이
    // dt 를 깎아 격자를 건너뛰는 것은 막지만, 그만큼 시간이 안 흐르고 같은 자리에 원자
    // 연산이 계속 몰린다. 잠깐 닿는 것은 정상이므로(지평선 가까이서는 늘 그렇다) 5초는
    // 두고 보다가 기록만 남기고, 30초를 넘기면 멈춘다.
    {
        const SimTimings t = sim.timings();
        const float c = lightSpeedFor(cfg.lengthScale, cfg.timeUnitScale);
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
    sim.setViewRot(camRot);

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
        // **배속을 스텝 반복과 dt 로 나눈다.** 규칙은 `Sim.h` 의 `stepRepsFor` 하나뿐이고
        // `Sim::step` 의 `dtScaleFor` 와 짝이다 — 둘이 어긋나면 배속이 이중 적용된다.
        //
        // 앞의 3 배까지만 여기서 스텝을 나눠 돈다. 그 위를 계속 스텝으로 내면 **GPU 가
        // 초당 도는 스텝 수가 천장**이라 fps 만 떨어지고 진행량은 안 는다(실측: 스텝 5 ms
        // 면 초당 200 회 — 배속 3.3 배에서 막힌다). 넘는 몫은 dt 가 받고, 그 dt 는
        // CFL 이 자른다.
        const int reps = stepRepsFor(cfg.timeScale);
        for (int i = 0; i < reps; ++i) sim.step();
        // 코어가 실패 상태면 step 은 아무것도 안 하고 돌아온다 — 그때까지 돈 것으로 세면
        // 제어 채널이 멈춘 시뮬레이션을 정상 진행으로 보고한다(round-08 리뷰 A12).
        stepsLastFrame = Sim::failed() ? 0 : reps;
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
            // 구간 이름의 뜻: 중력=scatterMs, 냉각·별=poissonMs, 적분=gatherMs (`SimTimings` 참조).
            put("%s: 스텝 %.1f ms (중력 %.1f 냉각·별 %.1f 적분 %.1f), "
                "프레임 %.1f ms, 알갱이 %d/%d, dt %.6g, 최고속도 %.3g, "
                "한칸최대 %d, 별 %d, "
                "블랙홀 %s 질량 %.0f 지평선 %.3e, 여유 VRAM %.0f MB",
                how, t.totalMs, t.scatterMs, t.poissonMs, t.gatherMs,
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
        // **빛으로 볼 때는 흑체 색을 쓴다.** 별이 실제로 내는 색이다.
        //
        // 색은 **밝기가 아니라 온도**가 정한다(2026-08-17 에 나눴다). `L = 4πR²σT⁴` 라
        // 밝기가 크기와 온도 둘 다에 달려 있어, 밝기 하나로 색을 정하면 **작고 뜨거운 것**
        // (백색왜성·중성자별)이 「어두우니 붉다」로 잘못 그려진다. 격자를 둘로 나눈 이유가
        // 그것이고, 그래서 이 보기에서만 넷(작은 별·큰 별·중성자별·블랙홀)이 갈린다.
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

    // ── 중력 하나만 남겼다(2026-08-19) ──────────────────────────────────────
    //
    // 별의 한살이·냉각·압력·접촉·블랙홀·세 힘을 전부 걷어냈다. 남은 것은 중력과,
    // 중력만 받는 것들(암흑물질·팽창·암흑에너지)뿐이다.
    //
    // 그래서 나선 은하 장면도 함께 지웠다 — 별이 안 생기면 그 장면은 팔도 별도 없는
    // 빈 껍데기가 된다. 남은 장면은 우주 필라멘트와 빈 우주 둘이다.
    //
    // 아래에서 힘 스위치들을 **명시적으로 끈다.** 기본값이 꺼짐인 것으로는 부족하다 —
    // 사용자가 전에 켜 두었으면 장면을 갈아타도 따라오기 때문이다(2026-08-19 실측:
    // 전자기력이 켜진 채 필라멘트가 돌아 「중력 공식만으로 동작하는 걸로는 안 보였어」).
    cfg.starFormationEnabled = false;
    cfg.coolingEnabled       = false;
    cfg.pressureEnabled      = false;
    cfg.contactEnabled       = false;
    cfg.blackHoleEnabled     = false;
    cfg.collapseEnabled      = false;
    cfg.strongForceEnabled   = false;
    cfg.emForceEnabled       = false;
    cfg.weakForceEnabled     = false;

    // 중력 세기. 구조가 자라려면 원반이 제 무게로 돌아야 한다 — 0.22 로 낮췄던 시절
    // 거미줄 장면이 끝까지 밋밋했다(2026-08-14 실측).
    cfg.gravity  = 0.9f;
    cfg.boundary = Boundary::Isolated;

    if (preset == Preset::Filament) {
        // ── 눈금 — 길이와 시간을 따로 잡는다 ────────────────────────────────
        //
        // 판 한 변 1억 광년(약 30 Mpc) · 시뮬 시간 1단위 10억 년.
        // 묶어 두면 광속은 안 변해서 편하지만 **나이가 어긋난다** — 구조가 여무는
        // simTime 21.9 가 길이에 맞춘 눈금(1단위 100억 년)에서는 2190억 년이 되는데
        // 실제 우주는 138억 년이다. 100 이면 219억 년으로 1.6 배까지 좁혀진다.
        // 더 줄이면 광속(= 시간/길이)이 내려가 빅뱅 초기 팽창이 거기 닿는다.
        cfg.lengthScale   = 1000.0f;
        cfg.timeUnitScale = 100.0f;

        // **물질의 85%가 암흑물질이다** — 실제 우주의 비율이고, 거대구조를 짜는 것이 그쪽이다.
        cfg.darkMatterFraction = 0.85f;

        // 각운동량 — 판 전체에 얹는 약한 회전. 크게 주면 원심력이 중력을 이겨
        // 그물이 자라기 전에 펴진다.
        cfg.spin = 0.15f;

        // ── 다 자란 공에서 시작한다(2026-08-20, 빅뱅을 걷어냈다) ──────────────
        //
        // 전에는 0.12 로 접어 모은 뒤 터뜨렸다. 보기에는 좋았지만 **속이 비었다** —
        // 사용자가 「구형 내부가 안 채워져있어」로 잡았고, 원인은 아래 암흑에너지 주석에
        // 적은 껍질 정리 오독이다. 이제는 접지 않고 **처음부터 다 자란 크기**로 깐다.
        //
        // 0.90 은 접는 것이 아니라 여유다. `ballPoint` 가 반지름 0.5 로 깔아 판에 꽉
        // 채우는데, 그대로 두면 알갱이가 아래 `softBoundR` 바깥에서 시작해 첫 프레임부터
        // 감속을 맞는다. 0.90 이면 반지름 0.45 라 경계와 0.02 가 뜬다.
        cfg.bigBangShrink = 0.90f;

        // 팽창은 없다. 이미 다 자란 크기라 퍼질 곳이 없고, 퍼지면 그만큼 껍질이 된다.
        cfg.hubble = 0.0f;

        // 암흑에너지 — **균일한 공 안에서는 중력도 r 에 비례한다(껍질 정리).**
        //
        // 앞서 33 을 쓴 근거가 틀렸다. 중력을 점질량(GM/r²)으로 보고 「r=0.4 에서 2.35 배」
        // 라고 적었는데, 균일한 공 **안쪽**에서 반지름 r 인 껍질이 받는 중력은 그 안에 든
        // 질량만 세므로 `a = (GM/R³)·r` 로 **r 에 비례한다**. 암흑에너지도 `Λ·r` 이라
        // 둘의 비가 `Λ·R³/(GM)` 으로 **반지름과 무관하다** — 1 보다 크면 공 어디서나
        // 팽창이 이겨 물질이 바깥 껍질로 밀린다. 33 은 R=0.45 기준 균형(≈10)의 3 배였다.
        // 그래서 속이 빈 것이다.
        //
        // **그리고 GM 을 코드에서 안 읽고 주석의 가정값으로 냈다.** 위 식에 `G=0.9 · M=1`
        // 을 넣어 균형을 9.9 로 계산했는데, 실제로는 **알갱이 하나의 질량이 1** 이라
        // 총질량이 알갱이 수에 비례한다(100만이면 M=100만). 자유낙하 시간 3.5 초에서
        // 역산한 실측 `GM/R³ ≈ 0.25` 로, **내 계산이 37 배 컸다.**
        //
        // 실측(알갱이 100만 · 각 150 초, 안쪽 비율은 균일한 공 대비):
        //
        //   Λ      속                                     그물          판정
        //   0.00   찼지만 t=4.7 에 안쪽 91% — 가운데 공    아주 셈       무너진다
        //   0.05   4.2%→48% 로 **완만히** 참               있음(밀도 500) ← 이것
        //   0.10   t=7.6 에 안쪽 0.01% — 껍질              셈             빈다
        //
        // Λ=0 은 합격 기준은 통과하지만 쓸 수 없다 — 붕괴와 되튐을 반복해 가운데 공이
        // 된다(사용자가 2026-08-19 에 「우주가 가운데로 합쳐져서 무너져내리고있어」로
        // 지적한 그 상태다). 0.05 가 그 붕괴를 늦추면서 속을 채운 채로 둔다.
        //
        // **알갱이 수를 바꿔도 이 값을 건드리지 않는다 — 건드리면 오히려 깨진다.**
        //
        // 총질량이 개수 그 자체이므로(알갱이 하나의 질량이 1) 균형 `GM/R³` 도 개수에
        // 비례할 줄 알고 `Λ = 0.05·(n/100만)` 로 맞춰 봤다. **정반대로 갈렸다** —
        // 30만에서 안쪽 99.7%(가운데 공으로 붕괴), 200만에서 0.26%(껍질). 지수를 낮춰
        // 0.5·0.75 도 시험했지만 같은 방향으로 틀렸다:
        //
        //   지수 p    30만 안쪽(균일 배)   200만 안쪽(균일 배)   판정
        //   0.00           2.89                  1.29           둘 다 찼다 ← 이것
        //   0.50          14.74                  0.22           붕괴 / 껍질
        //   0.75          18.39                  0.12           붕괴 / 껍질
        //
        // 격자 해상도와 소프트닝을 `ApplyAutoGrid` 가 이미 개수에 맞춰 정하고 있어서,
        // **유효 중력이 질량에 정비례하지 않는다.** 고정값이 세 배 범위(30만~200만)를
        // 그대로 덮는다.
        cfg.darkEnergy = 0.05f;

        // 경계를 구면으로. 고립 경계의 기본 처리(여섯 면에서 되튐)는 우주를 정육면체로
        // 보이게 한다 — 0.47 부터 바깥 속도를 깎아 부딪히는 순간을 없앤다. 위 공이
        // 0.45 라 시작할 때는 아무도 이 선 밖에 없다.
        cfg.softBoundR = 0.47f;

        // 속도 분산은 안 쓴다. 구를 떠받치는 데는 듣지만(점유셀 58% 유지) **비리얼 평형은
        // 정의상 뭉치지도 흩어지지도 않는 상태**라 구조가 안 생긴다(밀도 2 배, 빅뱅은 83 배).
        cfg.velDispersion = 0.0f;

        // **100만으로 올린다(2026-08-20). 앞서 30만으로 내린 것은 잘못 잰 값 탓이었다.**
        //
        // 배속 8 로 성능을 재고 있었는데, 배속 3 이상이면 **한 프레임에 스텝이 3 번** 돈다.
        // 그래서 프레임 시간이 3 배로 나왔고 그것을 렌더 탓으로 읽었다. 배속 1 로 다시 재니:
        //
        //   알갱이   스텝ms  프레임ms  렌더ms  fps   판정
        //   100만    12.6    16.7     4.1    60   여유
        //   200만    23.1    25.0     1.8    40   빠듯
        //   400만    38.9    42.9     4.0    23   가드가 판을 다시 깐다
        //
        // **병목은 렌더가 아니라 스텝(중력)이고 알갱이 수에 정비례한다.** 렌더는 4 ms 다.
        cfg.particleCount = 1000000;

        // 배속 — 팽창은 10 초에 걸쳐 보이고, 구조는 3.8 분에 여문다.
        // 0.2 로 두면 팽창이 52 초로 천천히 보이지만 구조까지 19 분이 걸린다.
        cfg.timeScale = 1.0f;
    } else {
        // 빈 우주 — 눈금을 기본으로 되돌린다. 마우스로 놓은 것을 은하 눈금에서 본다.
        cfg.lengthScale   = 1.0f;
        cfg.timeUnitScale = 1.0f;
        cfg.darkMatterFraction = 0.0f;
        cfg.spin          = 0.0f;
        cfg.bigBangShrink = 0.0f;
        cfg.hubble        = 0.0f;
        cfg.darkEnergy    = 0.0f;
        cfg.softBoundR    = 0.0f;
        cfg.velDispersion = 0.0f;
        cfg.timeScale     = 1.0f;
    }
}
