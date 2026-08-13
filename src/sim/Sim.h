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
    BlackHole,    // 중심에 블랙홀 — 휘어진 시공간의 최단경로를 따라 돈다
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
    float starDensityThreshold = 70.0f;   // 이 밀도를 넘고
    float starTempThreshold    = 0.05f;   // 이 온도보다 차가우면 별이 된다

    bool  expansionEnabled     = false;  // 주기 경계에서만 물리적 의미가 있다
    float hubble               = 0.3f;

    // ── 블랙홀 (BlackHole 장면에서만 쓴다) ────────────────────────────────
    // 뉴턴 중력 대신 휘어진 시공간의 최단경로(측지선)를 따라가게 한다.
    // 슈바르츠실트 해의 적도면 운동을 그대로 적분하므로 아래 셋이 저절로 나온다.
    //   지평선   r = rs        : 들어가면 못 나온다(흡수한다)
    //   광자 구면 r = 1.5 rs   : 원궤도 속도가 광속이 되는 경계
    //   최소 안정 궤도 r = 3rs : 이 안쪽에는 안정된 원궤도가 없어 나선으로 떨어진다
    // 크기는 물리보다 「보이는가」로 정했다. rs 를 화면 폭의 3% 로 두면 지평선·광자 구면·
    // 최소 안정 궤도 세 원이 눈으로 구분되고, 안쪽 가장자리가 깎이는 것도 보인다.
    // 1% 로 두었더니 세 원이 한 점으로 뭉쳐 아무것도 읽을 수 없었다(실측).
    bool  blackHoleEnabled     = false;
    float blackHoleGM          = 0.008f; // 중력 세기(GM). 궤도 속도를 정한다
    float blackHoleRs          = 0.03f;  // 지평선 반지름
};

// 마우스로 추가하는 형태.
enum class ShapeKind {
    Galaxy,   // 0 은하 — 도는 원반. 그 자리 중력을 재서 원 궤도가 되는 속도를 넣는다
    Sun,      // 1 태양 — 가운데로 갈수록 빽빽하고 뜨겁다
    Ring,     // 2 고리 — 가운데가 빈 도넛
    Cloud,    // 3 구름 — 넓게 퍼진 차가운 성운
    Blob,     // 4 덩어리 — 속도 0. 그대로 무너지는 것을 본다
};

// 한 스텝의 단계별 소요 시간(ms). 설정 보드 「성능」 섹션이 그대로 표시한다.
struct SimTimings {
    float scatterMs = 0.0f;
    float poissonMs = 0.0f;
    float gatherMs  = 0.0f;
    float sortMs    = 0.0f;
    float gasMs     = 0.0f;
    float totalMs   = 0.0f;
    // CFL 클램프가 실제로 쓴 값. 요청 dt 가 너무 크면 잘리고 여러 번 나눠 돈다.
    int   substeps  = 1;
    float dtUsed    = 0.0f;
    float maxSpeed  = 0.0f;
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

    // 이 설정으로 잡아야 할 VRAM 바이트 수. 할당하기 전에 가용량과 비교하는 데 쓴다.
    static size_t      estimateBytes(int particleCount, int gridSize, Boundary boundary);
    // 가용 VRAM 안에 들어가는 최대 파티클 수. 요청이 넘치면 이 값으로 잘라 쓴다.
    static int         maxParticlesFor(int gridSize, Boundary boundary, size_t freeBytes);

    void init(const SimConfig& cfg);
    // 파티클 수·격자 해상도가 바뀌면 버퍼를 다시 잡고 초기조건을 새로 만든다.
    void reconfigure(const SimConfig& cfg);
    void reset();
    void step();

    const SimConfig& config() const;
    SimTimings       timings() const;
    double           simTime() const;

    // CUDA 가 한 번이라도 실패했는가. 실패하면 그 뒤로 스텝이 멈춰 화면이 그대로 굳는다 —
    // 왜 굳었는지 사용자가 알 수 있어야 하므로 밖에서 읽을 수 있게 연다.
    static bool        failed();
    static std::string failMessage();
    int              gridSize() const;
    int              particleCount() const;

    // --- 측정 (테스트와 HUD 가 함께 쓴다) ---
    double measureTotalGridMass();
    double measureMaxDensity();
    int    measureOccupiedCells();
    // 질량중심(0~1 정규화 좌표). 파티클이 경계로 쏠리면 총질량은 그대로여도 이 값이 움직인다.
    void   measureCentroid(double& cx, double& cy);
    // 살아 있는 파티클의 평균 온도. 냉각이 실제로 식히는지를 보는 1차 지표다.
    double measureMeanTemperature();
    // 직접 O(N²) 계산을 정답지로 놓고 격자 중력의 상대오차 RMS 를 잰다.
    // 이 호출은 독립적으로 자기 버퍼를 잡고 끝나면 반납한다(현재 상태를 건드리지 않는다).
    double measureForceErrorVsDirect(int n, int gridSize, float softeningCells);

    // --- 마우스 도구 ---
    //
    // 살아 있는 파티클은 항상 배열 앞쪽 [0, activeCount()) 에 모여 있고 그 뒤는 빈 슬롯이다.
    // 그래서 형태를 여러 번 추가해도 요청한 개수가 정확히 들어간다 — 앞에서부터 훑으며
    // 이미 쓴 구간을 건너뛰던 방식은 두 번째 추가에서 개수가 모자랐다(design.md §9-1).
    // 지우개는 지운 자리를 메우는 정리를 함께 돌려 그 불변식을 지킨다.

    // 형태를 추가하고 실제로 들어간 개수를 돌려준다(빈 슬롯이 모자라면 그만큼만).
    int  addShape(float cx, float cy, ShapeKind kind, float radius, int count, bool autoOrbit);
    // 브러시 안의 파티클을 바깥으로 밀어낸다.
    void sprayAt(float cx, float cy, float radius, float strength);
    // 브러시 안의 파티클을 가운데로 끌어당긴다.
    void wellAt(float cx, float cy, float radius, float strength);
    // 브러시 안의 파티클을 지우고 지운 개수를 돌려준다.
    int  eraseAt(float cx, float cy, float radius);
    // 살아 있는 파티클 수. 지우거나 추가하면 바뀐다.
    int  activeCount() const;
    // 별이 된 파티클 수. 별 형성이 꺼져 있으면 0.
    int  starCount() const;

    // 화면에 색을 입힐 때 무엇을 기준으로 삼을지.
    enum class Field { Density, Temperature, Speed };

    // 렌더가 읽어 갈 격자(디바이스 포인터). gridSize()² 개의 float.
    // 온도·속도는 밀도로 가중 평균한 값이라 빈 칸은 0 이다.
    // 밀도가 아닌 것을 부르면 그 자리에서 한 번 더 뿌리므로 매 프레임 부르는 비용을 감안한다.
    const float* fieldDevicePtr(Field field);
    const float* densityDevicePtr() const;

    // 점 렌더가 직접 읽는 파티클 버퍼. [0, activeCount()) 만 유효하다.
    const float* particlePosDevicePtr() const;   // float2 배열을 float* 로 넘긴다
    const float* particleVelDevicePtr() const;
    const float* particleTempDevicePtr() const;

private:
    struct Impl;
    Impl* impl_;
};
