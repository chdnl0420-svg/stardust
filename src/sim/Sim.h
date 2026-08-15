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
    // ── 3D 로 옮기면서 달라진 값들 ────────────────────────────────────────
    //
    // 격자가 한 변이 아니라 세제곱으로 자란다. 2D 의 2048² 은 400만 칸이지만
    // 3D 의 2048³ 은 85억 칸이라 그릴 수도 잡을 수도 없다. 실제 상한은 이렇다.
    //   고립 경계 : 한 변 256 까지 (패딩 때문에 실제로는 512³ 을 잡는다)
    //   주기 경계 : 한 변 512 까지
    // 방향당 해상도는 내려가지만, 별이 위아래로 진동할 자유도가 생겨 원반이 조각나는 대신
    // 나선팔이 유지된다 — 3D 로 옮기는 이유가 그것이다.
    int   particleCount        = 2000000;
    int   gridSize             = 128;    // 2의 거듭제곱만 쓴다(주기 wrap 을 비트 마스크로 처리)

    // 원반의 두께. 실제 나선 은하의 원반은 지름에 견주면 아주 얇다(대략 1/100).
    // 이 값이 0 이면 알갱이가 한 평면에 갇혀 2D 와 같아진다.
    float diskThickness        = 0.012f;
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
    // 0.15 는 팔을 빨리 뭉갰다. 흩어짐이 크면 이웃끼리 상대속도가 커서 팔의 띠가 금세
    // 풀린다 — 팔이 자라기 전에 조각나지 않을 만큼만 남기고 줄인다(2026-08-14 실측).
    float orbitDispersion      = 0.085f;

    // ── 은하 한가운데의 별 무리(팽대부) ───────────────────────────────────
    //
    // 실제 나선 은하는 나선팔만 있는 것이 아니라 가운데에 빽빽한 공 모양 별 무리가 있다.
    // 그 무게가 중심 퍼텐셜을 깊게 만들어 원반이 안쪽으로 무너지는 것을 붙잡는다 —
    // 없으면 가운데가 텅 빈 고리처럼 보이고 원반도 덜 안정하다.
    //
    // 팽대부의 별은 원반처럼 나란히 돌지 않고 제각각 움직인다(회전보다 흩어짐이 지배적).
    // 알갱이 중 팽대부에 놓는 비율. 실제 나선 은하의 팽대부는 총 광도의 10~20% 다.
    // 0.28 로 두었더니 반지름 0.055 의 좁은 공에 28% 가 몰려, 화면에 밝은 점 하나만
    // 남고 나선팔이 그 빛에 묻혔다(2026-08-14 실측).
    float bulgeFraction        = 0.11f;
    float bulgeRadius          = 0.045f; // 그 무리의 크기

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
    // ── 나선 밀도파 ───────────────────────────────────────────────────────
    //
    // **실제 은하의 나선팔은 물질이 아니다.** 별들은 팔을 통과해 지나가고, 팔 자체는 원반과
    // 다른 속도로 도는 「무늬」다. 그래서 안쪽이 바깥쪽보다 빨리 도는데도 팔이 감겨 사라지지
    // 않는다 — 물질로 만든 팔은 반드시 감긴다(감김 문제).
    //
    // 이것을 재현하는 표준 방법은 회전하는 나선 모양의 얕은 골을 중력에 더하는 것이다.
    //   Φ(r,θ,t) = -A(r)·cos( m(θ - Ωp·t) - (m/tan i)·ln(r/r0) )
    // 별은 그 골을 지날 때 잠깐 느려지며 몰렸다가 빠져나간다. 몰린 자리가 곧 팔이고,
    // 그 자리는 Ωp 로 돌기 때문에 원반이 몇 바퀴를 돌아도 무늬가 그대로 남는다.
    //
    // 골의 깊이는 원반 중력의 몇 % 수준이면 충분하다 — 실제 은하도 그 정도다.
    bool  spiralWaveEnabled    = false;
    float spiralWaveStrength   = 0.055f;  // 원반 중력에 대한 골의 깊이
    float spiralWavePattern    = 0.42f;   // 무늬가 도는 속도 Ωp (rad / 시간)
    float spiralWavePitch      = 0.29f;   // tan(감김각). 배치에 쓰는 값과 같아야 한다

    bool  haloEnabled          = false;
    // 바깥에서 수렴하는 회전 속도. 이 값이 클수록 회전곡선이 더 평평해지고, 그만큼
    // 안팎의 도는 속도 차가 줄어 팔이 덜 감긴다 — 팔이 오래 남는 것은 대부분 이 힘 덕이다.
    float haloSpeed            = 0.78f;
    float haloCore             = 0.11f;  // 가운데 뭉툭한 부분의 크기
    float softeningCells       = 3.0f;   // 격자 셀 단위. 너무 작으면 근거리 힘이 발산한다
    float timeScale            = 1.0f;
    int   sortInterval         = 40;     // 몇 스텝마다 파티클을 셀 순서로 재배치할지(성능 전용)

    bool  pressureEnabled      = true;
    float pressureK            = 0.45f;
    float gamma                = 1.6f;

    bool  temperatureEnabled   = true;
    // 기본으로 켠다. 이것이 꺼져 있으면 **아무것도 뭉치지 않는다** — 중력으로 모이면
    // 그 자리가 데워져 도로 흩어지기만 한다. 켜면 같은 알갱이 100만이 18분의 1 넓이로
    // 모여 나선과 덩어리를 만든다(2026-08-14 실측: 최대밀도 6771 → 94483, 스텝 6.8 ms).
    bool  coolingEnabled       = true;
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
    // 마우스로 놓는 블랙홀의 무게 = 놓는 개수 × 이 값. 기본 50분의 1이다.
    //
    // 개수를 그대로 무게로 쓰던 때는 기본값(15만)만으로 판 물질의 15% 짜리 블랙홀이 생겼다.
    // 실제 은하는 중심 블랙홀이 은하 질량의 0.1% 안팎이고, 그 15% 짜리를 여럿 놓으면
    // 서로 순식간에 끌려가 합쳐지고 둘레 알갱이는 판 밖까지 튕겨 나갔다(2026-08-14 실측).
    float blackHoleMassScale   = 0.02f;

    // ── 나머지 세 가지 기본 힘 ────────────────────────────────────────────
    //
    // **이 판의 알갱이는 별과 가스다.** 핵력이 실제로 미치는 거리는 10⁻¹⁵ m 이고 여기서
    // 한 칸은 은하 규모라, 열다섯 자리가 넘게 어긋난다. 그대로 옮겨 담을 수는 없다.
    // 그래서 크기가 아니라 **거동**을 옮긴다 — 각 힘이 무엇을 하는 힘인지가 보이게.
    //
    //   강한핵력 : 아주 가까울 때만 세게 당기고, 더 붙으면 밀어낸다(핵자가 뭉치는 방식).
    //              중력과 달리 멀리 가지 않아, 붙은 것끼리만 덩어리로 굳는다.
    //   전자기력 : 알갱이마다 +/- 를 주고 같은 부호는 밀고 다른 부호는 당긴다.
    //              거리 제곱에 반비례하는 것은 중력과 같지만 **양쪽 부호가 있다**.
    //   약한핵력 : 힘이라기보다 바꿈이다. 알갱이의 부호가 이따금 뒤집힌다(베타 붕괴).
    //              그래서 전자기력을 켜 두면 굳어 있던 배치가 스스로 풀린다.
    //
    // 셋 다 접촉력이 이미 훑고 있는 이웃 위에서 계산해 값을 거의 더하지 않는다.
    bool  strongForceEnabled   = false;
    float strongForceK         = 8000.0f;
    bool  emForceEnabled       = false;
    float emForceK             = 0.004f;
    bool  weakForceEnabled     = false;
    float weakForceRate        = 0.05f;   // 한 스텝에 부호가 뒤집힐 확률의 세기

    // 위 두 힘의 감쇠 — **임계 감쇠에 대한 비율이다(1 = 임계).**
    //
    // 이 값이 세 힘이 폭주한 진짜 원인이었다. 처음에는 접촉력의 감쇠(0.35)를 그대로
    // 썼는데, 용수철 상수 k 인 진동자의 임계 감쇠는 2√k 이고 강한핵력은 k = 9600 이라
    // 필요한 값이 196 이었다 — 560분의 1을 쓴 셈이다. 감쇠가 모자란 진동자를 명시적
    // 적분으로 풀면 에너지가 매 스텝 (1+(ω·dt)²) 배로 늘어, 몇 초 만에 광속에 닿는다.
    // 1 로 두면 진동이 쌓이지 않고 부드럽게 가라앉는다.
    float newForceDamping      = 1.0f;

    // 판 전체 회전(세로축 중심 각속도). 판을 새로 열 때 얹힌다.
    //
    // 회전이 없으면 뭉친 것이 공이나 실이 된다 — 각운동량이 있어야 원반이 생긴다.
    // 다만 이것은 강체 회전이라 중심에서 멀수록 빨라진다(실제 원반은 멀수록 느리다).
    // 2.0 을 주었더니 바깥쪽이 궤도 속도를 넘어 원반이 되기 전에 흩어졌다(실측).
    float spin                 = 0.0f;

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
    Galaxy,     // 0 은하 — 나선 원반. 그 자리 중력을 재서 원 궤도가 되는 속도를 넣는다
    Sun,        // 1 태양 — 가운데로 갈수록 빽빽하다
    Ring,       // 2 고리 — 가운데가 빈 도넛
    Cloud,      // 3 구름 — 넓게 퍼진 성운
    BlackHole,  // 4 블랙홀 — 알갱이가 아니라 지평선을 세운다. 둘레의 것을 삼키며 자란다
    Saturn,     // 5 토성 — 가운데 공에 아주 얇은 고리가 둘린다
};

