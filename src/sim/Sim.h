// 시뮬레이션 코어 — Core 층.
// 이 헤더는 CUDA 헤더를 노출하지 않는다(Pimpl). 그래서 Win32·ImGui 쪽 .cpp 가
// CUDA 툴체인 없이도 include 할 수 있고, 코어만 떼어 콘솔 테스트로 돌릴 수 있다.
#pragma once

#include <string>

// 초기조건 프리셋. 각 값이 파티클을 어디에 어떤 속도로 놓을지를 정한다.
enum class Preset {
    SpiralDisk,   // 회전 원반 하나 — 나선팔·막대 구조를 본다
    TidalPair,    // 두 원반이 스쳐 지나며 조석 꼬리를 만든다
    HeadOnShock,  // 두 가스 덩어리 정면충돌 — 충격파 전선을 본다
    CosmicWeb,    // 균일 난수 + 미세 요동 — 우주 거대구조가 자란다
    Empty,        // 빈 판. 마우스로 직접 만든다
};

// 판 바깥을 어떻게 다루는가.
//  Isolated : 텅 빈 우주에 홀로 떠 있다(은하 시나리오). 격자를 2배로 패딩해 푼다 — 비용 4배
//  Periodic : 반대편으로 넘어간다(우주론 표준). 가장 싸다
enum class Boundary { Isolated, Periodic };

// 2D 격자에서 어떤 중력을 재현할지.
//  InverseSquare : 3D 우주를 위에서 눌러 본 느낌(힘 ∝ 1/r²). 주파수공간에서 1/k 를 곱한다
//  InverseR      : 수학적으로 올바른 2D 중력(힘 ∝ 1/r). 1/k² 를 곱한다. 판 전체가 한 덩어리로 붕괴한다
enum class GravityLaw { InverseSquare, InverseR };

struct SimConfig {
    int   particleCount        = 1000000;
    int   gridSize             = 2048;   // 2의 거듭제곱만 쓴다(주기 wrap 을 비트 마스크로 처리)
    Preset preset              = Preset::SpiralDisk;
    Boundary boundary          = Boundary::Isolated;
    GravityLaw law             = GravityLaw::InverseSquare;

    float gravity              = 0.6f;
    float softeningCells       = 3.0f;   // 격자 셀 단위. 너무 작으면 근거리 힘이 발산한다
    float timeScale            = 1.0f;
    int   sortInterval         = 40;     // 몇 스텝마다 파티클을 셀 순서로 재배치할지(성능 전용)

    bool  pressureEnabled      = true;
    float pressureK            = 0.45f;
    float gamma                = 1.6f;

    bool  temperatureEnabled   = true;
    bool  coolingEnabled       = false;
    float coolingRate          = 0.25f;
    bool  starFormationEnabled = false;
    float starDensityThreshold = 70.0f;

    bool  expansionEnabled     = false;  // 주기 경계에서만 물리적 의미가 있다
    float hubble               = 0.3f;
};

// 한 스텝의 단계별 소요 시간(ms). 설정 보드 「성능」 섹션이 그대로 표시한다.
struct SimTimings {
    float scatterMs = 0.0f;
    float poissonMs = 0.0f;
    float gatherMs  = 0.0f;
    float sortMs    = 0.0f;
    float gasMs     = 0.0f;
    float totalMs   = 0.0f;
};

class Sim {
public:
    Sim();
    ~Sim();
    Sim(const Sim&) = delete;
    Sim& operator=(const Sim&) = delete;

    static bool        deviceAvailable();
    static std::string deviceName();
    static size_t      deviceFreeBytes();

    void init(const SimConfig& cfg);
    // 파티클 수·격자 해상도가 바뀌면 버퍼를 다시 잡고 초기조건을 새로 만든다.
    void reconfigure(const SimConfig& cfg);
    void reset();
    void step();

    const SimConfig& config() const;
    SimTimings       timings() const;
    double           simTime() const;
    int              gridSize() const;
    int              particleCount() const;

    // --- 측정 (테스트와 HUD 가 함께 쓴다) ---
    double measureTotalGridMass();
    double measureMaxDensity();
    int    measureOccupiedCells();
    // 직접 O(N²) 계산을 정답지로 놓고 격자 중력의 상대오차 RMS 를 잰다.
    // 이 호출은 독립적으로 자기 버퍼를 잡고 끝나면 반납한다(현재 상태를 건드리지 않는다).
    double measureForceErrorVsDirect(int n, int gridSize, float softeningCells);

    // 렌더가 읽어 갈 밀도 격자(디바이스 포인터). gridSize()² 개의 float.
    const float* densityDevicePtr() const;

private:
    struct Impl;
    Impl* impl_;
};
