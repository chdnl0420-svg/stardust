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
//    CIC 는 파티클 하나를 이웃 4칸에 가중치로 쪼개 넣으므로 가중치 합이 정확히 1 이어야 한다.
// ---------------------------------------------------------------------------
static void testMassConservation() {
    printf("\n[1] 질량 보존\n");
    for (int G : {128, 256, 512}) {
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
        cfg.gridSize = 256;
        cfg.gravity = gravity;
        cfg.pressureEnabled = false;
        cfg.preset = Preset::SpiralDisk;
        sim.init(cfg);
        for (int i = 0; i < 200; ++i) sim.step();
        return sim.measureMaxDensity();
    };
    double off = peakAfter(0.0f);
    double on  = peakAfter(0.6f);
    char buf[160];
    snprintf(buf, sizeof(buf), "중력0 최대밀도=%.1f  중력0.6 최대밀도=%.1f  비율=%.2f", off, on, on / (off > 0 ? off : 1));
    check(on > off * 1.5, "중력을 켜면 더 뭉친다", buf);
}

// ---------------------------------------------------------------------------
// 3. 힘 오차 — 격자로 푼 중력이 정답지(직접 O(N²))와 얼마나 다른가.
//    판정선 0.15 의 근거는 design.md §8 (512² 실측 0.134 에 여유를 얹은 값).
// ---------------------------------------------------------------------------
static void testForceAccuracy() {
    printf("\n[3] 격자 중력의 힘 오차 (정답지: 직접 O(N^2))\n");
    for (int G : {256, 512}) {
        Sim sim;
        double rms = sim.measureForceErrorVsDirect(20000, G, 3.0f);
        char buf[160];
        snprintf(buf, sizeof(buf), "G=%d  소프트닝=3셀  상대오차RMS=%.4f  (판정선 0.15)", G, rms);
        check(rms >= 0.0 && rms < 0.15, "힘 오차가 판정선 안에 든다", buf);
    }
}

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
    for (Case c : { Case{1000000, 1024}, Case{100000, 2048}, Case{2000000, 4096} }) {
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
    for (P e : { P{Preset::SpiralDisk,"나선팔"}, P{Preset::TidalPair,"조석꼬리"},
                 P{Preset::HeadOnShock,"충격파"}, P{Preset::CosmicWeb,"구조형성"},
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
    cfg.gridSize = 512;
    cfg.preset = Preset::SpiralDisk;
    sim.init(cfg);
    for (int i = 0; i < 20; ++i) sim.step();
    SimTimings t = sim.timings();
    char buf[200];
    snprintf(buf, sizeof(buf), "산란=%.3f FFT=%.3f 보간=%.3f 정렬=%.3f 합=%.3f ms",
             t.scatterMs, t.poissonMs, t.gatherMs, t.sortMs, t.totalMs);
    check(t.totalMs > 0.0f && t.scatterMs > 0.0f && t.poissonMs > 0.0f,
          "단계별 시간이 채워진다", buf);
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
    cfg.gridSize = 512;
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
             "질량변화=%.2e  중심이동=%.4f  서브스텝=%d  dt=%.2e  최대속력=%.2f",
             dm, dc, t.substeps, t.dtUsed, t.maxSpeed);
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
    size_t freeB = Sim::deviceFreeBytes();
    int maxN = Sim::maxParticlesFor(2048, Boundary::Isolated, freeB);

    Sim sim;
    SimConfig cfg;
    cfg.particleCount = 500000000;   // 5억 — 8GB 로는 불가능
    cfg.gridSize = 2048;
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
    cfg.gridSize = 512;
    cfg.gravity = 0.6f;
    cfg.pressureEnabled = false;
    cfg.preset = Preset::Empty;
    sim.init(cfg);

    char buf[220];
    snprintf(buf, sizeof(buf), "activeCount=%d  격자질량=%.0f", sim.activeCount(), sim.measureTotalGridMass());
    check(sim.activeCount() == 0 && sim.measureTotalGridMass() < 1.0, "빈 판은 비어 있다", buf);

    // 세 번 추가하고 매번 정확한 개수가 들어가는지 본다
    const int want = 120000;
    int got1 = sim.addShape(0.35f, 0.45f, ShapeKind::RotatingDisk, 0.10f, want, true);
    int got2 = sim.addShape(0.65f, 0.55f, ShapeKind::StaticBlob,   0.08f, want, false);
    int got3 = sim.addShape(0.50f, 0.75f, ShapeKind::GasRing,      0.09f, want, true);
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
        s2.addShape(0.5f, 0.5f, ShapeKind::RotatingDisk, 0.12f, 200000, true);
        int diskCells = s2.measureOccupiedCells();
        Sim s3; s3.init(c2);
        s3.addShape(0.5f, 0.5f, ShapeKind::GasRing, 0.12f, 200000, true);
        int ringCells = s3.measureOccupiedCells();
        snprintf(buf, sizeof(buf), "원반 점유셀=%d  고리 점유셀=%d", diskCells, ringCells);
        check(diskCells > 0 && ringCells > 0 && ringCells < diskCells,
              "형태 종류마다 배치가 다르다(고리가 더 성기다)", buf);
    }

    // 지우개 — 지운 만큼 줄고, 남은 것은 앞쪽에 모여 있어야 다음 추가가 정확하다
    int erased = sim.eraseAt(0.35f, 0.45f, 0.12f);
    int afterErase = sim.activeCount();
    int got4 = sim.addShape(0.20f, 0.20f, ShapeKind::StaticBlob, 0.05f, 50000, false);
    int afterAdd = sim.activeCount();
    snprintf(buf, sizeof(buf), "지움=%d  지운뒤=%d  다시추가=%d  최종=%d",
             erased, afterErase, got4, afterAdd);
    check(erased > 0 && afterErase == total - erased
          && got4 == 50000 && afterAdd == afterErase + 50000,
          "지운 뒤에도 추가 개수가 정확하다", buf);

    // 뿌리기·우물 — 속도가 실제로 바뀌는지 (최대속력으로 본다)
    {
        Sim s4; SimConfig c4 = cfg; c4.gravity = 0.0f; s4.init(c4);
        s4.addShape(0.5f, 0.5f, ShapeKind::StaticBlob, 0.10f, 200000, false);
        s4.step();
        float v0 = s4.timings().maxSpeed;
        s4.sprayAt(0.5f, 0.5f, 0.12f, 0.5f);
        s4.step();
        float v1 = s4.timings().maxSpeed;
        snprintf(buf, sizeof(buf), "뿌리기 전 최대속력=%.4f  후=%.4f", v0, v1);
        check(v1 > v0 + 1e-4f, "뿌리기가 속도를 준다", buf);
    }
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
    testForceAccuracy();
    testReconfigure();
    testPresets();
    testTimings();
    testCflClamp();
    testLongRun();
    testVramClamp();
    testMouseTools();

    printf("\n=== 결과: %d PASS / %d FAIL ===\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
