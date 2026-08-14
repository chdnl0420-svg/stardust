// 시뮬레이션 코어 — Core 층.
// 이 헤더는 CUDA 헤더를 노출하지 않는다(Pimpl). 그래서 Win32·ImGui 쪽 .cpp 가
// CUDA 툴체인 없이도 include 할 수 있고, 코어만 떼어 콘솔 테스트로 돌릴 수 있다.
#pragma once

#include <string>

// 초기조건 프리셋. 각 값이 파티클을 어디에 어떤 속도로 놓을지를 정한다.
enum class Preset {
    SpiralDisk,   // 나선 은하 하나 — 처음부터 나선팔 모양으로 깐다
    TidalPair,    // 나선 은하 둘이 양옆에서 서로를 끌어당긴다
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
    // 원반을 깔 때 궤도 속도에 섞는 흩어짐(속도 분산). 궤도 속도에 대한 비율이다.
    //
    // 0 이면 모두가 정확히 같은 궤도로 돌아 이웃끼리 상대속도가 없고, 원반이 국소 중력에
    // 아무 저항도 못 해 나선팔이 자라기 전에 조각조각 뭉친다. 이 값이 그 자리에서
    // 압력 노릇을 해 파편화를 막고, 대신 원반을 도는 큰 무늬 — 나선팔 — 을 자라게 한다.
    // 0.25 는 팔은 잘 만들었지만 원반이 부풀어 t=0.2 만에 화면을 넘겼다(2026-08-14 실측).
    float orbitDispersion      = 0.15f;

    // ── 은하 한가운데의 별 무리(팽대부) ───────────────────────────────────
    //
    // 실제 나선 은하는 나선팔만 있는 것이 아니라 가운데에 빽빽한 공 모양 별 무리가 있다.
    // 그 무게가 중심 퍼텐셜을 깊게 만들어 원반이 안쪽으로 무너지는 것을 붙잡는다 —
    // 없으면 가운데가 텅 빈 고리처럼 보이고 원반도 덜 안정하다.
    //
    // 팽대부의 별은 원반처럼 나란히 돌지 않고 제각각 움직인다(회전보다 흩어짐이 지배적).
    float bulgeFraction        = 0.28f;  // 알갱이 중 팽대부에 놓는 비율
    float bulgeRadius          = 0.055f; // 그 무리의 크기

    // ── 보이지 않는 무게(암흑물질 헤일로) ─────────────────────────────────
    //
    // 실제 은하는 질량의 80~90% 가 눈에 안 보이는 헤일로에 있고, 그것이 원반을 감싸 붙잡는다.
    // 이게 없으면 원반은 제 무게만으로 버텨야 해서 나선팔이 자라기 전에 조각조각 부서진다.
    //
    // 헤일로가 하는 일이 곧 나선팔의 조건이다.
    //   · 회전곡선이 평평해진다 — 안팎의 도는 속도가 비슷해져 팔이 덜 감긴다
    //   · 원반이 국소 중력에 버틴다 — 파편화 대신 원반 전체를 도는 큰 무늬가 자란다
    //
    // 모양은 유사등온구를 쓴다. 가운데가 뭉툭하고 바깥에서 회전 속도가 haloSpeed 로 수렴한다.
    //   a(r) = −haloSpeed² · r⃗ / (r² + haloCore²)
    // 기본은 꺼 둔다. 켜는 것은 장면이 정한다(ApplyPresetDefaults) —
    // 여기서 켜 두면 힘을 재는 회귀 테스트가 알갱이의 중력 대신 이 배경 중력을 재게 된다.
    bool  haloEnabled          = false;
    float haloSpeed            = 0.62f;  // 바깥에서 수렴하는 회전 속도
    float haloCore             = 0.09f;  // 가운데 뭉툭한 부분의 크기
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

    // ── 알갱이끼리의 접촉 (강체) ──────────────────────────────────────────
    // 격자로 계산하는 중력만으로는 알갱이가 서로 그냥 통과한다. 격자 한 칸보다 작은 것은
    // 없는 것과 같아서, 같은 칸에 있는 둘은 서로에게 아무 힘도 주지 않기 때문이다.
    // 그래서 아무리 모여도 압축되기만 하고 덩어리가 되지 않는다.
    //
    // 겹치면 밀어내고 부딪히면 에너지를 잃게 하면, 모이다가 더 못 눌리는 지점에서 멈춘다.
    // 그 멈춘 덩어리가 소행성이고, 더 모이면 더 큰 덩어리다 — 임계값도 등급 규칙도 필요 없다.
    //
    // 반지름은 격자 칸의 절반으로 고정한다. 지름이 정확히 한 칸이라 이웃 3×3 칸만 보면
    // 부딪힐 상대를 전부 찾을 수 있고, 중력 격자를 그대로 이웃 찾기에 쓸 수 있다.
    bool  contactEnabled   = false;
    float contactStiffness = 1.0e6f;  // 겹친 만큼 밀어내는 세기
    float contactDamping   = 0.35f;   // 부딪힐 때 잃는 정도(0 완전 탄성 ~ 1 완전 비탄성)

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
    float blackHoleGM          = 0.008f; // 처음 놓는 블랙홀의 중력 세기(GM)
    // 처음 놓는 지평선 반지름. 이 값 하나가 블랙홀의 질량까지 정한다(rs = 2GM/c² 의 역).
    // 크게 잡으면 그만큼 무거운 블랙홀이 되어 원반이 통째로 빨려 든다.
    float blackHoleRs          = 0.006f;

