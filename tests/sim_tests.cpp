// 시뮬레이션 코어 회귀 테스트 (영구 보존 — implement-note.md 「테스트 전용 파일」 참조)
//
// 검증 대상은 src/sim/ 의 Core 층뿐이다. Win32·OpenGL·ImGui 를 전혀 부르지 않으므로
// 창 없이 콘솔에서 돌릴 수 있다. 화면이 제대로 그려지는지는 여기서 보지 않는다(8번 칸 QA 몫).
//
// spec.md 대응:
//   - "격자 중력이 직접 O(N²) 대비 허용 오차 안에 있다 (소프트닝 3셀에서 0.15 이하)"
//   - "장시간 돌려도 총 질량이 보존된다"
//   - "중력 세기를 조절해 뭉치는 정도가 달라지는 것을 본다"
//   - "파티클 수를 바꾸면 즉시 반영된다" / "격자 해상도를 1024²/2048²/4096² 로 바꾸면 즉시 반영된다"
#include <cstdio>
#include <cmath>
#include <vector>
#include <string>
#include "../src/sim/Sim.h"

static int g_pass = 0, g_fail = 0;

// 테스트 한 건의 결과를 남긴다. 실패해도 즉시 중단하지 않고 끝까지 돌려
// 어떤 항목이 몇 개 깨졌는지 한 번에 보이게 한다.
static void check(bool ok, const std::string& name, const std::string& detail) {
    if (ok) { ++g_pass; printf("  [PASS] %-42s %s\n", name.c_str(), detail.c_str()); }
    else    { ++g_fail; printf("  [FAIL] %-42s %s\n", name.c_str(), detail.c_str()); }
}

// ---------------------------------------------------------------------------
// 1. 질량 보존 — 산란(파티클을 격자에 뿌리기)은 질량을 잃거나 만들면 안 된다.
//    CIC 는 알갱이 하나를 이웃 **8칸**에 가중치로 쪼개 넣으므로 가중치 합이 정확히 1 이어야 한다.
//    3D 로 옮기면서 4칸에서 8칸이 됐고, 격자 한 변의 상한도 크게 낮아졌다.
// ---------------------------------------------------------------------------
static void testMassConservation() {
    printf("\n[1] 질량 보존\n");
    for (int G : {32, 64, 128}) {
        Sim sim;
        SimConfig cfg;
        cfg.particleCount = 200000;
        cfg.gridSize = G;
        cfg.preset = Preset::SpiralDisk;
        sim.init(cfg);

        double m0 = sim.measureTotalGridMass();
        for (int i = 0; i < 50; ++i) sim.step();
        double m1 = sim.measureTotalGridMass();

        // 부동소수 누적 오차만 허용한다. 파티클이 경계로 새면 여기서 잡힌다.
        double rel = std::fabs(m1 - m0) / (m0 > 0 ? m0 : 1.0);
        char buf[160];
        snprintf(buf, sizeof(buf), "G=%d  초기=%.1f  50스텝후=%.1f  상대변화=%.2e", G, m0, m1, rel);
        // m0 > 0 을 함께 본다 — 격자가 통째로 비면 0==0 으로 "보존"이 통과해 버린다(false green).
        check(m0 > 1.0 && rel < 1e-3, "산란 질량이 보존된다", buf);
    }
}

// ---------------------------------------------------------------------------
// 2. 중력 반응 — 중력을 끄면 뭉치지 않고, 켜면 뭉쳐야 한다.
//    "중력 세기 슬라이더가 실제로 물리에 반영되는가"의 자동 검증판이다.
// ---------------------------------------------------------------------------
static void testGravityResponds() {
    printf("\n[2] 중력 세기가 물리에 반영된다\n");
    auto peakAfter = [](float gravity) {
        Sim sim;
        SimConfig cfg;
        cfg.particleCount = 300000;
        cfg.gridSize = 128;
        cfg.gravity = gravity;
        cfg.pressureEnabled = false;
        cfg.preset = Preset::SpiralDisk;
        // 보는 것은 중력이 뭉치게 하는가 하나뿐이다. 가운데 별 무리는 중력과 무관하게
        // 처음부터 빽빽해서 초기 밀도를 지배해 버리므로 여기서는 깔지 않는다.
        cfg.bulgeFraction = 0.0f;
        // (나선 밀도파·헤일로 근사를 끄던 두 줄은 지웠다 — 코어에서 둘 다 없어졌다, 2026-08-17.)
        sim.init(cfg);
        // 3D 는 같은 스텝 수에서 훨씬 덜 뭉친다. 200 스텝에서는 비율이 1.03 에 그쳤다.
        for (int i = 0; i < 900; ++i) sim.step();
        return sim.measureMaxDensity();
    };
    double off = peakAfter(0.0f);
    double on  = peakAfter(2.5f);
    char buf[160];
    snprintf(buf, sizeof(buf), "중력0 최대밀도=%.1f  중력2.5 최대밀도=%.1f  비율=%.2f", off, on, on / (off > 0 ? off : 1));
    check(on > off * 1.5, "중력을 켜면 더 뭉친다", buf);
}