// 지금 판에 있는 블랙홀. 없으면 active 가 false 다.
struct BlackHoleState {
    bool  active = false;
    float x = 0.5f, y = 0.5f, z = 0.5f;  // 0~1 정규화 좌표
    // **블랙홀도 중력을 받아 움직인다.** 질량이 있으니 당연한데, 오래 고정이었다.
    // 여럿을 놓을 수 있게 되면서 이것이 중요해졌다 — 둘이 서로를 돌다 합쳐지는 것이
    // 이 장면에서 가장 볼 만한 일이고, 고정된 점 둘로는 그 일이 일어나지 않는다.
    float vx = 0.f, vy = 0.f, vz = 0.f;
    float mass = 0.f;          // 삼킨 알갱이 수(전체 대비 비율이 아니라 개수)
    float rs = 0.f;            // 지평선 반지름 — 질량에서 나온다
    bool  born = false;        // 이번 판에서 무너져 생긴 것인가(처음부터 있던 것이 아니라)
};

// 한 판에 둘 수 있는 블랙홀 수.
//
// **상한이 있어야 한다.** 적분 커널이 알갱이마다 이 수만큼 도므로 비용이 정비례한다 —
// 알갱이 400만이면 한 스텝에 3200만 번이다. 여덟은 눈으로 구분되는 만큼이면서
// 그 곱이 아직 가벼운 자리다(이 프로젝트에서 상한 없는 반복은 카드를 죽인다).
constexpr int kMaxBlackHoles = 8;

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
    // 이 드라이버가 받아 주는 CUDA 판("CUDA 13.3"). 못 읽으면 빈 문자열.
    static std::string deviceDriver();
    static size_t      deviceFreeBytes();
    // 이 카드의 멀티프로세서 수. 감당할 수 있는 알갱이 수를 어림하는 데 쓴다(못 읽으면 0).
    static int         deviceMultiProcessors();

    // 이 경계에서 격자 한 변이 가질 수 있는 최대값.
    //
    // 3D 라 세제곱으로 자란다. 고립 경계는 합성곱이 감기지 않게 한 변을 두 배로 잡으므로
    // 실제로 잡는 것은 그 여덟 배다. 밖에서 이보다 큰 값을 넣어도 reconfigure 가 잘라 낸다.
    static int         maxGridSize(Boundary boundary);

    // 이 설정으로 잡아야 할 VRAM 바이트 수. 할당하기 전에 가용량과 비교하는 데 쓴다.
    static size_t      estimateBytes(int particleCount, int gridSize, Boundary boundary);
    // 가용 VRAM 안에 들어가는 최대 파티클 수. 요청이 넘치면 이 값으로 잘라 쓴다.
    static int         maxParticlesFor(int gridSize, Boundary boundary, size_t freeBytes);

    // 이 카드의 메모리 대역폭(GB/s). 감당할 수 있는 격자를 어림하는 데 쓴다. 못 읽으면 0.
    static double      deviceBandwidthGBs();

    // 이 조합으로 한 스텝을 도는 데 드는 시간(ms) 어림.
    //
    // **메모리만으로 상한을 정하면 안 된다.** VRAM 에는 들어가지만 한 스텝이 몇백 ms 걸리는
    // 조합이 있고, 그 상태에서 알갱이가 한곳에 몰리면 커널 하나가 드라이버 타임아웃(2초)을
    // 넘겨 시스템이 재부팅된다(2026-08-14 실측: 480만 알갱이 + 256³ 격자 + 블랙홀).
    // 상한을 정하는 쪽은 메모리와 이 값을 **둘 다** 봐야 한다.
    static double      estimateStepMs(int particleCount, int gridSize, Boundary boundary);

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
    // ── 지금 우주를 파일로 남기고 되살리기 ────────────────────────────────
    //
    // 흥미로운 상태는 우연히 나온다. 저장할 수 없으면 앱을 끄는 순간 사라지고, 같은 것을
    // 다시 만들 방법이 없다 — 마우스로 만진 것은 난수 씨앗으로 재현되지 않는다.
    //
    // 담는 것은 알갱이의 위치·속도와 그것을 읽는 데 필요한 최소한의 설정뿐이다.
    // 격자는 담지 않는다 — 위치에서 다시 만들 수 있고, 128³ 이면 그 자체로 수백 MB 다.
    bool saveState(const std::string& path);
    bool loadState(const std::string& path);

    // 회전곡선 — 반지름별 평균 회전 속도.
    //
    // 은하 시뮬레이터에서 가장 먼저 보는 그래프다. 알갱이 자신의 무게만으로 도는 원반은
    // 바깥으로 갈수록 느려지는데(케플러), 보이지 않는 무게(암흑물질 헤일로)가 감싸면
    // 곡선이 평평해진다 — 실제 은하가 그렇게 관측되고, 그것이 암흑물질의 증거다.
    // 이 앱의 핵심 주장을 눈으로 확인하는 자리다.
    //
    // bins 칸으로 나눠 out[i] 에 그 고리의 평균 |회전 속도| 를 담는다. 판 한가운데를
    // 중심으로 xy 평면에서 재고, 위아래 속도는 회전과 무관하므로 세지 않는다.
    void   measureRotationCurve(float* out, int bins, float maxRadius);

    // 에너지 — 운동에너지와 그 변화를 보는 값. 계산이 새는지 감시한다.
    double measureKineticEnergy();

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

    // 지금 판에 있는 블랙홀 가운데 **가장 무거운 것**.
    //
    // 오래 「판에 하나」였던 자리라 부르는 곳이 많다(하단 막대·재는 창·제어 채널).
    // 여럿이 된 뒤에도 그 자리들이 알고 싶은 것은 대개 「지금 제일 큰 것」이므로 그대로 둔다.
    // 전부가 필요한 곳(그리기)은 아래 둘을 쓴다.
    BlackHoleState blackHole() const;
    // 지금 판에 있는 블랙홀 수(0 ~ kMaxBlackHoles).
    int            blackHoleCount() const;
    // i 번째 블랙홀. 범위를 벗어나면 active 가 false 인 것을 돌려준다.
    BlackHoleState blackHoleAt(int i) const;
    // 전부 지운다. 삼킨 알갱이가 돌아오지는 않는다.
    void           clearBlackHoles();

    // 화면에 색을 입힐 때 무엇을 기준으로 삼을지.
    // Dispersion 은 속도 분산 — 은하에서 「온도」에 해당한다.
    // 별들이 나란히 돌면 차갑고, 제각각 움직이면 뜨겁다.
    enum class Field { Density, Dispersion, Speed };

    // 렌더가 읽어 갈 격자(디바이스 포인터). gridSize()² 개의 float.
    // 온도·속도는 밀도로 가중 평균한 값이라 빈 칸은 0 이다.
    // 밀도가 아닌 것을 부르면 그 자리에서 한 번 더 뿌리므로 매 프레임 부르는 비용을 감안한다.
    const float* fieldDevicePtr(Field field);
    const float* densityDevicePtr() const;

    // 보는 방향(라디안). 좌우로 도는 각과 위아래로 기우는 각.
    // 둘 다 0 이면 위에서 곧장 내려다보던 그림 그대로이고, 그때는 회전 계산도 건너뛴다.
    void setViewAngles(float yaw, float pitch);

    // 점 렌더가 직접 읽는 파티클 버퍼. [0, activeCount()) 만 유효하다.
    //
    // 3D 로 옮기면서 float4 배열이 됐다(x, y, z, 안 씀). float3 가 아니라 float4 인 것은
    // 16 바이트 정렬이라야 카드가 한 번에 읽어 가기 때문이다 — 12 바이트는 두 번에 걸쳐 읽는다.
    // 화면은 위에서 내려다보므로 그리는 쪽은 x, y 만 쓴다.
    const float* particlePosDevicePtr() const;   // float4 배열을 float* 로 넘긴다
    const float* particleVelDevicePtr() const;
    const float* particleTempDevicePtr() const;

private:
    struct Impl;
    Impl* impl_;
};