    // ── 무너져서 블랙홀이 되는 것 ─────────────────────────────────────────
    //
    // 알갱이끼리 부딪히게 해 두면 한 칸에 한 개 남짓밖에 못 들어간다. 그런데 중력이 그것을
    // 밀어내고 훨씬 더 쌓이면, 버티던 힘이 진 것이다 — 실제 별도 그렇게 최후를 맞는다.
    // 그 자리에서 무너져 블랙홀이 된다.
    //
    // 한번 생기면 그 뒤로는 지평선 안으로 들어온 것을 삼키며 자란다. 지평선 반지름은
    // 따로 정하지 않고 삼킨 질량에서 나온다 — rs = 2·G·M / c².
    bool  collapseEnabled      = false;
    // 무너지는 문턱(평균 밀도의 몇 배).
    //
    // 접촉을 켜 두어도 뭉친 자리는 평균의 60배까지 오른다(2026-08-14 실측: 회귀 [21] 에서
    // 접촉 켠 최대 밀도 11.6, 평균 0.19). 문턱을 그 언저리에 두면 뭉치기만 해도 곧바로
    // 블랙홀이 되어 「중력이 버티는 힘을 이겼다」가 아니라 「뭉치면 블랙홀」이 된다.
    // 그 몇 곱절을 넘어야 정말로 접촉이 밀린 자리만 무너진다.
    // 400 으로 두었더니 이번에는 아무리 뭉쳐도(평균의 13배까지 갔다) 한 번도 안 생겼다 —
    // 있으나 마나 한 기능이 된다. 150 이 그 사이다.
    float collapseDensity      = 150.0f;
    // 이 우주의 광속 제곱. 지평선 크기를 정하는 값이라 눈에 보이는 크기를 여기서 조절한다.
    // 실제 광속을 쓰면 지평선이 원자보다 작아 화면에 점 하나도 안 찍힌다.
    //
    // 이 값이 곧 블랙홀이 자라는 속도이기도 하다. 지평선은 질량에 비례해 커지는데(rs = 2GM/c²),
    // 작게 잡으면 조금만 삼켜도 지평선이 크게 벌어져 그다음 스텝에 더 삼키고, 몇 초 만에
    // 판 전체를 먹는다(2026-08-14 실측: 0.5 로 두었더니 20만 개가 전부 사라져 화면이 캄캄해졌다).
    //
    // 300 이면 판의 물질을 **전부** 삼켜도 지평선이 화면 폭의 0.4% 에 그친다.
    // 실제 은하도 중심 블랙홀의 지평선은 은하 크기에 견주면 없는 것이나 마찬가지다 —
    // 질량에 비해 지평선이 크게 보이면 그건 광속을 너무 느리게 잡은 것이다.
    // 화면에서 점으로도 안 보일 만큼 작아지는 것은 그릴 때만 최소 크기를 줘서 해결한다.
    float lightSpeedSq         = 300.0f;
};

// 마우스로 추가하는 형태.
enum class ShapeKind {
    Galaxy,   // 0 은하 — 도는 원반. 그 자리 중력을 재서 원 궤도가 되는 속도를 넣는다
    Sun,      // 1 태양 — 가운데로 갈수록 빽빽하고 뜨겁다
    Ring,     // 2 고리 — 가운데가 빈 도넛
    Cloud,    // 3 구름 — 넓게 퍼진 차가운 성운
    Blob,     // 4 덩어리 — 속도 0. 그대로 무너지는 것을 본다
};

// 지금 판에 있는 블랙홀. 없으면 active 가 false 다.
struct BlackHoleState {
    bool  active = false;
    float x = 0.5f, y = 0.5f;  // 0~1 정규화 좌표
    float mass = 0.f;          // 삼킨 알갱이 수(전체 대비 비율이 아니라 개수)
    float rs = 0.f;            // 지평선 반지름 — 질량에서 나온다
    bool  born = false;        // 이번 판에서 무너져 생긴 것인가(처음부터 있던 것이 아니라)
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
    // 이 카드의 멀티프로세서 수. 감당할 수 있는 알갱이 수를 어림하는 데 쓴다(못 읽으면 0).
    static int         deviceMultiProcessors();

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

    // 지금 판에 있는 블랙홀. 화면에 지평선을 그리고 상태를 알리는 데 쓴다.
    BlackHoleState blackHole() const;

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