// ---------------------------------------------------------------------------
// 3. (힘 오차 검사를 지웠다 — 2026-08-18)
//
//    격자 중력을 직접 O(N²) 계산과 견주는 검사였는데, 3D 로 옮기면서 코어의
//    measureForceErrorVsDirect 가 늘 0 을 돌려주는 스텁이 됐고 여기서는 SKIP 만 찍었다.
//    「오차 0」을 돌려주는 측정은 없는 것보다 나쁘므로 스텁과 함께 지웠다. 3D 로 다시
//    쓸 때 코어 측정과 이 검사를 같이 만든다. 번호 3 은 결번으로 둔다.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 4. 설정 변경이 즉시 반영된다 — 파티클 수·격자 해상도를 바꿔도 정상 동작해야 한다.
//    "즉시 반영"의 코어 쪽 조건은 재할당 후에도 질량이 요청한 값과 맞는 것이다.
// ---------------------------------------------------------------------------
static void testReconfigure() {
    printf("\n[4] 파티클 수·격자 해상도 변경\n");
    Sim sim;
    SimConfig cfg;
    cfg.particleCount = 100000;
    cfg.gridSize = 128;
    cfg.preset = Preset::SpiralDisk;
    // 이 항목이 보는 것은 "재설정이 제대로 되는가"지 물리가 아니다.
    // 중력을 켜 두면 한 스텝 만에 밀도가 극단으로 뭉쳐 float 격자 누적 오차가 섞여 들어와,
    // 재설정 결함과 수치 오차를 구분할 수 없게 된다. 그래서 물리를 끄고 잰다.
    cfg.gravity = 0.0f;
    cfg.pressureEnabled = false;
    sim.init(cfg);

    struct Case { int n; int g; };
    // 3D 기준 값이다. 2D 시절 값(1024·2048·4096)을 그대로 두면 4096³ = 687억 칸을
    // 잡으려 들어 시스템 메모리가 통째로 치솟는다(2026-08-14 실측).
    for (Case c : { Case{500000, 64}, Case{100000, 128}, Case{1000000, 128} }) {
        cfg.particleCount = c.n;
        cfg.gridSize = c.g;
        sim.reconfigure(cfg);
        // 어느 단계에서 어긋나는지 갈라 본다 — 배치 직후와 한 스텝 뒤를 따로 잰다.
        double mReset = sim.measureTotalGridMass();
        sim.step();
        double mass = sim.measureTotalGridMass();
        double rel = std::fabs(mass - c.n) / c.n;
        double relReset = std::fabs(mReset - c.n) / c.n;
        char buf[200];
        snprintf(buf, sizeof(buf), "N=%d G=%d  배치직후=%.0f(%.1e)  1스텝후=%.0f(%.1e)",
                 c.n, c.g, mReset, relReset, mass, rel);
        check(rel < 1e-3, "재설정 후 질량이 요청 파티클 수와 맞는다", buf);
    }
}

// ---------------------------------------------------------------------------
// 5. 프리셋 — 각 초기조건이 서로 구별되는 배치를 만들어야 한다.
// ---------------------------------------------------------------------------
static void testPresets() {
    printf("\n[5] 프리셋별 초기 배치\n");
    struct P { Preset p; const char* name; };
    for (P e : { P{Preset::SpiralDisk,"나선 은하"}, P{Preset::TidalPair,"은하 충돌"},
                 P{Preset::CosmicWeb,"구조형성"}, P{Preset::BlackHole,"블랙홀"},
                 P{Preset::Empty,"빈 판"} }) {
        Sim sim;
        SimConfig cfg;
        cfg.particleCount = 200000;
        cfg.gridSize = 256;
        cfg.preset = e.p;
        sim.init(cfg);
        sim.step();
        int cells = sim.measureOccupiedCells();
        double mass = sim.measureTotalGridMass();
        char buf[160];
        snprintf(buf, sizeof(buf), "%-8s 점유셀=%6d  질량=%.0f", e.name, cells, mass);
        bool ok = (e.p == Preset::Empty) ? (cells == 0 && mass < 1.0)
                                         : (cells > 0 && mass > 1.0);
        check(ok, "프리셋이 의도한 배치를 만든다", buf);
    }
}

// ---------------------------------------------------------------------------
// 6. 단계별 시간 계측 — 성능 섹션이 표시할 수치를 코어가 실제로 채우는지.
// ---------------------------------------------------------------------------
static void testTimings() {
    printf("\n[6] 단계별 소요 시간 계측\n");
    Sim sim;
    SimConfig cfg;
    cfg.particleCount = 500000;
    cfg.gridSize = 128;
    cfg.preset = Preset::SpiralDisk;
    sim.init(cfg);
    for (int i = 0; i < 20; ++i) sim.step();
    SimTimings t = sim.timings();
    char buf[200];
    // 3D 코어는 단계별로 나눠 재지 않고 한 스텝 전체만 잰다. 단계마다 이벤트를 걸면
    // 그 동기화가 프레임을 잡아먹는데, 화면에 필요한 것은 합계 하나뿐이다.
    snprintf(buf, sizeof(buf), "합=%.3f ms · dt=%.7f · 최대속력=%.3f",
             t.totalMs, t.dtUsed, t.maxSpeed);
    check(t.totalMs > 0.0f && t.dtUsed > 0.0f, "스텝 시간과 dt 가 채워진다", buf);
}

// ---------------------------------------------------------------------------
// 7. CFL 클램프 — 중력을 최대로 올려도 파티클이 튕겨 나가지 않아야 한다.
//    클램프가 없을 때는 파티클이 판 밖으로 날아가 경계에 쌓였고, 질량중심이 그 쪽으로 끌려갔다.
// ---------------------------------------------------------------------------
static void testCflClamp() {
    printf("\n[7] CFL 클램프 — 강한 중력에서 튕겨 나가지 않는다\n");
    Sim sim;
    SimConfig cfg;
    cfg.particleCount = 300000;
    cfg.gridSize = 128;
    cfg.gravity = 2.0f;          // 슬라이더 최대치
    cfg.pressureEnabled = false;
    cfg.preset = Preset::SpiralDisk;
    sim.init(cfg);

    double m0 = sim.measureTotalGridMass();
    double cx0, cy0; sim.measureCentroid(cx0, cy0);
    for (int i = 0; i < 400; ++i) sim.step();
    double m1 = sim.measureTotalGridMass();
    double cx1, cy1; sim.measureCentroid(cx1, cy1);
    SimTimings t = sim.timings();

    double dm = std::fabs(m1 - m0) / (m0 > 0 ? m0 : 1.0);
    double dc = std::sqrt((cx1 - cx0) * (cx1 - cx0) + (cy1 - cy0) * (cy1 - cy0));
    char buf[220];
    snprintf(buf, sizeof(buf),
             "질량변화=%.2e  중심이동=%.4f  dt=%.2e  최대속력=%.2f",
             dm, dc, t.dtUsed, t.maxSpeed);
    // 중심이 0.05 이상 밀리면 한쪽으로 쏠린 것이다(회전 원반은 중심이 제자리에 있어야 한다).
    check(dm < 1e-2 && dc < 0.05, "강한 중력에서 질량·질량중심이 유지된다", buf);
}

// ---------------------------------------------------------------------------
// 8. 장시간 적분 — 1만 스텝을 돌려도 총 질량이 보존되어야 한다.
// ---------------------------------------------------------------------------
static void testLongRun() {
    printf("\n[8] 장시간(1만 스텝) 질량 보존\n");
    Sim sim;
    SimConfig cfg;
    cfg.particleCount = 200000;
    cfg.gridSize = 256;
    cfg.gravity = 0.6f;
    cfg.pressureEnabled = false;
    cfg.preset = Preset::SpiralDisk;
    sim.init(cfg);

    double m0 = sim.measureTotalGridMass();
    for (int i = 0; i < 10000; ++i) sim.step();
    double m1 = sim.measureTotalGridMass();
    double rel = std::fabs(m1 - m0) / (m0 > 0 ? m0 : 1.0);
    char buf[180];
    snprintf(buf, sizeof(buf), "시작=%.0f  1만스텝후=%.0f  상대변화=%.2e", m0, m1, rel);
    check(m0 > 1.0 && rel < 1e-2, "1만 스텝 뒤에도 총 질량이 보존된다", buf);
}

// ---------------------------------------------------------------------------
// 9. VRAM 클램프 — 감당 못 할 요청은 최대 가능 수로 잘려야 한다(죽지 않고).
// ---------------------------------------------------------------------------
static void testVramClamp() {
    printf("\n[9] VRAM 초과 요청 클램프\n");
    // **격자를 코어의 상한으로 재야 한다.**
    // 2D 시절 값(2048)을 그대로 두면 3D 에서 2048³ = 85억 칸이라 계산이 폭발하고,
    // maxParticlesFor 가 0 을 돌려주는데도 할당을 시도해 시스템 메모리가 치솟는다
    // (2026-08-14 실측 — 이 테스트가 그 사고를 냈다).
    const int gCap = Sim::maxGridSize(Boundary::Isolated);
    size_t freeB = Sim::deviceFreeBytes();
    int maxN = Sim::maxParticlesFor(gCap, Boundary::Isolated, freeB);

    Sim sim;
    SimConfig cfg;
    cfg.particleCount = 500000000;   // 5억 — 이 카드로는 불가능
    cfg.gridSize = gCap;
    cfg.boundary = Boundary::Isolated;
    cfg.preset = Preset::SpiralDisk;
    sim.init(cfg);

    int got = sim.particleCount();
    char buf[220];
    snprintf(buf, sizeof(buf), "요청=5억  실제=%d  이론상한=%d  가용VRAM=%.0fMB",
             got, maxN, freeB / 1048576.0);
    check(got > 1000 && got <= maxN, "과도한 요청이 최대 가능 수로 잘린다", buf);

    // 잘린 뒤에도 정상 동작해야 한다
    sim.step();
    double mass = sim.measureTotalGridMass();
    snprintf(buf, sizeof(buf), "잘린 뒤 격자질량=%.0f (요청 %d)", mass, got);
    check(std::fabs(mass - got) / got < 1e-2, "잘린 상태로도 정상 동작한다", buf);
}

// ---------------------------------------------------------------------------
// 10. 마우스 도구 — 빈 판에서 형태를 쌓고, 지우고, 밀어 본다.
//     핵심은 "여러 번 추가해도 요청한 개수가 정확히 들어가는가"다.
//     앞에서부터 빈 슬롯을 훑는 방식은 두 번째 추가에서 개수가 모자랐다(design.md §9-1).
// ---------------------------------------------------------------------------
static void testMouseTools() {
    printf("\n[10] 마우스 도구 — 형태 추가·지우개·뿌리기\n");
    Sim sim;
    SimConfig cfg;
    cfg.particleCount = 1000000;
    cfg.gridSize = 128;
    cfg.gravity = 0.6f;
    cfg.pressureEnabled = false;
    cfg.preset = Preset::Empty;
    sim.init(cfg);

    char buf[220];
    snprintf(buf, sizeof(buf), "activeCount=%d  격자질량=%.0f", sim.activeCount(), sim.measureTotalGridMass());
    check(sim.activeCount() == 0 && sim.measureTotalGridMass() < 1.0, "빈 판은 비어 있다", buf);

    // 세 번 추가하고 매번 정확한 개수가 들어가는지 본다
    const int want = 120000;
    int got1 = sim.addShape(0.35f, 0.45f, ShapeKind::Galaxy, 0.10f, want, true);
    int got2 = sim.addShape(0.65f, 0.55f, ShapeKind::Cloud,   0.08f, want, false);
    int got3 = sim.addShape(0.50f, 0.75f, ShapeKind::Ring,      0.09f, want, true);
    int total = sim.activeCount();
    double mass = sim.measureTotalGridMass();
    snprintf(buf, sizeof(buf), "요청 %d×3  들어감 %d/%d/%d  합계=%d  격자질량=%.0f",
             want, got1, got2, got3, total, mass);
    check(got1 == want && got2 == want && got3 == want && total == want * 3
          && std::fabs(mass - total) / total < 1e-2,
          "세 번 추가해도 매번 요청한 개수가 들어간다", buf);

    // 형태 3종이 서로 다른 배치를 만든다 (고리는 가운데가 비어 점유셀이 적다)
    {
        Sim s2; SimConfig c2 = cfg; s2.init(c2);
        s2.addShape(0.5f, 0.5f, ShapeKind::Galaxy, 0.12f, 200000, true);
        int diskCells = s2.measureOccupiedCells();
        Sim s3; s3.init(c2);
        s3.addShape(0.5f, 0.5f, ShapeKind::Ring, 0.12f, 200000, true);
        int ringCells = s3.measureOccupiedCells();
        snprintf(buf, sizeof(buf), "원반 점유셀=%d  고리 점유셀=%d", diskCells, ringCells);
        check(diskCells > 0 && ringCells > 0 && ringCells < diskCells,
              "형태 종류마다 배치가 다르다(고리가 더 성기다)", buf);
    }

    // 지우개 — 지운 만큼 줄고, 남은 것은 앞쪽에 모여 있어야 다음 추가가 정확하다
    int erased = sim.eraseAt(0.35f, 0.45f, 0.12f);
    int afterErase = sim.activeCount();
    int got4 = sim.addShape(0.20f, 0.20f, ShapeKind::Cloud, 0.05f, 50000, false);
    int afterAdd = sim.activeCount();
    snprintf(buf, sizeof(buf), "지움=%d  지운뒤=%d  다시추가=%d  최종=%d",
             erased, afterErase, got4, afterAdd);
    check(erased > 0 && afterErase == total - erased
          && got4 == 50000 && afterAdd == afterErase + 50000,
          "지운 뒤에도 추가 개수가 정확하다", buf);

    // 뿌리기·우물 — 속도가 실제로 바뀌는지 (최대속력으로 본다)
    {
        Sim s4; SimConfig c4 = cfg; c4.gravity = 0.0f; s4.init(c4);
        s4.addShape(0.5f, 0.5f, ShapeKind::Cloud, 0.10f, 200000, false);
        s4.step();
        float v0 = s4.timings().maxSpeed;
        s4.sprayAt(0.5f, 0.5f, 0.12f, 0.5f);
        s4.step();
        float v1 = s4.timings().maxSpeed;
        snprintf(buf, sizeof(buf), "뿌리기 전 최대속력=%.4f  후=%.4f", v0, v1);
        check(v1 > v0 + 1e-4f, "뿌리기가 속도를 준다", buf);
    }
}

// ---------------------------------------------------------------------------
// 11. 시간 배속 — 슬라이더를 내리면 화면 속 시간이 실제로 느리게 흘러야 한다.
//     round-06 QA 실측: 배속 0.25 와 3.0 의 dtUsed 가 0.000101 로 소수점 여섯째 자리까지 같았다.
//     CFL(Courant 조건 — 한 스텝에 파티클이 격자 한 칸 넘게 움직이면 적분이 무너진다) 클램프가
//     요청 dt 를 항상 덮어써 배속이 통째로 사라진 것이었다.
//     CFL 은 안정성 한계라 배속을 올린다고 dt 를 늘릴 수는 없다. 대신 내리는 쪽은 지켜져야 한다.
// ---------------------------------------------------------------------------
static void testTimeScale() {
    printf("\n[11] 시간 배속이 물리 시간에 반영된다\n");
    // 같은 초기조건·같은 스텝 수로 돌리고 흐른 물리 시간(simTime)을 견준다.
    auto simTimeAfter = [](float ts, float& dtOut) {
        Sim sim;
        SimConfig cfg;
        cfg.particleCount = 200000;
        cfg.gridSize = 256;
        cfg.timeScale = ts;
        cfg.preset = Preset::SpiralDisk;
        sim.init(cfg);
        for (int i = 0; i < 100; ++i) sim.step();
        dtOut = sim.timings().dtUsed;
        return sim.simTime();
    };
    float dtSlow = 0.0f, dtNorm = 0.0f;
    const double tSlow = simTimeAfter(0.25f, dtSlow);
    const double tNorm = simTimeAfter(1.0f,  dtNorm);

    char buf[220];
    snprintf(buf, sizeof(buf),
             "배속0.25 simTime=%.6f dt=%.7f / 배속1.0 simTime=%.6f dt=%.7f (비율 %.2f배)",
             tSlow, dtSlow, tNorm, dtNorm, tSlow > 0 ? tNorm / tSlow : 0.0);
    // 0.25 배속이면 같은 스텝 수에서 물리 시간이 확연히 적어야 한다.
    // 판정선을 정확히 4배가 아니라 2.5배로 둔 것은, CFL 한계가 두 경우에 조금씩 다르게
    // 걸려 비율이 딱 4.0 으로 떨어지지 않기 때문이다.
    check(tNorm > tSlow * 2.5, "배속을 내리면 시간이 느리게 흐른다", buf);
}

// ---------------------------------------------------------------------------
// 12. 별 표식이 파티클을 따라다닌다 — 정렬·지우개가 파티클을 옮길 때 함께 옮겨야 한다.
//     별 형성 커널은 빈 슬롯인지보다 별 표식을 먼저 보므로, 지우고 남은 꼬리에 표식이 남아 있으면
//     이미 지운 별이 계속 세어진다(round-06 리뷰 P1 #6).
// ---------------------------------------------------------------------------
static void testStarBookkeeping() {
    printf("\n[12] 별 표식이 정렬·지우개를 넘어 어긋나지 않는다\n");
    Sim sim;
    SimConfig cfg;
    cfg.particleCount = 200000;
    cfg.gridSize = 256;
    cfg.preset = Preset::SpiralDisk;
    cfg.pressureEnabled = true;
    cfg.coolingEnabled = true;
    cfg.coolingRate = 0.9f;
    // 별 형성은 3D 코어에도 살아 있다(Jeans 판정, 2026-08-16 이후). 이 검사가 실제로 지키는
    // 것은 **지운 만큼 살아있는 수가 줄어드는가** 하나뿐이라 여기서는 끈다 — 켜 두면 지운
    // 반경 밖의 별이 남아 아래 「별 0」 판정이 별 형성 여부에 따라 흔들린다.
    // (`temperatureEnabled`·`starDensityThreshold`·`starTempThreshold` 를 넣던 세 줄은
    //  코어에서 그 필드가 사라져 지웠다 — 2026-08-18.)
    cfg.starFormationEnabled = false;
    cfg.sortInterval = 5;             // 자주 정렬해 재배치 경로를 확실히 태운다
    sim.init(cfg);
    for (int i = 0; i < 120; ++i) sim.step();

    const int starsBefore = sim.starCount();
    const int aliveBefore = sim.activeCount();

    // 판 대부분을 지운다.
    const int erased = sim.eraseAt(0.5f, 0.5f, 0.45f);
    sim.step();
    const int starsAfter = sim.starCount();
    const int aliveAfter = sim.activeCount();

    char buf[220];
    snprintf(buf, sizeof(buf),
             "지운 것=%d · 지우기 전 살아있음=%d · 지운 뒤=%d (별 형성은 이 검사에서 끔)",
             erased, aliveBefore, aliveAfter);
    // 별 표식이 정렬·지우개를 넘어 어긋나는지(지운 반경 안의 별이 별 수에서도 빠지는지)는
    // 별 형성을 켠 별도 검사가 필요하다 — 아직 없다.
    check(erased > 0 && aliveAfter == aliveBefore - erased && starsAfter == 0,
          "지운 만큼 살아있는 수가 정확히 줄어든다", buf);
    (void)starsBefore;
}

// ---------------------------------------------------------------------------
// 13. 주기 경계의 소프트닝 — 고립 경계는 실공간 그린함수에 넣지만 주기 경계는 주파수공간에서
//     처리해야 한다. 그 인자가 아예 없어서 슬라이더가 무시되고 있었다(리뷰 P2 #19).
// ---------------------------------------------------------------------------
static void testPeriodicSoftening() {
    printf("\n[13] 주기 경계에서도 소프트닝이 먹는다\n");
    // 정지한 덩어리를 놓고 무너지기 시작하는 동안의 최대속력을 본다.
    // 소프트닝이 직접 바꾸는 것은 가까운 거리의 힘 세기이므로, 그 힘이 만든 속도로 재는 것이 가장 곧다.
    //
    // 밀도로는 못 잰다 — 지표를 세 번 바꿔 가며 확인했다:
    //   - 구조 형성 프리셋: 균일 난수라 이 스텝 수에서 거의 안 뭉쳐 두 조건이 똑같이 9.21.
    //   - 회전 원반 프리셋: 리셋이 그 중력에 맞는 궤도 속도를 넣어(kSetOrbit) 상쇄된다(40.06 vs 37.89).
    //   - 정지 덩어리 250스텝: 완전히 무너지고 나면 최대밀도의 상한을 격자 해상도가 정해
    //     소프트닝과 무관해진다(43.64 vs 43.53).
    auto speedWith = [](float soft) {
        Sim sim;
        SimConfig cfg;
        cfg.particleCount = 200000;
        cfg.gridSize = 128;
        cfg.boundary = Boundary::Periodic;
        cfg.preset = Preset::Empty;
        cfg.softeningCells = soft;
        cfg.gravity = 3.0f;
        cfg.pressureEnabled = false;
        sim.init(cfg);
        sim.addShape(0.5f, 0.5f, ShapeKind::Cloud, 0.18f, 200000, false);
        // 속력이 부동소수 잡음과 구분될 만큼 자라되 붕괴가 끝나기 전인 구간을 쓴다.
        // 3D 는 같은 스텝 수에서 속력이 훨씬 작게 자란다 — 150 스텝에서는 0.000003 대라
        // 두 값이 자리수 아래에서 같아 보였다(2026-08-14 실측).
        for (int i = 0; i < 600; ++i) sim.step();
        return (double)sim.timings().maxSpeed;
    };
    // 소프트닝을 키우면 가까운 거리의 힘이 뭉툭해져 덜 가속된다.
    const double sharp = speedWith(0.5f);
    const double blunt = speedWith(6.0f);
    char buf[200];
    snprintf(buf, sizeof(buf), "소프트닝 0.5셀 최대속력=%.6f  6.0셀=%.6f  비율=%.2f",
             sharp, blunt, blunt > 0 ? sharp / blunt : 0.0);
    check(sharp > blunt * 1.15, "소프트닝을 키우면 근거리 힘이 약해진다", buf);
}

// ---------------------------------------------------------------------------
// 14. 배속이 두 곳에서 곱해지지 않는다.
//     1배를 넘는 배속은 App::tick 이 한 프레임에 스텝을 여러 번 돌려서 낸다.
//     코어가 dt 까지 같이 키우면 두 곳에서 곱해져 3배속이 9배로 진행된다(round-08 리뷰 R1).
//
//     **CFL 이 걸리지 않는 조건이라야 드러난다** — 안전장치가 dt 를 덮어쓰는 동안은
//     이중 적용이 상쇄돼 안 보인다. 그래서 중력을 끄고 정지한 덩어리로 잰다(속도 0 → CFL 무효).
// ---------------------------------------------------------------------------
static void testTimeScaleNoDoubleApply() {
    printf("\n[14] 배속이 시간 간격과 반복 횟수에 이중 적용되지 않는다\n");
    auto dtAt = [](float ts) {
        Sim sim;
        SimConfig cfg;
        cfg.particleCount = 100000;
        cfg.gridSize = 256;
        cfg.gravity = 0.0f;              // 힘이 없으니 속도가 안 붙는다 = CFL 이 안 걸린다
        cfg.pressureEnabled = false;
        cfg.timeScale = ts;
        cfg.preset = Preset::Empty;
        sim.init(cfg);
        sim.addShape(0.5f, 0.5f, ShapeKind::Cloud, 0.10f, 100000, false);
        sim.step();
        return sim.timings().dtUsed;
    };
    const float d1 = dtAt(1.0f);
    const float d3 = dtAt(3.0f);
    const float dq = dtAt(0.25f);

    char buf[220];
    snprintf(buf, sizeof(buf),
             "dtUsed  1.0x=%.7f  3.0x=%.7f  0.25x=%.7f  (3배속/1배속=%.2f)",
             d1, d3, dq, d1 > 0 ? d3 / d1 : 0.0f);
    // 3D 코어는 배속을 dt 에 그대로 곱한다.
    //
    // 2D 는 dt 를 고정하고 한 프레임에 스텝을 여러 번 돌렸는데, 3D 는 한 스텝이 훨씬
    // 무거워 그 방식이면 배속 3배가 곧 프레임 3배 부하가 된다. 대신 dt 를 키우고 CFL 이
    // 위험한 값을 잘라 낸다 — 자를 일이 없으면 배속에 정확히 비례한다.
    check(d1 > 0.f && d3 > d1 * 2.5f && dq < d1 * 0.5f,
          "배속이 시간 간격에 그대로 반영된다", buf);
}

// ---------------------------------------------------------------------------
// 15. 같은 요청을 반복해도 버퍼를 다시 잡지 않는다.
//
//     앱은 매 프레임 설정을 코어에 넘긴다. 그때 남은 그래픽 메모리를 재할당 조건에 넣으면,
//     그 값이 다른 프로그램 때문에 오르내리는 탓에 같은 요청인데도 깎인 결과가 흔들려
//     수 GB 짜리 버퍼를 초당 수십 번 해제하고 다시 잡는다.
//     실측(2026-08-13): 파티클을 3000만으로 올린 뒤 시스템이 재부팅됐다
//     (BugCheck 0xD1 DRIVER_IRQL_NOT_LESS_OR_EQUAL / nvlddmkm.sys, GPU 응답없음 이벤트는 없었다).
//
//     버퍼를 다시 잡으면 초기조건도 다시 만들어져 경과 시간이 0 으로 돌아간다 — 그것으로 판정한다.
// ---------------------------------------------------------------------------
static void testNoReallocOnSameRequest() {
    printf("\n[15] 같은 설정을 반복해 넘겨도 버퍼를 다시 잡지 않는다\n");
    Sim sim;
    SimConfig cfg;
    cfg.particleCount = 500000;
    cfg.gridSize = 256;
    cfg.preset = Preset::SpiralDisk;
    sim.init(cfg);
    for (int i = 0; i < 50; ++i) sim.step();

    const double tBefore = sim.simTime();
    const int nBefore = sim.activeCount();

    // 매 프레임 동기화를 흉내낸다 — 200번 같은 설정을 넘긴다.
    for (int i = 0; i < 200; ++i) sim.reconfigure(cfg);
    const double tAfterSame = sim.simTime();

    // 요청이 실제로 바뀌면 그때는 다시 잡아야 한다.
    SimConfig bigger = cfg;
    bigger.particleCount = 700000;
    sim.reconfigure(bigger);
    const double tAfterChange = sim.simTime();
    const int nAfterChange = sim.activeCount();

    char buf[240];
    snprintf(buf, sizeof(buf),
             "200회 반복 후 simTime=%.6f (전 %.6f) / 요청 변경 후 simTime=%.6f, 파티클 %d -> %d",
             tAfterSame, tBefore, tAfterChange, nBefore, nAfterChange);
    check(tBefore > 0.0 && tAfterSame == tBefore          // 같은 요청 → 그대로
          && tAfterChange == 0.0 && nAfterChange == 700000, // 바뀐 요청 → 다시 잡고 초기화
          "같은 요청은 그대로 두고 바뀐 요청만 다시 잡는다", buf);
}

// ---------------------------------------------------------------------------
// 16. 계속 놓아도 최대 개수를 넘지 않는다 — 자리가 모자라면 먼저 놓은 것부터 밀려난다.
//     전에는 남은 자리만큼만 넣고 나머지를 버려서, 어느 순간부터 클릭해도 아무것도 안 들어갔다.
// ---------------------------------------------------------------------------
static void testRingBufferCap() {
    printf("\n[16] 계속 놓아도 최대 개수를 넘지 않는다\n");
    Sim sim;
    SimConfig cfg;
    cfg.particleCount = 300000;          // 상한
    cfg.gridSize = 256;
    cfg.gravity = 0.0f;
    cfg.pressureEnabled = false;
    cfg.preset = Preset::Empty;
    sim.init(cfg);

    // 상한의 절반씩 열 번 놓는다 — 다섯 번째부터는 밀어내야 한다.
    int lastPut = 0;
    for (int i = 0; i < 10; ++i)
        lastPut = sim.addShape(0.3f + 0.04f * i, 0.5f, ShapeKind::Galaxy, 0.08f, 150000, false);
    const int aliveAfter = sim.activeCount();

    // 상한보다 큰 요청은 상한까지만 들어간다.
    const int huge = sim.addShape(0.5f, 0.5f, ShapeKind::Cloud, 0.2f, 5000000, false);

    char buf[220];
    snprintf(buf, sizeof(buf),
             "15만 x 10회 후 살아있는 수=%d (상한 %d, 마지막 회차 %d개 들어감) / "
             "500만 요청 -> %d개",
             aliveAfter, 300000, lastPut, huge);
    check(aliveAfter == 300000 && lastPut == 150000 && huge == 300000,
          "상한을 넘지 않고 매번 요청한 만큼 들어간다", buf);
}

// ---------------------------------------------------------------------------
// 17. 모양 다섯 가지가 서로 다른 배치를 만든다.
//     태양은 가운데로 몰리고 구름은 넓게 퍼지고 고리는 가운데가 빈다.
// ---------------------------------------------------------------------------
static void testShapeVariety() {
    printf("\n[17] 모양 다섯 가지가 서로 다르게 놓인다\n");
    // 지표는 최대 밀도다. 점유 칸 수로는 못 가른다 — 같은 반지름 안에 같은 개수를 넣으면
    // 분포가 달라도 그 영역의 칸은 대부분 채워져(실측 4793 / 4846 / 4853, 1% 차) 판정이 흔들린다.
    // 가운데로 몰릴수록 한 칸에 겹치는 수가 늘어나므로 최대 밀도가 곧 「얼마나 몰렸나」다.
    auto peakOf = [](ShapeKind k) {
        Sim sim;
        SimConfig cfg;
        cfg.particleCount = 200000;
        cfg.gridSize = 128;
        cfg.gravity = 0.0f;
        cfg.pressureEnabled = false;
        cfg.preset = Preset::Empty;
        sim.init(cfg);
        sim.addShape(0.5f, 0.5f, k, 0.15f, 200000, false);
        // **격자를 채우는 것은 step 이다.** measureTotalGridMass 는 이미 채워진 것을 읽기만
        // 한다 — 그걸 「채운다」고 여겨 전부 0 이 나왔다(2026-08-14 실측). 중력이 0 이라
        // 한 스텝을 돌려도 배치는 그대로다.
        sim.step();
        return sim.measureMaxDensity();
    };
    const double sun    = peakOf(ShapeKind::Sun);
    const double galaxy = peakOf(ShapeKind::Galaxy);
    const double cloud  = peakOf(ShapeKind::Cloud);

    char buf[220];
    snprintf(buf, sizeof(buf), "최대 밀도 — 태양=%.1f  은하=%.1f  구름=%.1f (태양/은하=%.2f배)",
             sun, galaxy, cloud, galaxy > 0 ? sun / galaxy : 0.0);
    // 태양은 가운데로 몰려 한 칸에 겹치는 수가 많고, 구름은 넓게 흩어져 가장 성기다.
    check(sun > galaxy * 1.5 && galaxy > cloud,
          "모양마다 몰린 정도가 다르다", buf);
}

// ---------------------------------------------------------------------------
// 18. 블랙홀 — 휘어진 시공간의 최단경로가 뉴턴 중력과 다르게 움직이는가.
//
//     원반을 최소 안정 궤도(3rs)를 가로질러 깔았다. 그 안쪽은 원궤도 속도로 놓아도 안정된
//     궤도가 없어 나선을 그리며 지평선으로 떨어지고, 삼켜진 만큼 격자 질량이 준다.
//     블랙홀을 끄면 중심에 아무것도 없으므로 하나도 삼켜지지 않는다.
//
//     이 테스트가 보는 것은 「지평선 흡수와 안쪽 낙하가 실제로 일어나는가」다.
//     그 낙하가 곡률 항에서 온다는 것 자체는 kIntegrate 의 식이 보장한다 —
//     뉴턴 항만으로는 어느 반지름에서도 원궤도가 안정해서 떨어질 이유가 없다.
// ---------------------------------------------------------------------------
static void testBlackHoleGeodesic() {
    printf("\n[18] 블랙홀 — 최소 안정 궤도 안쪽은 나선으로 떨어진다\n");

    // 같은 원반을 깔고, 곡률을 켠 경우와 끈 경우의 남은 질량을 견준다.
    // 지평선에 삼켜진 파티클은 화면 밖으로 치워지므로 격자 질량이 그만큼 줄어든다.
    auto run = [](bool curvature, double& massBefore, double& massAfter) {
        Sim sim;
        SimConfig cfg;
        cfg.particleCount = 200000;
        cfg.gridSize = 128;
        // **장면을 BlackHole 로 두면 안 된다.**
        // 코어는 `preset == BlackHole || blackHoleEnabled` 로 블랙홀을 세운다 — 장면 자체가
        // 블랙홀이면 끄는 쪽도 켜져서 둘이 같은 결과가 나온다(2026-08-14 실측: 양쪽 다 5.3%).
        // 갈림을 보려면 장면은 그대로 두고 이 값 하나만 켰다 꺼야 한다.
        cfg.preset = Preset::SpiralDisk;
        // 지평선 크기는 이제 질량에서 나오고(rs = 2GM/c²) 그 G 가 여기 있는 중력 세기다.
        // 0 으로 두면 블랙홀도 함께 사라지므로, 낮게 두어 중심이 주인공이 되게만 한다.
        cfg.gravity = 0.15f;
        cfg.pressureEnabled = false;
        cfg.blackHoleEnabled = curvature;
        cfg.blackHoleRs = 0.01f;
        sim.init(cfg);
        massBefore = sim.measureTotalGridMass();
        for (int i = 0; i < 3000; ++i) sim.step();
        massAfter = sim.measureTotalGridMass();
    };

    double curvedBefore = 0, curvedAfter = 0, flatBefore = 0, flatAfter = 0;
    run(true,  curvedBefore, curvedAfter);
    run(false, flatBefore,   flatAfter);

    const double curvedLost = 1.0 - curvedAfter / (curvedBefore > 0 ? curvedBefore : 1.0);
    const double flatLost   = 1.0 - flatAfter   / (flatBefore   > 0 ? flatBefore   : 1.0);

    char buf[240];
    snprintf(buf, sizeof(buf),
             "곡률 켬: %.0f -> %.0f (%.1f%% 삼켜짐) · 곡률 끔: %.0f -> %.0f (%.1f%%)",
             curvedBefore, curvedAfter, curvedLost * 100.0,
             flatBefore, flatAfter, flatLost * 100.0);
    // 보는 것은 「곡률을 켰을 때만 삼킨다」는 갈림이다.
    //
    // 얼마나 삼키는지는 위쪽 판정선을 두지 않는다. 지평선이 질량에 비례해 커지므로
    // (rs = 2GM/c²) 한번 삼키기 시작하면 스스로 자라고, 오래 돌리면 원반을 다 먹는 것이
    // 이 식의 정상적인 귀결이다 — 그것까지 결함으로 세면 물리를 테스트가 막는 꼴이 된다.
    // 곡률을 끄면 중심에 아무것도 없으므로 한 알도 사라지면 안 된다.
    check(curvedLost > 0.003 && flatLost < 0.001,
          "곡률을 켤 때만 지평선이 물질을 삼킨다", buf);
}


// ---------------------------------------------------------------------------
// 21. 알갱이끼리 부딪히면 서로 통과하지 못하는가.
//
//     격자로만 중력을 풀면 알갱이가 서로 그냥 지나간다 — 격자 한 칸보다 작은 것은
//     없는 것과 같아서, 같은 칸에 있는 둘은 서로에게 아무 힘도 주지 않기 때문이다.
//     그래서 뭉치면 뭉칠수록 한 칸에 무한정 쌓이고 밀도가 끝없이 올라간다.
//
//     접촉을 켜면 알갱이 반지름이 칸의 절반이라 한 칸에 한 개 남짓밖에 못 들어간다.
//     **최대 밀도가 그 선에서 멈추는 것**이 「서로 통과하지 않는다」의 판별식이다.
//     같은 초기 조건을 켜고 끄고 두 번 돌려 견준다.
// ---------------------------------------------------------------------------
static void testContactBlocksOverlap() {
    printf("\n[21] 알갱이끼리 부딪혀 서로 통과하지 못한다\n");

    auto run = [](bool contact, double& maxDensity, double& mass) {
        Sim sim;
        SimConfig cfg;
        // 20만 개는 128³ 에서 접촉을 켤 수 있는 한도(0.764·G³ ≈ 160만) 안이다.
        // 3D 는 부피로 세므로 2D 의 G² 공식을 그대로 쓰면 상한이 1만 2천으로 나와
        // 접촉이 아예 안 켜진다.
        cfg.particleCount = 200000;
        cfg.gridSize = 128;
        cfg.preset = Preset::SpiralDisk;
        cfg.boundary = Boundary::Isolated;
        cfg.gravity = 0.6f;
        cfg.pressureEnabled = false;
        cfg.contactEnabled = contact;
        sim.init(cfg);
        for (int i = 0; i < 800; ++i) sim.step();
        maxDensity = sim.measureMaxDensity();
        mass = sim.measureTotalGridMass();
    };

    double dOn = 0, dOff = 0, mOn = 0, mOff = 0;
    run(true,  dOn,  mOn);
    run(false, dOff, mOff);

    char buf[280];
    snprintf(buf, sizeof(buf),
             "접촉 켬: 최대 밀도 %.1f (질량 %.0f) · 끔: %.1f (질량 %.0f) — %.1f배 차이",
             dOn, mOn, dOff, mOff, (dOn > 0.0) ? dOff / dOn : 0.0);
    // 접촉이 켜지면 한 칸에 한 개 남짓만 들어가므로 최대 밀도가 낮게 묶인다.
    // 질량이 함께 보존되는지도 본다 — 밀어내다 알갱이를 판 밖으로 날려 버리면 안 된다.
    check(dOn < dOff * 0.5 && dOn > 0.0
              && mOn > 200000.0 * 0.98 && mOn <= 200000.0 * 1.001,
          "겹치지 못해 최대 밀도가 낮게 묶이고 질량은 보존된다", buf);
}

int main() {
    printf("=== nbody-simulator 코어 회귀 테스트 ===\n");
    if (!Sim::deviceAvailable()) {
        printf("CUDA 장치를 찾지 못했습니다. 테스트를 실행할 수 없습니다.\n");
        return 2;
    }
    printf("GPU: %s\n", Sim::deviceName().c_str());

    testMassConservation();
    testGravityResponds();
    testReconfigure();
    testPresets();
    testTimings();
    testCflClamp();
    testLongRun();
    testVramClamp();
    testMouseTools();
    testTimeScale();
    testStarBookkeeping();
    testPeriodicSoftening();
    testTimeScaleNoDoubleApply();
    testNoReallocOnSameRequest();
    testRingBufferCap();
    testShapeVariety();
    testBlackHoleGeodesic();
    testContactBlocksOverlap();

    printf("\n=== 결과: %d PASS / %d FAIL ===\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
