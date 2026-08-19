// 시뮬레이션 코어 구현 — Core 층. **3D**.
//
// 알갱이는 3차원으로 움직이고 화면만 위에서 내려다본다. 2D 로 풀 때는 별이 위아래로
// 진동할 자유도가 없어 원반의 면밀도가 그대로 뭉쳤고, 나선팔이 자라기 전에 조각났다.
// 그 자유도를 주는 것이 3D 로 옮기는 이유다.
//
// 한 스텝의 흐름:
//   (K스텝마다) 셀키 -> radix sort -> 재배치      : 캐시 지역성 회복. 성능 목적
//   격자 비우기 -> CIC 산란                        : 알갱이 질량을 격자 **8칸**에 나눠 담는다
//   포아송 풀기                                    : 주기면 주파수공간 -1/k², 고립이면 패딩+그린함수
//   격자 가속도 -> CIC 보간 -> 속도·위치 적분
//   (접촉 켜짐) 이웃 27칸을 훑어 겹친 것을 밀어낸다
//
// 격자가 세제곱으로 자라므로 한 변의 상한이 2D 보다 훨씬 낮다.
//   고립 경계 : 한 변 256 (패딩 때문에 실제로 512³ 을 잡는다)
//   주기 경계 : 한 변 512
//
// **커널마다 한 프레임에 몇 번 도는지를 적어 둔다.** 이 계산을 빠뜨리면 카드가 죽는다 —
// 2026-08-14 에 그리기 커널 하나가 알갱이당 625 픽셀을 칠하다 드라이버를 무너뜨렸고
// 시스템이 통째로 재부팅됐다. N=알갱이 수, G=격자 한 변, S=패딩 포함 한 변이다.
//
// 용어:
//   CIC(Cloud-In-Cell) : 알갱이 하나를 가장 가까운 격자 8칸에 거리 가중치로 나눠 담는 방식.
//   포아송 방정식       : "질량이 이렇게 분포하면 중력장이 어떻게 생기나"를 주는 식.
//   FFT                : 신호를 파동의 겹침으로 바꾸는 변환. 모든 칸이 모든 칸에 미치는
//                        영향을 한 번에 처리할 수 있다.
//   그린함수            : 점 하나가 주변에 만드는 장(場)의 모양. 밀도와 합성곱하면 전체 장이 나온다.
#include "Sim.h"
#include "StarLook.h"        // 갓 태어난 별이 먼지 고치에서 드러나는 과정(점 렌더와 공유)
#include "ViewRot.h"         // 보는 방향 — 격자 렌더와 점 렌더가 같은 값을 써야 한다
#include "app/Forensics.h"   // 사고 기록 — 코어가 쥔 값(재할당·실패)을 코어가 직접 적는다

#include <cuda_runtime.h>
#include <cufft.h>
#include <cub/cub.cuh>
// CUDA 13(CCCL 3.x)에서 cub::TransformInputIterator·CountingInputIterator 가 제거돼 thrust 쪽을 쓴다.
#include <thrust/iterator/transform_iterator.h>
#include <thrust/iterator/counting_iterator.h>

#include <cmath>
#include <cstdio>
#include <vector>

// ---------------------------------------------------------------------------
// 오류 처리 — 코어는 조용히 기본값을 돌려주지 않는다. 실패를 표시하고 상위가 알게 한다.
//
// 한 번이라도 실패하면 g_failed 를 세우고 그 뒤로는 커널을 더 띄우지 않는다.
// 할당이 실패하면 그 포인터는 null 이라 다음 커널이 null 을 건드려 드라이버가 컨텍스트를
// 통째로 버린다. 그러면 이후 모든 호출이 연쇄로 실패하고, 화면에는 "아무 일도 안 일어나는 앱"만
// 남아 원인을 못 찾는다(round-06 리뷰 P1 #7).
// ---------------------------------------------------------------------------
namespace {
bool g_failed = false;
char g_failMsg[256] = { 0 };

void markFailure(const char* what, const char* file, int line) {
    if (!g_failed) {                    // 첫 실패만 남긴다 — 뒤따르는 연쇄 실패는 원인이 아니다
        g_failed = true;
        snprintf(g_failMsg, sizeof(g_failMsg), "%s (%s:%d)", what, file, line);
        // 디스크까지 민다. CUDA 가 실패한 뒤 시스템이 죽는 일이 잦아, 이 줄이 남지 않으면
        // 「드라이버가 먼저 무너졌는지」와 「우리가 먼저 잘못했는지」를 가릴 수 없다.
        fx::mark("!! CUDA 실패: %s (%s:%d)", what, file, line);
    }
    printf("[sim] CUDA error %s:%d %s\n", file, line, what);
}
} // namespace

#define CK(x)  do { cudaError_t e_ = (x); if (e_ != cudaSuccess) {                      \
                    markFailure(cudaGetErrorString(e_), __FILE__, __LINE__); }          \
               } while (0)

#define FK(x)  do { cufftResult r_ = (x); if (r_ != CUFFT_SUCCESS) {                    \
                    char m_[64]; snprintf(m_, sizeof(m_), "cuFFT error %d", (int)r_);   \
                    markFailure(m_, __FILE__, __LINE__); }                              \
               } while (0)

namespace {

__device__ __forceinline__ unsigned pcgHash(unsigned v) {
    unsigned s = v * 747796405u + 2891336453u;
    unsigned w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
__device__ __forceinline__ float rnd01(unsigned s) {
    return pcgHash(s) * 2.3283064365386963e-10f;
}
// 평균 0, 표준편차 1 인 난수 한 쌍 중 하나. 두께·속도 분산에 쓴다.
__device__ __forceinline__ float rndNormal(unsigned s) {
    const float u1 = fmaxf(rnd01(s), 1e-7f);
    const float u2 = rnd01(s ^ 0x9E3779B9u);
    return sqrtf(-2.0f * __logf(u1)) * __cosf(6.2831853f * u2);
}

// 3D 격자 인덱스. 주기면 반대편으로 감고, 고립이면 가장자리에 붙인다.
// 한 변이 2의 거듭제곱이라 wrap 을 나눗셈 없이 비트 마스크로 처리한다.
__device__ __forceinline__ int gidx3(int x, int y, int z, int G, int S, int periodic) {
    if (periodic) { x &= (G - 1); y &= (G - 1); z &= (G - 1); }
    else          { x = min(max(x, 0), G - 1); y = min(max(y, 0), G - 1); z = min(max(z, 0), G - 1); }
    return (z * S + y) * S + x;
}

// ---------------------------------------------------------------------------
// 초기 배치
// ---------------------------------------------------------------------------

// 나선 은하의 원반 한 점.
//
// 은하는 「팔만 있는」 것이 아니다. 원반 전체에 별이 깔려 있고, 나선팔은 그 위에 얹힌
// 밀도 파동이라 팔이 배경의 두 배쯤 진할 뿐이다. 팔 위에만 점을 찍으면 팔 사이가 텅 비어
// 실제 사진과 전혀 달라 보인다 — 전에 그렇게 만들어서 국수 두 가닥처럼 나왔다.
//
// 그래서 세 가지를 겹친다.
//
//  1) 반지름 — 지수분포에서 뽑는다. 실제 원반의 표면 밀도가 exp(-r/h) 이고,
//     h(스케일 길이)는 눈에 보이는 반지름의 1/3 쯤이다.
//
//  2) 각도 — 균등하게 뽑은 각을 팔 쪽으로 당긴다. 당기는 양을 -(A/m)·sin(m(θ-ψ)) 로 두면
//     밀도가 1 + A·cos(m(θ-ψ)) 가 된다(변환의 야코비안이 그렇게 나온다). 팔은 두 개(m=2).
//     ψ 는 그 반지름에서 팔이 지나는 각이고, 로그 나선이라 ln(r) 에 비례한다.
//     실제 은하의 감김각은 10~25도다 — 여기서는 18도를 쓴다.
//
//  3) 두께 — 안쪽이 얇고 바깥으로 갈수록 두껍다. 실제 원반이 나팔처럼 벌어진다.
// 중심에서의 거리만 뽑는다. **원반과 구형이 이것을 나눠 쓴다** — 그래야 모양만 다르고
// 질량이 어떻게 퍼졌는지는 같아, 「구형으로 시작해서 원반이 되는가」를 공정하게 잰다.
__device__ __forceinline__ float galaxyRadius(float R, unsigned s) {
    // 반지름 — 표면 밀도가 exp(-r/h) 라도, **그 반지름에 있는 별의 수**는 원둘레가 곱해져
    // r·exp(-r/h) 다. 지수분포를 그대로 쓰면 중심에 과하게 몰려 팔이 안 보인다(실측).
    // r·exp(-r/h) 는 지수 둘의 합이라, 균등난수 두 개의 로그를 더하면 그 분포가 나온다.
    // 스케일 길이. 짧게 잡으면 알갱이가 중심에 몰려 정작 팔이 보이는 반지름대가 비고,
    // 화면에는 밝은 점 하나에 흐릿한 테두리만 남는다(2026-08-14 실측).
    const float h    = R * 0.42f;
    const float rMax = R * 1.6f;

    // **넘친 것을 경계에 몰아넣지 않는다 — 이것이 은하를 두르던 선이었다(2026-08-18).**
    //
    // 전에는 `if (r > rMax) r = rMax;` 한 줄이었고 주석은 「아주 먼 꼬리는 자른다」였다.
    // 그런데 클램프는 **자르는 것이 아니라 몰아넣는 것**이다 — 넘친 알갱이가 버려지지 않고
    // **정확히 같은 반지름의 원 위에 쌓인다.**
    //
    // 감마분포(k=2)의 꼬리 확률은 `(1+x)e^(-x)`, `x = rMax/h = 3.81` 이라 **10.66%** 다
    // (실측 10.74%). 알갱이 100만이면 **106,572개**가 반지름 0.48 인 한 원에 놓이고,
    // 그 원의 둘레가 15,635 픽셀이라 **픽셀당 6.8개** — 원반 안쪽 배경(픽셀당 0.074개)의
    // **92배**다. 사용자가 「바깥쪽에 라인 생기는거」로 알린 것이 이것이다.
    //
    // 절단분포를 제대로 뽑는 방법은 **버리고 다시 뽑는 것**이다. 네 번이면 남는 것이
    // `0.1066^4 = 1.29e-4` 라 100만 개에 129개, 픽셀당 0.008개라 보이지 않는다.
    // **루프 횟수가 고정이라 비용에 상한이 있다** — 이 프로젝트에서 상한 없는 반복은
    // 카드를 죽인다(CLAUDE.md 2번).
    float r = 0.f;
    unsigned rs = s ^ 0x85EBCA6Bu;        // 각도·두께와 겹치지 않는 씨앗
    for (int k = 0; k < 4; ++k) {
        const float a = rnd01(rs), b = rnd01(rs * 13u + 7u);
        r = -h * (__logf(fmaxf(a, 1e-6f)) + __logf(fmaxf(b, 1e-6f)));
        if (r <= rMax) break;
        rs = rs * 1664525u + 1013904223u; // 다음 뽑기(선형합동)
    }
    // 네 번 다 넘친 129개. 여기서는 몰려도 픽셀당 0.008개라 선이 되지 않는다.
    if (r > rMax) r = rMax;
    // 중심 쪽 하한도 같은 성격이지만 걸리는 확률이 0.06%(100만에 640개)이고 그 자리는
    // 원반에서 가장 빽빽한 곳이라 배경에 묻힌다 — 다시 뽑을 값어치가 없다.
    return fmaxf(r, R * 0.015f);
}

// **구형으로 깐다 — 원반은 결과이지 초기 조건이 아니다(2026-08-18).**
//
// 실제 은하는 ①가스가 구형으로 뭉치고 ②조금 회전하며 ③서로 부딪혀 식으면서 ④회전축
// 방향으로만 납작해져 **원반이 된다.** 이 판은 ①~④를 건너뛰고 ⑤결과부터 깔고 있었다.
// 사용자 지적: 「입자를 구형태로 깔아야될꺼같은데 지금은 2차원 원반 형태로 깔고있어서
// 문제가있어」.
//
// 이 판의 첫째 원칙과도 어긋난다 — 나선팔은 손으로 안 그리기로 했는데(그 주석: 「팔이
// 저절로 생기는지 보려고 만든 판에서 팔을 처음부터 그려 넣으면, 무엇을 확인하든 이미
// 답이 그려져 있다」) **원반 자체는 손으로 그리고 있었다.**
//
// 거리 분포는 원반과 **똑같이** 두고 방향만 구 전체에 고르게 편다. 그래야 「구형이라서
// 달라진 것」만 갈린다.
__device__ __forceinline__ float3 spherePoint(float R, unsigned s) {
    const float r = galaxyRadius(R, s);
    // 구 위에 고르게 뿌리려면 z 를 균등하게 뽑고 그 위도의 원에서 각을 뽑는다.
    const float cz = rnd01(s * 3u + 1u) * 2.0f - 1.0f;
    const float sz = sqrtf(fmaxf(1.0f - cz * cz, 0.0f));
    const float ph = rnd01(s * 7u + 5u) * 6.2831853f;
    return make_float3(r * sz * __cosf(ph), r * sz * __sinf(ph), r * cz);
}

// **공 안에 고르게** — 빅뱅의 첫 덩어리를 만드는 자리.
//
// `bulgePoint`(r = R·u²)나 `spherePoint`(은하 반지름 분포)와 **반지름 분포가 다르다.**
// 저 둘은 중심으로 몰리는데, 여기서는 밀도가 고른 공이어야 한다 — 처음부터 가운데가
// 무거우면 팽창해도 그 자리가 그대로 남아 「중심이 있는 우주」가 된다.
//
// 부피가 r³ 로 자라므로 **세제곱근**을 취해야 고르게 찬다. `u` 를 그냥 반지름으로 쓰면
// 중심이 빽빽해진다(부피가 작은 안쪽에 같은 수가 들어가므로).
__device__ __forceinline__ float3 ballPoint(float R, unsigned s) {
    const float r  = R * cbrtf(fmaxf(rnd01(s), 1e-9f));
    const float cz = rnd01(s * 3u + 1u) * 2.0f - 1.0f;     // cos θ 를 균등하게
    const float sz = sqrtf(fmaxf(1.0f - cz * cz, 0.0f));
    const float ph = rnd01(s * 7u + 5u) * 6.2831853f;
    return make_float3(r * sz * __cosf(ph), r * sz * __sinf(ph), r * cz);
}

__device__ __forceinline__ float3 diskPoint(float R, float thickness, unsigned s) {
    const float u2 = rnd01(s * 3u + 1u);
    const float r  = galaxyRadius(R, s);

    // (중심에서의 거리를 뽑는 부분은 `galaxyRadius` 로 옮겼다 — 구형 배치가 같은 것을
    //  쓴다. 경계에 몰아넣지 않고 다시 뽑는 까닭도 그 함수 주석에 있다.)

    // **각은 균등하게 둔다 — 나선팔을 손으로 그리지 않는다(2026-08-16).**
    //
    // 전에는 여기서 로그 나선 `psi = ln(r/R₀)/tanI`(감김각 16°)로 팔이 지나는 각을 잡고,
    // 각을 `-(A/2)·sin(2Δ) - (B/4)·sin(4Δ)` 만큼 당겨 밀도에 `1 + A·cos(2Δ) + B·cos(4Δ)` 를
    // 만들었다. 야코비안을 이용한 정교한 방법이었고 사진처럼 보이는 팔이 나왔다.
    //
    // **그것이 이 판에서 가장 큰 연출이었다.** 팔이 저절로 생기는지 보려고 만든 판에서
    // 팔을 처음부터 그려 넣으면, 무엇을 확인하든 이미 답이 그려져 있다.
    // `spiralWave`(회전 밀도파)를 지워도 이 배치가 남아 있으면 팔은 계속 보인다.
    //
    // 팔이 나오면 중력·냉각·압력·별의 한살이가 만든 것이고, 안 나오면 안 나오는 것이 결과다.
    const float th = u2 * 6.2831853f;

    const float sigma = thickness * (0.6f + 0.9f * r / R);
    const float z = rndNormal(s ^ 0x2545F491u) * sigma;
    return make_float3(r * __cosf(th), r * __sinf(th), z);
}

// 팽대부의 한 점 — 가운데가 빽빽한 공. r = R·u² 로 중심에 몰아 넣는다.
__device__ __forceinline__ float3 bulgePoint(float R, unsigned seed) {
    const float u = rnd01(seed);
    const float r = R * u * u;
    // 구 위에 고르게 뿌리려면 z 를 균등하게 뽑고 그 위도의 원에서 각을 뽑는다.
    const float cz = rnd01(seed * 3u + 1u) * 2.0f - 1.0f;
    const float sz = sqrtf(fmaxf(1.0f - cz * cz, 0.0f));
    const float ph = rnd01(seed * 7u + 5u) * 6.2831853f;
    return make_float3(r * sz * __cosf(ph), r * sz * __sinf(ph), r * cz);
}

// 은하주변물질(CGM) — 원반을 감싼 가스 저장고의 자리.
//
// `bulgePoint` 와 다른 점은 **반지름 분포**다. 팽대부는 `r = R·u²` 라 중심에 몰리는데,
// CGM 은 반대로 **바깥까지 넓게 퍼져 있어야** 원반이 다 쓴 뒤에도 공급이 이어진다.
//
// 관측된 CGM 밀도는 대략 `ρ ∝ r^-1.5` 다. 그러면 반지름 r 안에 든 질량이 `M(r) ∝ r^1.5`
// 이고, 이것을 뒤집으면 `r = R·u^(2/3)` 이 나온다 — 균등난수 하나로 그 분포가 그대로 된다.
//
// 안쪽 하한을 둔다. 원반이 이미 차지한 자리에 겹쳐 놓으면 저장고가 아니라 그냥 원반이
// 두꺼워지는 것이 되고, 떨어져 들어오는 것을 잴 수도 없다.
__device__ __forceinline__ float3 haloGasPoint(float rMin, float rMax, unsigned seed) {
    const float u = rnd01(seed);
    const float r = rMin + (rMax - rMin) * __powf(fmaxf(u, 1e-6f), 0.6667f);
    // 구 위에 고르게 뿌린다(bulgePoint 와 같은 방법).
    const float cz = rnd01(seed * 3u + 1u) * 2.0f - 1.0f;
    const float sz = sqrtf(fmaxf(1.0f - cz * cz, 0.0f));
    const float ph = rnd01(seed * 7u + 5u) * 6.2831853f;
    return make_float3(r * sz * __cosf(ph), r * sz * __sinf(ph), r * cz);
}

// CGM 가스가 원반에 견줘 얼마나 느리게 도는가.
//
// **각운동량이 모자라야 떨어진다.** 1.0 이면 원 궤도라 영원히 그 자리를 돌고, 0 이면
// 곧장 자유낙하한다. 실제 은하 헤일로의 가스는 원반보다 느리게 도는 것이 관측돼 있고
// (lagging halo), 그래서 나선을 그리며 안쪽으로 들어온다.
//
// 0.5 는 각운동량이 절반이라는 뜻이고, 그러면 근일점이 처음 반지름의 1/4 언저리까지
// 내려와 원반과 만난다. 거기서 압력(속도 분산)과 부딪혀 각운동량을 더 잃고 정착한다.
__device__ __constant__ float kHaloGasSpin = 0.5f;

// 알갱이가 CGM 가스로 뽑혔는가. **`kPlace` 와 `kSetOrbit` 이 같은 답을 내야 한다** —
// 자리는 `kPlace` 가 놓고 속도는 `kSetOrbit` 이 주는데, 둘이 다른 알갱이를 고르면
// 원반에 있는 것이 느리게 돌거나 헤일로에 있는 것이 원 궤도를 받는다.
//
// 표시를 따로 두지 않고 **알갱이 번호에서 같은 해시**를 뽑는다. 그 사이(배치 → 전하 →
// 궤도)에 정렬이 없어 번호가 그대로라 안전하다.
__device__ __forceinline__ bool isHaloGas(unsigned s, float frac) {
    return frac > 0.f && rnd01(s * 17u + 3u) < frac;
}

// 알갱이를 처음 놓는다.
//
// 비용: N 스레드 × O(1). 한 프레임이 아니라 판을 새로 깔 때 한 번만 돈다.
__global__ void kPlace(float4* pos, float4* vel, int n, int preset,
                       float bulgeFrac, float bulgeR, float thickness, unsigned seed,
                       float darkFrac, float haloGasFrac, float sphereFrac,
                       float bigBangShrink) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const unsigned s = (unsigned)i * 2654435761u + seed;
    const float u1 = rnd01(s), u2 = rnd01(s * 3u + 1u), u3 = rnd01(s * 7u + 5u);
    float x = 0.5f, y = 0.5f, z = 0.5f;
    // `vel.w` 표시. 0 이면 보통 물질, -100 이면 암흑물질이다. **마지막 줄에서 한 번만
    // 쓴다** — 중간에 `vel[i]` 를 써 두면 끝에서 통째로 덮어써 표시가 지워진다.
    float velW = 0.f;

    // ── 암흑물질 ────────────────────────────────────────────────────────────
    //
    // **중력만 주고받고 빛과는 아무 상호작용을 하지 않는 물질.** 은하 회전곡선이 바깥에서
    // 안 떨어지는 것이 그 존재의 첫 증거였다 — 보이는 별만으로는 바깥 별이 그렇게 빨리
    // 돌 수 없다.
    //
    // **넓은 구형 헤일로로 깐다.** 실제 암흑물질이 원반이 아니라 공 모양으로 퍼져 있는
    // 이유는 **서로 부딪히지 않아 에너지를 잃지 못하기 때문**이다. 보통 물질은 부딪혀
    // 식으며 납작해지지만(그래서 원반 은하가 있다) 암흑물질은 그 길이 없다.
    // 그 성질을 이 판에서도 지킨다 — 아래 커널들이 `vel.w < -50` 을 보고 식히기와
    // 압력에서 빼고, 별도 안 된다.
    //
    // **표시를 `vel.w` 에 둔다.** 알갱이 번호로 가르면 정렬이 재배치하는 순간 뒤섞인다
    // (`kReorder` 는 `float4` 를 통째로 옮기므로 `vel.w` 는 알갱이를 따라간다).
    if (darkFrac > 0.f && rnd01(s * 13u + 7u) < darkFrac) {
        if (preset == 1) {
            // **필라멘트 장면에서는 헤일로가 아니라 판 전체에 고르게 깐다.**
            // 여기서는 은하 하나가 주인공이 아니라 **판 전체가 우주 한 조각**이라,
            // 가운데로 모으면 그 순간 「중심이 있는 우주」가 되어 필라멘트가 아니라
            // 공 하나가 자란다. 자리는 아래 필라멘트 분기와 **같은 변위**를 받아야
            // 보통 물질과 같은 씨앗에서 함께 자란다 — 그래서 여기서 끝내지 않고
            // 표시만 남긴 뒤 아래로 흘려보낸다.
            velW = -100.f;                                 // -100 = 암흑물질
        } else {
            // 헤일로는 원반보다 훨씬 크다(실제로도 광학 반지름의 수 배까지 뻗는다).
            const float3 h = bulgePoint(0.42f, s ^ 0x2545F491u);
            pos[i] = make_float4(0.5f + h.x, 0.5f + h.y, 0.5f + h.z, 0.f);
            vel[i] = make_float4(0.f, 0.f, 0.f, -100.f);   // -100 = 암흑물질
            return;
        }
    }

    // ── 은하주변물질(CGM) — 원반이 다 쓰고 나면 채워 줄 가스 저장고 ──────────────
    //
    // **이것이 없어서 은하가 한 번 쓰고 말랐다.** 별의 99.7% 는 수명이 우주 나이보다
    // 길어 가스로 안 돌아오므로, 밖에서 받지 않으면 원반 가스는 한 번 쓰면 끝이다
    // (근거와 실측은 `SimConfig::haloGasFraction` 주석).
    //
    // **구형으로 둔다.** 원반은 두께 0.02 로 납작하니, 같은 반지름이라도 구에 뿌리면
    // 대부분이 원반 위아래의 빈 공간에 놓인다. 실제 CGM 도 원반이 아니라 구형 헤일로다.
    // 판이 [0,1] 이고 중심이 0.5 라 반지름 상한은 0.45 다(0.5+0.45=0.95, 벽에 안 닿는다).
    //
    // 속도는 여기서 0 으로 두고 `kSetOrbit` 이 **느린 회전**을 준다 — 그 느림이
    // 「떨어져 들어온다」의 전부다. 표시를 남기지 않고 같은 해시(`isHaloGas`)로 고른다.
    //
    // 나선 장면에만 둔다. 필라멘트·빈 판은 원반 하나가 주인공이 아니라
    // 저장고라는 개념이 성립하지 않는다.
    if (preset == 0 && isHaloGas(s, haloGasFrac)) {
        const float3 h = haloGasPoint(0.15f, 0.45f, s ^ 0x7FEB352Du);
        pos[i] = make_float4(0.5f + h.x, 0.5f + h.y, 0.5f + h.z, 0.f);
        vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);      // 가스다 — 나이 0, 별이 될 수 있다
        return;
    }

    if (preset == 0) {                           // 나선 은하
        const float R = 0.30f;
        if (u3 < bulgeFrac) {
            const float3 b = bulgePoint(bulgeR, s ^ 0x51ED2701u);
            x = 0.5f + b.x; y = 0.5f + b.y; z = 0.5f + b.z;
        } else if (sphereFrac > 0.f && rnd01(s * 23u + 11u) < sphereFrac) {
            // **구형으로 깐다** — 원반은 결과여야지 초기 조건이면 안 된다(`spherePoint`).
            // 거리 분포는 원반과 같고 방향만 구에 고르게 편다.
            const float3 p = spherePoint(R, s ^ 0x9E3779B9u);
            x = 0.5f + p.x; y = 0.5f + p.y; z = 0.5f + p.z;
        } else {
            const float3 p = diskPoint(R, thickness, s ^ 0x9E3779B9u);
            x = 0.5f + p.x; y = 0.5f + p.y; z = 0.5f + p.z;
        }
    } else if (preset == 1) {                    // 우주 필라멘트 — 고르게 깔고 씨앗을 심는다
        // **공 안에 고르게 깐다.** 큐브로 깔면 접었을 때 정육면체 덩어리가 보이고,
        // 팽창해도 모서리 방향이 한동안 남는다 — 빅뱅에 모서리는 없다.
        // 반지름 0.5 로 깔아 판에 꽉 채우고, 아래에서 `bigBangShrink` 로 접는다.
        const float3 b = ballPoint(0.5f, s ^ 0x6C8E9CF5u);
        x = 0.5f + b.x; y = 0.5f + b.y; z = 0.5f + b.z;

        // **알갱이를 밀어 밀도 요동을 만든다.**
        //
        // 균등하게 뿌린 위에 작은 사인파를 더하는 것만으로는 밀도가 거의 균등해서 아무것도
        // 자라지 않는다(2026-08-14 실측: 판이 끝까지 밋밋했다). 실제 우주론 계산이 쓰는
        // 방법은 알갱이를 **위치에 따라 밀어내는** 것이다 — 미는 양이 자리마다 다르면
        // 밀려 온 곳은 빽빽해지고 밀려 나간 곳은 성겨진다. 그것이 중력이 자랄 씨앗이 된다.
        //
        // 파장을 셋 겹쳐 한 방향으로만 줄무늬가 지지 않게 한다.
        // 미는 양이 크면 그만큼 처음부터 뚜렷한 벽과 빈 공간이 생긴다. 0.055 로는 판이
        // 끝까지 밋밋했다 — 실제 우주론 계산도 처음 요동이 너무 작으면 구조가 자라는 데
        // 우주 나이만큼이 걸린다. 눈으로 볼 시간 안에 자라도록 크게 준다.
        const float tau = 6.2831853f;
        float dx = 0.f, dy = 0.f, dz = 0.f;
        for (int m = 0; m < 3; ++m) {
            const float k = tau * (2.0f + (float)m * 2.0f);   // 파장 넷·여섯·여덟 조각
            const float amp = 0.16f / (1.0f + (float)m);      // 긴 파장이 더 크다
            dx += amp * __sinf(k * (y + 0.13f * (float)m)) * __cosf(k * (z + 0.29f));
            dy += amp * __sinf(k * (z + 0.19f * (float)m)) * __cosf(k * (x + 0.37f));
            dz += amp * __sinf(k * (x + 0.23f * (float)m)) * __cosf(k * (y + 0.11f));
        }
        x += dx; y += dy; z += dz;

        // 구 밖으로 밀려 나간 것은 **표면에 붙인다.** 예전처럼 반대편으로 감으면
        // (`x -= floorf(x)`) 한쪽 끝의 알갱이가 반대쪽에 나타나 **구가 깨진다** —
        // 그것은 판이 주기 경계였을 때의 처리다. 지금은 고립 경계이고 모양이 공이다.
        {
            const float rx = x - 0.5f, ry = y - 0.5f, rz = z - 0.5f;
            const float rr = sqrtf(rx * rx + ry * ry + rz * rz);
            if (rr > 0.5f) {
                const float k = 0.5f / rr;
                x = 0.5f + rx * k; y = 0.5f + ry * k; z = 0.5f + rz * k;
            }
        }

        // ── 빅뱅 — 방금 만든 무늬를 통째로 접어 한 덩어리로 모은다 ──────────────
        //
        // **무늬는 그대로 두고 좌표만 줄인다.** 그래서 팽창이 시작되면 접기 전 구조가
        // 그대로 커진다 — 요동을 새로 만드는 것이 아니라 **이미 있는 요동이 자란다.**
        // 실제 우주론이 초기 요동을 팽창시키는 것과 같은 짜임이고, 그래서 「빅뱅처럼
        // 퍼지면서 필라멘트가 생긴다」가 연출이 아니라 결과가 된다.
        if (bigBangShrink > 0.f) {
            x = 0.5f + (x - 0.5f) * bigBangShrink;
            y = 0.5f + (y - 0.5f) * bigBangShrink;
            z = 0.5f + (z - 0.5f) * bigBangShrink;
        }
    } else {                                     // 빈 판
        pos[i] = make_float4(-1.f, -1.f, -1.f, 0.f);
        vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
        return;
    }

    pos[i] = make_float4(x, y, z, 0.f);
    vel[i] = make_float4(0.f, 0.f, 0.f, velW);
    // `temp`(지금은 전자기력의 전하 배열)는 여기서 건드리지 않는다 — reset() 이 이 커널
    // 직후 `kInitCharge` 로 전체를 ±1 로 깐다. 온도 배열이던 시절의 0.02 쓰기는 지웠다.
}

// 격자 중력을 한 번 푼 뒤, 그 자리에서 원 궤도가 되는 속도를 넣는다.
//
// 속도를 임의로 정하면 원반이 흩어진다 — 그 자리 중력이 얼마인지 재서 정해야 한다.
// 회전은 xy 평면에서 일어난다(원반의 축이 z 다).
//
// 비용: N 스레드 × O(1). 판을 깔 때 한 번.
__global__ void kSetOrbit(float4* vel, const float4* pos,
                          const float* accMag, int n,
                          float bulgeR, float2 base, float thickness,
                          unsigned seed, float haloGasFrac, float diskDisp,
                          float diskSpinLag) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;

    const float dx = p.x - 0.5f, dy = p.y - 0.5f;
    const float r = sqrtf(dx * dx + dy * dy);
    // **`w` 를 0 으로 덮지 않는다** — 거기에 나이·잔해 종류·암흑물질 표시가 들어 있다.
    const float keepW = vel[i].w;
    if (r < 1e-5f) { vel[i] = make_float4(base.x, base.y, 0.f, keepW); return; }

    // a = v²/r 에서 v = √(a·r). accMag 는 그 자리에서 잰 중심 방향 가속도 크기다.
    const float v = sqrtf(fmaxf(accMag[i], 0.f) * r);

    // 팽대부에 가까울수록 회전보다 흩어짐이 지배한다 — 실제 은하의 중심부가 그렇다.
    //
    // **원반에도 태어날 때의 속도 분산을 준다(2026-08-19, `diskDisp`).**
    //
    // 전에는 원반 쪽 흩어짐을 0 으로 두고 「압력이 그 일을 한다」고 적었다. 그런데 나선팔
    // 시도 9회가 전부 m=2 요동으로 실패했고, 마지막 시도(별을 냉각·압력에서 뺀 것)가 Q 를
    // 0.05→0.14 로 올리긴 했으나 실제 나선은하(1~2)의 1/10 에 머물렀다. 원반이 **태어날
    // 때부터 완벽한 원운동**이라 Q 가 0 에서 출발하고, 별은 부딪히지 않아 뜨거워질 길이 없다.
    //
    // 실제 별은 가스 구름의 난류를 물려받아 태어날 때부터 속도 분산을 갖는다 — 얇은 원반
    // 별의 분산이 회전 속도의 10~20% 다. 그것이 곧 「Q 가 1 근처인 원반」의 초기 조건이고,
    // 이 판에는 그것이 없었다. 연출이 아니라 빠져 있던 초기 조건이다.
    //
    // 팽대부 몫(0.85·bulgeMix)과 합쳐 하나의 `disp` 로 쓴다 — 아래 `g1·v·disp` 통로가 이미
    // 있어 식이 안 바뀐다.
    const float bulgeMix = (bulgeR > 0.f) ? __expf(-(r * r) / (bulgeR * bulgeR)) : 0.f;
    const float disp = 0.85f * bulgeMix + diskDisp * (1.0f - bulgeMix);
    // **분산을 준 만큼 회전을 덜 준다 — 비대칭 흐름(asymmetric drift).**
    //
    // 실제 별 원반은 원 궤도 속도로 돌지 않는다. 속도 분산이 있으면 그 압력이 중력의
    // 일부를 대신 버티므로, 평형을 이루는 회전 속도는 원 궤도보다 느리다(우리 은하
    // 태양 근처에서 10~15%). 시도 10 은 분산(0.15)을 주면서 회전은 원 궤도 그대로 두어
    // **과잉 지지** — 회전과 압력이 둘 다 중력을 버텨 원반이 바깥으로 부풀었다가 되돌아
    // 오는 진동을 시작했고, 그것이 m=2 요동의 씨앗이 됐을 수 있다.
    //
    // 원반 몫(1−bulgeMix)에만 건다. 팽대부는 원래 회전이 아니라 분산으로 지지된다.
    float spin = (1.0f - 0.55f * bulgeMix) * (1.0f - diskSpinLag * (1.0f - bulgeMix));

    // **CGM 가스는 원반보다 느리게 돈다 — 그래서 떨어져 들어온다.**
    //
    // 원 궤도 속도를 그대로 주면 각운동량이 딱 맞아 그 반지름을 영원히 돈다. 그러면
    // 저장고가 있어도 원반에 닿지 않아 아무 공급이 안 된다. 각운동량을 덜 주면 근일점이
    // 안쪽으로 내려와 원반과 만나고, 거기서 압력에 부딪혀 정착한다.
    //
    // 실제 은하 헤일로의 가스도 원반보다 느리게 도는 것이 관측돼 있다(lagging halo).
    // **자리를 놓은 `kPlace` 와 같은 해시를 쓴다** — 둘이 다른 알갱이를 고르면 원반에
    // 있는 것이 느려지거나 헤일로에 있는 것이 원 궤도를 받는다.
    if (isHaloGas((unsigned)i * 2654435761u + seed, haloGasFrac)) spin *= kHaloGasSpin;

    const unsigned s = (unsigned)i * 22695477u + 7u;
    const float g1 = rndNormal(s), g2 = rndNormal(s ^ 0xA341316Cu), g3 = rndNormal(s ^ 0x1B873593u);

    // 위아래 속도는 원반 두께에 맞춘다. 두께에 견줘 너무 빠르면 원반이 부풀어 사라진다.
    const float vz = g3 * v * fminf(thickness * 8.0f, 0.35f);
    vel[i] = make_float4(-dy / r * v * spin + g1 * v * disp + base.x,
                          dx / r * v * spin + g2 * v * disp + base.y,
                          vz, keepW);
}

// ---------------------------------------------------------------------------
// 격자
// ---------------------------------------------------------------------------

__global__ void kClearF(float* a, int n) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) a[i] = 0.f;
}
__global__ void kClearF4(float4* a, int n) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) a[i] = make_float4(0.f, 0.f, 0.f, 0.f);
}
__global__ void kFillInt(int* a, int n, int v) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) a[i] = v;
}

// CIC 산란 — 알갱이 하나를 이웃 **8칸**에 거리 가중치로 나눠 담는다.
//
// 비용: N 스레드 × 8 atomicAdd = 8N. N=200만이면 1600만 회.
__global__ void kScatter(const float4* pos, int n, float* grid, int G, int S, int periodic) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;

    const float gx = p.x * G - 0.5f, gy = p.y * G - 0.5f, gz = p.z * G - 0.5f;
    const int ix = (int)floorf(gx), iy = (int)floorf(gy), iz = (int)floorf(gz);
    const float fx = gx - ix, fy = gy - iy, fz = gz - iz;

    for (int k = 0; k < 8; ++k) {
        const int ox = k & 1, oy = (k >> 1) & 1, oz = (k >> 2) & 1;
        const float w = (ox ? fx : 1.f - fx) * (oy ? fy : 1.f - fy) * (oz ? fz : 1.f - fz);
        // 고립 경계에서는 범위 밖 가중치를 버리지 않고 가장자리 칸에 얹는다.
        // 버리면 판 끝에 붙은 알갱이의 질량 일부가 사라진다 — 적분기가 알갱이를 판 안에
        // 붙잡아 두므로 질량도 판 안에 남아 있어야 앞뒤가 맞는다.
        atomicAdd(&grid[gidx3(ix + ox, iy + oy, iz + oz, G, S, periodic)], w);
    }
}

// 주기 경계용 주파수공간 커널. 3D 에서 뉴턴 중력은 -1/k² 다.
//
// 2D 판에서는 1/k 를 곱해 3D 형 1/r² 힘을 흉내 냈지만, 진짜 3D 에서는 그럴 필요가 없다.
//
// 비용: (G/2+1)·G² 스레드 × O(1).
__global__ void kPoissonPeriodic(cufftComplex* F, int G, float scale, float softCells) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = blockIdx.z * blockDim.z + threadIdx.z;
    const int H = G / 2 + 1;
    if (x >= H || y >= G || z >= G) return;

    const int ky = (y <= G / 2) ? y : y - G;
    const int kz = (z <= G / 2) ? z : z - G;
    const float k2 = (float)(x * x + ky * ky + kz * kz);
    const int idx = (z * G + y) * H + x;
    if (k2 < 1e-6f) { F[idx].x = 0.f; F[idx].y = 0.f; return; }   // 평균값은 힘에 기여하지 않는다

    // **소프트닝은 여기서 넣는다.**
    //
    // 고립 경계는 실공간 그린함수에 `-1/(r + soft)` 로 넣지만, 주기 경계는 주파수공간에서
    // 곱하므로 따로 실어야 한다. 이 항을 빠뜨리면 소프트닝 슬라이더가 주기 경계에서 아무
    // 일도 하지 않는다 — 0.5 셀과 6 셀의 결과가 소수점 아래까지 같았다(2026-08-14 실측).
    //
    // 짧은 파장(큰 k)일수록 세게 누르는 가우시안을 쓴다. 실공간에서 점을 그만한 폭으로
    // 번지게 하는 것과 같아, 가까이 붙은 알갱이가 무한대로 당기는 것을 막는다.
    float m = -scale / k2;
    if (softCells > 0.f) {
        // k 는 정수 파수라 실제 파수는 2π·k/L(L=1). 셀 크기는 1/G 이므로
        // 소프트닝 길이는 softCells/G 이고, 지수는 -(2π k · soft/G)²/2 가 된다.
        const float s = 6.2831853f * softCells / (float)G;
        m *= __expf(-0.5f * k2 * s * s);
    }
    F[idx].x *= m; F[idx].y *= m;
}

// 고립 경계용 그린함수를 실공간에 만든다. g(r) = -1/r, 아주 가까운 곳은 소프트닝으로 막는다.
// 패딩 격자의 네 귀퉁이(각 축의 양끝)에서 거리를 재야 합성곱이 순환하지 않는다.
//
// 비용: S³ 스레드 × O(1). S=2G. 판을 깔 때 한 번만 돈다.
__global__ void kGreen(float* g, int S, int G, float soft) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= S || y >= S || z >= S) return;
    const int dx = (x <= S / 2) ? x : S - x;
    const int dy = (y <= S / 2) ? y : S - y;
    const int dz = (z <= S / 2) ? z : S - z;
    const float r = sqrtf((float)(dx * dx + dy * dy + dz * dz)) + soft;
    g[(z * S + y) * S + x] = -1.0f / r;
}

// 두 주파수공간 배열을 곱한다(합성곱). 배율은 FFT 정규화까지 함께 실는다.
//
// 비용: (S/2+1)·S² 스레드 × O(1).
__global__ void kMulSpec(cufftComplex* a, const cufftComplex* b, int n, float scale) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const cufftComplex x = a[i], y = b[i];
    a[i].x = (x.x * y.x - x.y * y.y) * scale;
    a[i].y = (x.x * y.y + x.y * y.x) * scale;
}

// 퍼텐셜의 기울기를 격자 가속도로 만든다(중앙차분).
//
// 비용: G³ 스레드 × O(1). G=128 이면 200만 회.
__global__ void kGridAccel(const float* pot, float4* accG, int G, int S,
                           float potScale, int periodic) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= G || y >= G || z >= G) return;

    int xm, xp, ym, yp, zm, zp;
    if (periodic) {
        xm = (x - 1) & (G - 1); xp = (x + 1) & (G - 1);
        ym = (y - 1) & (G - 1); yp = (y + 1) & (G - 1);
        zm = (z - 1) & (G - 1); zp = (z + 1) & (G - 1);
    } else {
        xm = max(x - 1, 0); xp = min(x + 1, G - 1);
        ym = max(y - 1, 0); yp = min(y + 1, G - 1);
        zm = max(z - 1, 0); zp = min(z + 1, G - 1);
    }
    const float h = 0.5f * G * potScale;
    const float ax = -(pot[(z * S + y) * S + xp] - pot[(z * S + y) * S + xm]) * h;
    const float ay = -(pot[(z * S + yp) * S + x] - pot[(z * S + ym) * S + x]) * h;
    const float az = -(pot[(zp * S + y) * S + x] - pot[(zm * S + y) * S + x]) * h;
    accG[(z * G + y) * G + x] = make_float4(ax, ay, az, 0.f);
}

// 격자 가속도를 알갱이 자리로 되읽는다(CIC 8칸).
__device__ __forceinline__ float4 sampleAcc(const float4* accG, float4 p, int G, int periodic) {
    const float gx = p.x * G - 0.5f, gy = p.y * G - 0.5f, gz = p.z * G - 0.5f;
    const int ix = (int)floorf(gx), iy = (int)floorf(gy), iz = (int)floorf(gz);
    const float fx = gx - ix, fy = gy - iy, fz = gz - iz;
    float4 a = make_float4(0.f, 0.f, 0.f, 0.f);
    for (int k = 0; k < 8; ++k) {
        const int ox = k & 1, oy = (k >> 1) & 1, oz = (k >> 2) & 1;
        const float w = (ox ? fx : 1.f - fx) * (oy ? fy : 1.f - fy) * (oz ? fz : 1.f - fz);
        int cx = ix + ox, cy = iy + oy, cz = iz + oz;
        if (periodic) { cx &= (G - 1); cy &= (G - 1); cz &= (G - 1); }
        else { cx = min(max(cx, 0), G - 1); cy = min(max(cy, 0), G - 1); cz = min(max(cz, 0), G - 1); }
        const float4 g = accG[(cz * G + cy) * G + cx];
        a.x += g.x * w; a.y += g.y * w; a.z += g.z * w;
    }
    return a;
}

// 가속도 크기만 필요할 때(궤도 속도 정하기).
//
// 비용: N 스레드 × 8칸 보간.
// **적분기가 실제로 쓰는 힘을 전부 세야 한다.**
//
// 격자 중력만 재서 속도를 정하면, 도는 동안 헤일로와 블랙홀 중력이 더 붙어 궤도가 모자란다.
// 그러면 판을 열자마자 원반이 안으로 무너진다(2026-08-14 실측). 여기서 더하는 항은
// kIntegrate 가 더하는 항과 하나하나 짝이 맞아야 한다.
// 커널에 넘기는 블랙홀 묶음.
//
// 포인터가 아니라 **값으로** 넘긴다. 여덟 개라도 264 바이트라 커널 인자 한도에 넉넉히 들고,
// device 메모리를 따로 잡아 매 스텝 올려 보내는 것보다 간단하다.
//
// **비용에 상한이 있다는 점이 중요하다.** 알갱이마다 이 묶음을 훑으므로 비용이 개수에
// 정비례한다 — 그래서 kMaxBlackHoles 를 여덟로 묶어 두었다. 알갱이 400만이면 한 스텝에
// 3200만 번이고, 이 카드에서 그 정도는 아직 가볍다.
struct BHPack {
    float4 p[kMaxBlackHoles];   // x, y, z, 삼킴 반경
    float4 q[kMaxBlackHoles];   // GM, 지평선, 안 씀, 안 씀
    int    n = 0;
};

__global__ void kAccelMag(const float4* accG, const float4* pos, float* out,
                          int n, int G, int periodic,
                          BHPack bh) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) { out[i] = 0.f; return; }
    float4 a = sampleAcc(accG, p, G, periodic);

    // (헤일로 근사를 지웠다 — 진짜 암흑물질 입자가 격자 중력에 이미 들어 있다)
    // 처음 속도를 정할 때는 상대론 보정을 빼고 뉴턴만 본다 — 그 보정은 각운동량이
    // 정해진 뒤에야 계산할 수 있는데, 지금 정하려는 것이 바로 그 각운동량이다.
    for (int b = 0; b < bh.n; ++b) {
        const float4 bp = bh.p[b];
        const float dx = p.x - bp.x, dy = p.y - bp.y, dz = p.z - bp.z;
        const float r2 = dx * dx + dy * dy + dz * dz;
        // 적분기와 **같은 소프트닝**을 쓴다. 다르면 처음 넣는 궤도 속도가 실제로 받는 힘과
        // 어긋나 알갱이가 놓이자마자 안팎으로 흘러간다.
        const float rs2 = r2 + bh.q[b].w;
        const float m = -bh.q[b].x / (rs2 * sqrtf(rs2));
        a.x += m * dx; a.y += m * dy; a.z += m * dz;
    }

    // 원반 회전에 쓰는 것은 중심을 향한 **수평** 성분이다. 위아래 성분은 회전과 무관하다.
    const float dx = p.x - 0.5f, dy = p.y - 0.5f;
    const float r = sqrtf(dx * dx + dy * dy);
    out[i] = (r > 1e-5f) ? fmaxf(-(a.x * dx + a.y * dy) / r, 0.f) : 0.f;
}

// 속도와 위치를 한 스텝 나아가게 한다.
//
// 비용: N 스레드 × 8칸 보간. N=200만이면 1600만 번의 격자 읽기.
__global__ void kIntegrate(const float4* accG, float4* pos, float4* vel,
                           int n, int G, float dt, int periodic,
                           BHPack bh, float c2, int* eaten, float* eatenP,
                           const float4* accContact, const float4* accPress,
                           float softBoundR, float darkEnergy) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float4 p = pos[i];
    if (p.x < 0.f) return;
    float4 v = vel[i];

    float4 a = sampleAcc(accG, p, G, periodic);
    if (accContact) { const float4 c = accContact[i]; a.x += c.x; a.y += c.y; a.z += c.z; }

    // **암흑에너지 — 거리에 비례해 바깥으로 민다**(`a = Λ·r`).
    //
    // 중력이 거리의 제곱에 반비례해 **가까울수록** 세지는 것과 반대로, 이것은 **멀수록**
    // 세진다. 그 어긋남이 우주의 한살이를 만든다 — 처음 뭉쳐 있을 때는 중력이 압도해
    // 구조가 자라고, 퍼져서 성겨지면 이쪽이 이겨 다시는 안 무너진다.
    //
    // 이것이 없으면 판이 닫힌 우주가 되어 결국 가운데로 무너진다(2026-08-19 사용자:
    // 「우주가 가운데로 합쳐져서 무너져내리고있어」). 세기를 고른 근거는 `SimConfig::darkEnergy`.
    if (darkEnergy != 0.f) {
        a.x += darkEnergy * (p.x - 0.5f);
        a.y += darkEnergy * (p.y - 0.5f);
        a.z += darkEnergy * (p.z - 0.5f);
    }

    // **압력은 가스만 받는다 — 별은 서로 부딪히지 않는다(2026-08-19).**
    //
    // 여태 압력이 `accG` 에 합쳐져 별에도 걸렸다. 그런데 별 사이 거리는 별 지름의 수천만
    // 배라 별끼리는 충돌이 없고, 압력이란 충돌이 만드는 힘이다 — 별에는 걸릴 근거가 없다.
    // 압력을 받는 별 원반은 가스처럼 부풀고 뭉치기를 반복해, 밀도파(나선팔)가 살아남을
    // 「차가운 별 원반」이 만들어지지 않았다. 나선팔 시도 8회(냉각·압력·형성속도·암흑물질·
    // 해상도·팽대부)가 전부 m=2 요동으로 실패한 뿌리가 이것이다(`.goal-prompt/spiral-arms-
    // emerge/log.md`).
    //
    // 가스는 `p.w == 0`, 별은 `p.w > 0`, 폭발 중은 `p.w < 0`(바깥층이 날아가는 가스라 압력을
    // 받는다). 암흑물질은 `vel.w < -50` 이고 애초에 압력 격자에 안 쌓이지만 여기서도 뺀다.
    if (accPress && p.w <= 0.f && v.w >= -50.f) {
        const float4 pr = sampleAcc(accPress, p, G, periodic);
        a.x += pr.x; a.y += pr.y; a.z += pr.z;
    }

    // (암흑물질 헤일로 근사와 나선 밀도파를 지웠다 — 2026-08-17)
    //
    // **둘 다 「버린 것」인데 코드가 남아 있었다.**
    //
    // 헤일로는 암흑물질을 **배경 힘으로 흉내 낸 근사**였다. round-34 에서 **진짜 입자**로
    // 다시 만들었다(`darkMatterFraction`) — 중력만 주고받고 서로 부딪히지 않아 식지 못해
    // 넓은 구형으로 남는 그 성질까지 실제와 같다. 근사와 진짜가 둘 다 있으면 사용자가
    // 어느 것을 켜야 하는지 알 수 없다.
    //
    // 나선 밀도파는 **팔을 직접 그리는 장치**였다. round-17 에서 **끄고도 팔이 나왔고**
    // (`spiralM2` 0.10~0.26, 실제 은하 범위), 그것이 이 판의 첫째 원칙(연출을 제거한다)이
    // 지키려던 바로 그 결과다. 무늬를 손으로 그리면 「나왔다」가 아무 뜻이 없어진다.

    // 블랙홀 — 휘어진 시공간의 최단경로. 슈바르츠실트 해의 운동을 그대로 적분한다.
    //   a = -GM/r³ · (1 + 3L²/(c²r²)) · r⃗
    // 뒤의 괄호가 상대론 보정이라, 이것 하나로 광자 구면과 최소 안정 궤도가 저절로 나온다.
    // 비용: 알갱이마다 최대 kMaxBlackHoles(여덟) 번. 상한이 있다.
    for (int b = 0; b < bh.n; ++b) {
        const float4 bp = bh.p[b];
        const float dx = p.x - bp.x, dy = p.y - bp.y, dz = p.z - bp.z;
        const float r2 = dx * dx + dy * dy + dz * dz;
        const float r = sqrtf(fmaxf(r2, 1e-12f));
        if (r <= bp.w) {                       // 사건의 지평선 안 — 예외 없이 삼킨다
            // **지평선을 넘은 것은 돌아 나오지 못한다.** 질량과 운동량을 블랙홀에 넘기고
            // 알갱이는 사라진다. 그것이 지평선의 정의다.
            //
            // 여기 있던 **에딩턴 대기열을 걷어냈다(2026-08-18).** 몫이 차면 안 삼키고
            // 「둘레를 돌며 기다린다」고 했는데, 세 가지가 어긋나 있었다:
            //   · 에딩턴 한계는 복사압이 물질을 **바깥으로** 미는 것이라 바깥을 향한
            //     세계선이 없는 지평선 안에서는 성립할 수 없다. 걸 자리가 아니었다.
            //   · 막힌 알갱이가 **지평선 안에 남아 화면에 그려졌다** — 실제로는 그 안에서
            //     나온 빛이 밖에 닿지 못한다.
            //   · 그 알갱이가 튀니까 `v *= 0.90`(스텝당 10%, dt 무관)으로 눌렀고, 그래도
            //     튀니까 중력을 껐다(`continue`). **구심력이 0 이면 원운동이 원리적으로
            //     불가능하다** — 사용자가 본 「경계 입자가 안 돈다」가 그 결과였다.
            //
            // 대기열이 필요했던 이유는 삼킴 반경이 진짜 지평선의 97~650배여서였다.
            // 반경을 실제 값으로 되돌린 지금은 삼키는 부피가 90만분의 1 이라 판이 비지
            // 않는다. 유입을 늦추는 것은 이제 **원반의 마찰**이 한다(지평선 밖에서).
            //
            // 운동량은 그대로 넘긴다 — `v_new = (M·v_bh + Σm·v_p)/(M+Σm)` 를 호스트가
            // 스텝 끝에서 적용한다. 완전비탄성 병합이라 **운동량은 보존하고 운동에너지는
            // 잃는데, 그 잃은 몫이 실제로 원반이 내는 빛이다.**
            atomicAdd(&eaten[b], 1);
            const float4 vin = vel[i];
            atomicAdd(&eatenP[b * 3 + 0], vin.x);
            atomicAdd(&eatenP[b * 3 + 1], vin.y);
            atomicAdd(&eatenP[b * 3 + 2], vin.z);
            pos[i] = make_float4(-1.f, -1.f, -1.f, 0.f);
            vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
            return;
        }
        // 각운동량 L = |r × v|
        const float lx = dy * v.z - dz * v.y;
        const float ly = dz * v.x - dx * v.z;
        const float lz = dx * v.y - dy * v.x;
        const float L2 = lx * lx + ly * ly + lz * lz;
        const float corr = 1.0f + 3.0f * L2 / fmaxf(c2 * r2, 1e-12f);
        // **소프트닝 — 격자 중력과 같은 근거다(2026-08-18에 넣었다).**
        //
        // 여태 이 자리에 소프트닝이 없었는데, 삼킴 반경이 격자 한 칸이라 알갱이가 그
        // 안쪽으로 못 들어가 **그것이 소프트닝 노릇을 대신하고 있었다.** 지평선을 실제
        // 크기(`2GM/c²`, 격자 한 칸의 수천분의 1)로 되돌리자 그 가림막이 사라져 알갱이가
        // 무한히 접근할 수 있게 됐고, `a = GM/r²` 이 발산해 **한 스텝에 광속을 넘겼다** —
        // 사용자가 「엄청 빠르게 은하 밖으로 튕겨져 나가는 입자들이 있어」로 알린 것이다
        // (실측: 블랙홀 전환만 끄면 최고 속도 100 → 1.16).
        //
        // 격자 한 칸보다 작은 거리는 이 시뮬이 원리적으로 구분하지 못한다. 그 아래에서
        // 힘이 발산하지 않게 무르는 것은 격자법의 정당한 근사이고, 실제로 `softeningCells`
        // 가 격자 중력에 이미 같은 일을 한다. 지평선(삼킴 판정)은 그대로 실제 값이다 —
        // **무르는 것은 힘이지 지평선이 아니다.**
        const float eps2 = bh.q[b].w;                 // 소프트닝 길이의 제곱
        const float rs2  = r2 + eps2;
        const float m = -bh.q[b].x * corr / (rs2 * sqrtf(rs2));
        a.x += m * dx; a.y += m * dy; a.z += m * dz;
    }

    v.x += a.x * dt; v.y += a.y * dt; v.z += a.z * dt;

    // **이 우주의 광속을 넘지 못한다.**
    //
    // 물리적으로 당연한 말이지만, 실용적인 이유가 더 크다. 블랙홀을 놓는 순간 이미 궤도
    // 속도로 돌던 알갱이들은 그 중력에 맞지 않는 속도가 되어 안으로 떨어지며 폭주한다.
    // 2026-08-14 실측: 광속의 21배까지 올라갔고(그때 광속은 17.3 이었다), 그러자 CFL 이 「한 스텝에 한 칸을
    // 넘으면 안 된다」며 dt 를 94분의 1로 깎아 **시간이 흐르지 않았다** — 6초 동안 시뮬레이션
    // 시간이 0.013 밖에 안 갔다. 화면은 멈춘 것처럼 보인다.
    //
    // 여기서 잘라 두면 dt 의 하한이 저절로 생긴다(0.8·칸/광속). 잘리는 알갱이는 어차피
    // 지평선으로 떨어질 것들이라 궤도의 모양을 바꾸지 않는다.
    {
        const float sp2 = v.x * v.x + v.y * v.y + v.z * v.z;
        if (sp2 > c2) {
            const float k = sqrtf(c2 / sp2);
            v.x *= k; v.y *= k; v.z *= k;
        }
    }

    p.x += v.x * dt; p.y += v.y * dt; p.z += v.z * dt;

    // 숫자가 한 번 깨지면 그 알갱이는 영영 돌아오지 않고, 격자를 통해 이웃까지 오염시킨다.
    // 발견 즉시 빈 슬롯으로 돌린다.
    if (!isfinite(p.x) || !isfinite(p.y) || !isfinite(p.z) ||
        !isfinite(v.x) || !isfinite(v.y) || !isfinite(v.z)) {
        pos[i] = make_float4(-1.f, -1.f, -1.f, 0.f);
        vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
        return;
    }

    if (periodic) {
        p.x -= floorf(p.x); p.y -= floorf(p.y); p.z -= floorf(p.z);
    } else if (softBoundR > 0.f) {
        // ── 구형 경계 — 벽에 가까울수록 바깥으로 가는 속도를 잃는다 ───────────
        //
        // 아래 큐브 벽은 **우주를 정육면체로 보이게 한다.** 알갱이가 면에 부딪혀 되튀고,
        // 모서리 방향으로만 더 멀리 갈 수 있어 퍼진 모양에 여섯 면이 드러난다
        // (2026-08-19 사용자: 「큐브모양 벽에 부딛혀서 되돌아오고있어. 그래서 우주가
        // 큐브모양처럼 보여」. 그때 30만 중 15187 개가 벽에 붙어 있었다).
        //
        // 그래서 **되튀지 않게** 한다 — 중심에서 `softBoundR` 을 넘어서면 거기서부터
        // 바깥으로 가는 속도 성분만 서서히 깎고, 안쪽으로 오는 것은 건드리지 않는다.
        // 깎는 양이 거리의 제곱으로 커져 한계에 닿을 즈음 0 이 되므로, **부딪히는 순간이
        // 없다.** 튕기는 대신 잦아든다.
        //
        // 접선 속도는 그대로 두는 것이 중요하다 — 함께 깎으면 가장자리 알갱이가 회전을
        // 잃고 지름 방향으로만 늘어서 또 다른 인위적 무늬가 생긴다.
        const float dx = p.x - 0.5f, dy = p.y - 0.5f, dz = p.z - 0.5f;
        const float r2 = dx * dx + dy * dy + dz * dz;
        const float R1 = 0.497f;                       // 절대 한계(판 안쪽)
        if (r2 > softBoundR * softBoundR) {
            const float r   = sqrtf(r2);
            const float inv = 1.0f / fmaxf(r, 1e-6f);
            const float nx = dx * inv, ny = dy * inv, nz = dz * inv;
            // 0(듣기 시작) → 1(한계). 한계 밖은 1 로 묶는다.
            const float t = fminf((r - softBoundR) / fmaxf(R1 - softBoundR, 1e-6f), 1.0f);

            const float vr = v.x * nx + v.y * ny + v.z * nz;   // + 면 바깥으로 간다
            if (vr > 0.f) {
                const float cut = vr * t * t;                  // 제곱이라 안쪽에서는 거의 안 듣는다
                v.x -= nx * cut; v.y -= ny * cut; v.z -= nz * cut;
            }
            // 안쪽으로 당기는 힘도 거리와 함께 커진다. 속도를 깎는 것만으로도 벽에는
            // 안 닿지만, 이것이 있어야 가장자리에 알갱이가 얇게 눌어붙지 않고 돌아온다.
            const float pull = 2.0f * t * t;
            v.x -= nx * pull * dt; v.y -= ny * pull * dt; v.z -= nz * pull * dt;

            // 그래도 한계를 넘었으면 구면에 붙인다 — 큐브 벽이 아니라 **구면**이다.
            if (r > R1) {
                const float k = R1 * inv;
                p.x = 0.5f + dx * k; p.y = 0.5f + dy * k; p.z = 0.5f + dz * k;
            }
        }
    } else {
        // 고립 경계에서는 판 밖으로 못 나가게 붙잡고 속도를 죽인다.
        if (p.x < 0.002f) { p.x = 0.002f; v.x = fabsf(v.x) * 0.25f; }
        if (p.x > 0.998f) { p.x = 0.998f; v.x = -fabsf(v.x) * 0.25f; }
        if (p.y < 0.002f) { p.y = 0.002f; v.y = fabsf(v.y) * 0.25f; }
        if (p.y > 0.998f) { p.y = 0.998f; v.y = -fabsf(v.y) * 0.25f; }
        if (p.z < 0.002f) { p.z = 0.002f; v.z = fabsf(v.z) * 0.25f; }
        if (p.z > 0.998f) { p.z = 0.998f; v.z = -fabsf(v.z) * 0.25f; }
    }
    pos[i] = p; vel[i] = v;
}

// 블랙홀을 놓을 때, 그 둘레의 알갱이에 **그 블랙홀을 도는 속도**를 준다.
//
// **왜 필요한가.** 마우스로 놓는 블랙홀은 알갱이보다 나중에 생긴다. 그 알갱이들의 속도는
// 블랙홀이 없다는 전제로 정해진 것이라 새 중심에 대한 각운동량이 거의 없고, 각운동량이
// 없는 것은 궤도를 그리지 못하고 곧장 중심으로 떨어진다 — 그래서 놓자마자 둘레가 통째로
// 빨려 들어갔다. reset 이 블랙홀을 알갱이보다 **먼저** 세우는 것도 정확히 같은 이유다.
//
// 원궤도 속도는 v = √(GM/r). 도는 방향은 새로 정하지 않고 그 알갱이가 이미 돌던 쪽을
// 따른다 — 원반의 회전이 한쪽만 뒤집히면 그것대로 어색하다.
//
// 최소 안정 궤도(3rs) 안쪽은 손대지 않는다. 거기서는 어떤 속도를 줘도 나선으로 떨어지는
// 것이 옳고, 그 모습이 곧 강착원반의 안쪽 가장자리가 깎이는 장면이다.
//
// 비용: N 스레드 × O(1).
__global__ void kOrbitAroundBH(float4* pos, float4* vel, int n,
                               float bx, float by, float bz,
                               float gm, float rIn, float rOut) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;

    const float dx = p.x - bx, dy = p.y - by, dz = p.z - bz;
    const float r2 = dx * dx + dy * dy + dz * dz;
    const float r = sqrtf(fmaxf(r2, 1e-12f));
    if (r < rIn || r > rOut) return;

    float4 v = vel[i];

    // z 축을 회전축으로 본 접선. 원반이 xy 평면에서 도는 판이라 그것이 자연스럽다.
    float tx = -dy, ty = dx;
    const float tl = sqrtf(tx * tx + ty * ty);
    if (tl < 1e-9f) return;          // 회전축 바로 위 — 접선이 정해지지 않는다
    tx /= tl; ty /= tl;

    // 안쪽일수록 강하게, 바깥으로 갈수록 원래 속도를 존중한다. 블랙홀에서 멀면 원반
    // 자신의 중력이 주인이라, 거기까지 손대면 오히려 판이 흐트러진다.
    const float t = (rOut > rIn) ? (r - rIn) / (rOut - rIn) : 0.f;
    const float w = 1.0f - t * t;

    // 중심으로 떨어지는 성분(반지름 방향)을 덜어 낸다 — 그것이 곧 빨려 드는 성분이다.
    const float ux = dx / r, uy = dy / r, uz = dz / r;
    const float vr = v.x * ux + v.y * uy + v.z * uz;
    v.x -= vr * ux * w;
    v.y -= vr * uy * w;
    v.z -= vr * uz * w;

    // 접선 속도를 원궤도 값으로 끌어당긴다. 이미 돌던 쪽을 따른다.
    const float sgn = (v.x * tx + v.y * ty) >= 0.f ? 1.f : -1.f;
    const float vc  = sqrtf(fmaxf(gm / r, 0.f));
    const float dvt = sgn * vc - (v.x * tx + v.y * ty);
    v.x += dvt * tx * w;
    v.y += dvt * ty * w;

    vel[i] = v;
}

// 각 블랙홀이 놓인 자리의 격자 가속도 — 둘레 물질이 블랙홀을 끄는 힘이다.
// **`w` 에는 그 자리의 밀도를 담는다** — 동역학적 마찰이 쓴다(아래 advanceBlackHoles).
// 블랙홀 수만큼만 도는 아주 작은 커널이라 블록 하나로 충분하다.
__global__ void kSampleAccAtBH(const float4* accG, const float* rho, int G, int S, int periodic,
                               BHPack bh, float4* out) {
    const int i = threadIdx.x;
    if (i >= bh.n) return;
    const float4 bp = bh.p[i];
    float4 a = sampleAcc(accG, make_float4(bp.x, bp.y, bp.z, 0.f), G, periodic);

    // 그 자리의 밀도를 CIC 8칸으로 읽는다. 가속도와 같은 보간이라 둘이 같은 자리를 가리킨다.
    // 밀도 격자는 고립 경계에서 2배로 패딩돼 있으므로 `S`(stride)로 인덱싱한다.
    float d = 0.f;
    if (rho) {
        const float gx = bp.x * G - 0.5f, gy = bp.y * G - 0.5f, gz = bp.z * G - 0.5f;
        const int ix = (int)floorf(gx), iy = (int)floorf(gy), iz = (int)floorf(gz);
        const float fx = gx - ix, fy = gy - iy, fz = gz - iz;
        for (int k = 0; k < 8; ++k) {
            const int ox = k & 1, oy = (k >> 1) & 1, oz = (k >> 2) & 1;
            const float w = (ox ? fx : 1.f - fx) * (oy ? fy : 1.f - fy) * (oz ? fz : 1.f - fz);
            int cx = ix + ox, cy = iy + oy, cz = iz + oz;
            if (periodic) { cx &= (G - 1); cy &= (G - 1); cz &= (G - 1); }
            else { cx = min(max(cx, 0), G - 1); cy = min(max(cy, 0), G - 1); cz = min(max(cz, 0), G - 1); }
            d += rho[((size_t)cz * S + cy) * S + cx] * w;
        }
    }
    a.w = d;
    out[i] = a;
}

// ---------------------------------------------------------------------------
// 알갱이끼리의 접촉 (강체)
//
// 격자로 계산하는 중력만으로는 알갱이가 서로 그냥 통과한다. 격자 한 칸보다 작은 것은
// 없는 것과 같아서, 같은 칸에 있는 둘은 서로에게 아무 힘도 주지 않기 때문이다.
// 겹치면 밀어내고 부딪히면 에너지를 잃게 하면, 모이다가 더 못 눌리는 지점에서 멈춘다.
// ---------------------------------------------------------------------------

// 셀 순서로 정렬된 키에서 각 칸의 [시작, 끝) 구간을 뽑는다.
__global__ void kBuildCellRange(const int* keys, int n, int* start, int* end) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const int k = keys[i];
    if (k < 0) return;
    if (i == 0 || keys[i - 1] != k) start[k] = i;
    if (i == n - 1 || keys[i + 1] != k) end[k] = i + 1;
}

// 이웃 27칸을 훑어 겹친 알갱이를 밀어낸다.
//
// 비용: N 스레드 × 27칸 × (칸당 알갱이 수). 2D 의 9칸에서 27칸으로 세 배가 됐다.
// 칸당 평균 알갱이가 1 을 크게 넘으면 이 커널이 프레임을 통째로 먹으므로,
// 접촉을 켤 수 있는 알갱이 수를 밖에서 제한한다(App::ContactFitsCount).
// 안전을 위해 한 칸에서 보는 상대 수에도 상한을 둔다 — 뭉친 자리에서 폭주하지 않게.
// 세 가지 힘을 얹어 넘기는 묶음. 인자를 늘리는 대신 하나로 묶는다.
struct ForcePack {
    int   contact;      // 겹치면 밀어내기(강체)
    int   strong;       // 강한핵력 — 아주 가까울 때만 세게 당기고, 더 붙으면 민다
    int   em;           // 전자기력 — 같은 부호끼리 밀고 다른 부호끼리 당긴다
    float strongK;
    float emK;
    float damp;         // 임계 감쇠에 대한 비율(1 = 임계). 새 두 힘에만 쓴다
    const float* charge;   // 알갱이마다의 부호(+1/-1). em 을 켤 때만 쓴다
};

__global__ void kContact(const float4* pos, const float4* vel, int n, int G, int S,
                         int periodic, const int* cellStart, const int* cellEnd,
                         float radius, float stiffness, float damping, ForcePack fp,
                         float4* accOut) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    float4 a = make_float4(0.f, 0.f, 0.f, 0.f);
    if (p.x < 0.f) { accOut[i] = a; return; }
    const float4 v = vel[i];

    const float d0 = radius * 2.0f;     // 이보다 가까우면 겹친 것이다
    const float d02 = d0 * d0;
    const int cx = min(max((int)(p.x * G), 0), G - 1);
    const int cy = min(max((int)(p.y * G), 0), G - 1);
    const int cz = min(max((int)(p.z * G), 0), G - 1);

    // 한 알갱이가 이번 스텝에 상대할 수 있는 최대 수. 이 상한이 없으면 뭉친 칸 하나가
    // 스레드 하나를 수천 번 돌게 만들어 프레임이 통째로 멎는다.
    const int kMaxPeers = 96;
    int seen = 0;
    // 새로 더한 두 힘(강한핵력·전자기력)이 만든 몫만 따로 쌓는다. 아래에서 상한을 건다.
    float ax2 = 0.f, ay2 = 0.f, az2 = 0.f;

    for (int dz = -1; dz <= 1 && seen < kMaxPeers; ++dz)
    for (int dy = -1; dy <= 1 && seen < kMaxPeers; ++dy)
    for (int dx = -1; dx <= 1 && seen < kMaxPeers; ++dx) {
        const int c = gidx3(cx + dx, cy + dy, cz + dz, G, G, periodic);
        const int s0 = cellStart[c], e0 = cellEnd[c];
        if (s0 < 0 || e0 <= s0) continue;
        for (int j = s0; j < e0 && seen < kMaxPeers; ++j) {
            if (j == i) continue;
            ++seen;
            const float4 q = pos[j];
            if (q.x < 0.f) continue;
            float ex = p.x - q.x, ey = p.y - q.y, ez = p.z - q.z;
            if (periodic) {   // 반대편으로 감아 가까운 쪽을 본다
                if (ex >  0.5f) ex -= 1.f; else if (ex < -0.5f) ex += 1.f;
                if (ey >  0.5f) ey -= 1.f; else if (ey < -0.5f) ey += 1.f;
                if (ez >  0.5f) ez -= 1.f; else if (ez < -0.5f) ez += 1.f;
            }
            // **도달 거리는 접촉과 같게 둔다 — 넓히면 작용·반작용이 깨진다.**
            //
            // 처음에는 이 두 힘만 두 배 멀리 보게 했다. 반경이 두 배면 이웃이 여덟 배라
            // 한 알갱이가 볼 수 있는 상한(kMaxPeers=96)에 쉽게 걸리는데, **걸리는 순간
            // i 는 j 를 보지만 j 는 i 를 못 보는 짝이 생긴다.** 그러면 힘이 한쪽에만 걸려
            // 두 알갱이가 나란히 밀려나고, 감쇠는 상대 속도에 비례하므로 아무 일도 하지
            // 못한다 — 3초 만에 광속에 닿은 것이 이것이다(2026-08-15 실측).
            // 실제 핵력도 닿을 만큼 가까울 때만 듣는 힘이라 이쪽이 물리적으로도 맞다.
            const float dd = ex * ex + ey * ey + ez * ez;
            if (dd >= d02 || dd < 1e-16f) continue;
            const float d = sqrtf(dd);
            const float nx = ex / d, ny = ey / d, nz = ez / d;
            const float4 vj = vel[j];

            float f = 0.f;                      // 접촉(강체) 몫 — 양수면 민다
            float fx = 0.f;                     // 새로 더한 두 힘의 몫. 따로 모아 상한을 건다
            bool  touched = false;              // 이 짝에 무슨 힘이든 걸렸는가

            const float vn = (v.x - vj.x) * nx + (v.y - vj.y) * ny + (v.z - vj.z) * nz;

            // 겹치면 밀어내기(강체).
            //
            // **감쇠까지 더한 뒤에 자른다.** 이 순서가 뒤집히면 접촉이 끈끈이가 된다 —
            // 멀어지는 짝(vn>0)에 -damping·vn 이 붙어 힘이 음수가 되고, 그것을 자르지
            // 않으면 접촉이 당기는 힘이 되어 그대로 발산한다. 감쇠를 아래 새 힘 쪽으로
            // 옮기며 절단이 감쇠 앞으로 가버렸고, 접촉만 켜도 광속에 닿았다
            // (2026-08-15 실측: peak 11.45). 원래 코드는 한 줄에서 둘을 함께 했다.
            if (fp.contact && d < d0) {
                float fc = stiffness * (d0 - d) - damping * vn;
                if (fc < 0.f) fc = 0.f;
                f += fc;
                touched = true;
            }

            // **강한핵력** — 닿을 만큼 가까울 때만 세게 당기고, 더 붙으면 밀어낸다.
            // 이 두 겹이 있어야 한 점으로 무너지지 않고 「덩어리」로 굳는다. 실제
            // 핵자가 뭉치는 방식이 그렇고, 중력과 달리 멀리 새지 않아 붙은 것끼리만 묶인다.
            if (fp.strong) {
                // **평형 거리에서 0 이고 양쪽으로 이어지는 힘이어야 한다.**
                //
                // 전에는 「core 안쪽이면 밀고 그 밖이면 당긴다」로 나눠 두었는데, 그 경계에서
                // 힘이 0 에서 -18.7 로 **점프**했다. 알갱이가 그 선을 지날 때마다 없던 에너지를
                // 주고받아, 세기를 낮추든 감쇠를 임계로 올리든 3초면 광속에 닿았다.
                // 게다가 그 인력은 가까울수록 세서, 당길수록 더 당기는 되먹임이었다.
                //
                // 지금은 eq 에서 0 이고 가까우면 밀고 멀면 당긴다. 바깥은 창(w)으로 부드럽게
                // 0 이 되어 닿는 거리에서도 끊기지 않는다 — 실제 핵자 사이 퍼텐셜의 모양이다.
                const float eq = d0 * 0.7f;
                const float w  = 1.0f - d / d0;      // d=d0 에서 정확히 0
                fx += fp.strongK * (eq - d) * fmaxf(w, 0.f);
                touched = true;
            }

            // **전자기력** — 부호가 같으면 밀고 다르면 당긴다. 거리 제곱에 반비례하는
            // 것은 중력과 같지만, 양쪽 부호가 있어 뭉치기만 하지 않고 격자처럼 늘어선다.
            //
            // 나누는 값에 바닥을 둔다. 두 알갱이가 겹칠 만큼 가까우면 1/r² 이 발산해
            // 그 짝만으로 판이 터진다 — 바닥 없이 두었더니 점유 칸이 4만에서 격자 전체인
            // 204만으로 벌어지고 속력이 이 우주의 광속에 붙었다(2026-08-14 실측).
            if (fp.em && fp.charge) {
                const float q = fp.charge[i] * fp.charge[j];
                fx += fp.emK * q / fmaxf(dd, d02);
                touched = true;
            }

            // **감쇠는 「세기」에 맞춰야 한다. 이 자리가 세 힘이 폭주한 진짜 원인이었다.**
            //
            // 용수철 상수 k 인 진동자의 임계 감쇠는 2√k 다. 여기서는 힘이 곧 가속도이므로
            // ω = √k 이고, 감쇠가 그보다 한참 작으면 명시적 적분에서 **에너지가 매 스텝
            // (1 + (ω·dt)²) 배로 늘어난다.** 강한핵력 k = 9600 이면 ω = 98, dt = 0.0016 이라
            // 한 바퀴에 1.0246 배 — 1초(60스텝)에 4.3배, 5초면 1500배다. 실측에서 몇 초 만에
            // 이 우주의 광속(100)에 닿은 것이 정확히 이 값이었고, 세기를 2.5분의 1로 낮춰도
            // 여섯 경우 모두 닿은 것도 이것으로 설명된다 — 세기를 낮추면 늘어나는 속도만
            // 조금 느려질 뿐 방향은 그대로다.
            //
            // 접촉력이 오래 무사했던 것은 밀기만 해서(f<0 절단) **애초에 진동자가 아니었기**
            // 때문이다. 인력을 넣는 순간 무감쇠 진동자가 되었고, 그때 감쇠 0.35 는 필요한
            // 값의 560분의 1이었다.
            // 새 두 힘의 감쇠. 접촉의 감쇠는 위에서 그 힘과 함께 계산해 잘랐다.
            if (touched) {
                if (fp.strong || fp.em) {
                    // **감쇠는 「한 쌍당」 값이라 이웃 수만큼 쌓인다.**
                    //
                    // 임계 감쇠 2√k 를 쌍마다 걸었더니, 이웃이 아흔여섯이면 합이 그 아흔여섯
                    // 배가 됐다. 세기를 천분의 1 로 낮춰도(K=8, c=6.2) 합이 595 라 한 스텝에
                    // 속도가 0.95 씩 늘어 열여덟 스텝이면 광속이다 — 세기를 낮추든 알갱이를
                    // 줄이든 3초 만에 터진 것이 이것이었다(2026-08-15 실측).
                    //
                    // 그래서 이웃 수로 나눠 「이 알갱이가 받는 감쇠」의 총량을 임계에 맞춘다.
                    // 그리고 이 몫도 fx 에 넣어 아래 가속도 상한이 함께 잡게 한다 — 예전에는
                    // f 에 들어가 상한 밖에 있었다.
                    float k = 0.f;
                    if (fp.strong) k = fmaxf(k, fp.strongK);
                    // 전자기력의 실효 강성은 |df/dr| = 2·emK/r³ 이고 가장 가까운 r = d0 에서 세다.
                    if (fp.em)     k = fmaxf(k, 2.0f * fp.emK / fmaxf(d02 * d0, 1e-12f));
                    const float cPair = 2.0f * sqrtf(k) * fp.damp / (float)(seen > 0 ? seen : 1);
                    fx -= cPair * vn;
                }
            }

            a.x += (f + fx) * nx; a.y += (f + fx) * ny; a.z += (f + fx) * nz;
            // 새 힘이 만든 몫만 따로 쌓아 둔다(아래에서 상한을 건다).
            ax2 += fx * nx; ay2 += fx * ny; az2 += fx * nz;
        }
    }

    // **새 힘이 만든 가속도에 상한을 건다.**
    //
    // 세기를 2.5분의 1로 낮춰도 여섯 경우 모두 알갱이가 이 우주의 광속(100)에 닿았다
    // (2026-08-14 실측). 세기 문제가 아니다 — 두 알갱이가 충분히 가까워지면 어떤 세기로도
    // 힘이 커지고, 그 자리를 한 번 지난 알갱이는 계속 빨라진다. 상한이 있으면 그 경로가
    // 원천적으로 막힌다.
    //
    // 값의 근거: 한 스텝에 속도가 광속의 1% 넘게 바뀌지 않도록 잡았다.
    //   dt 최대 0.0016, 광속 17.3 → a ≤ 0.01·17.3 / 0.0016 ≈ 108
    // 접촉력(강체)은 이 상한 밖에 둔다 — 그쪽은 예전부터 이 값 위에서 제대로 돌았고,
    // 깎으면 알갱이가 서로 파고든다.
    {
        // 100 은 너무 헐거웠다 — 한 스텝에 0.16 씩이면 108 스텝(1.8초)에 광속이다.
        // 5 면 2100 스텝(36초)이 걸려, 그 전에 광속 감시(30초)가 먼저 손을 댄다.
        // 정상 판에서는 이웃 힘이 서로 상쇄돼 순 가속도가 이 값 근처에도 못 간다.
        const float kMaxNewAcc = 5.0f;
        const float m2 = ax2 * ax2 + ay2 * ay2 + az2 * az2;
        if (m2 > kMaxNewAcc * kMaxNewAcc) {
            const float s = kMaxNewAcc * rsqrtf(fmaxf(m2, 1e-20f));
            // 넘친 만큼만 되돌린다(합에서 빼고 잘린 값을 다시 더한다).
            a.x += ax2 * (s - 1.f);
            a.y += ay2 * (s - 1.f);
            a.z += az2 * (s - 1.f);
        }
    }
    accOut[i] = a;
}

// 냉각 1단계 — 칸마다 속도를 모은다.
//
// 나누면 그 칸의 **평균 흐름**이 되고, 2단계가 그것을 냉각과 분산에 쓴다.
//
// **비용**: N 스레드 × 4 atomicAdd = 4N. N=100만이면 400만 회로, `kScatter`(8N)의 절반이다.
// CIC 8칸이 아니라 **자기 칸 하나**에만 쌓는다 — 냉각은 「같이 있는 것들이 서로 맞춰 간다」는
// 국소 규칙이라 이웃 칸으로 번지게 할 이유가 없고, 8칸이면 원자 연산이 여덟 배가 된다.
__global__ void kAccumCellVel(const float4* pos, const float4* vel, int n, int G, int periodic,
                              float* sumX, float* sumY, float* sumZ, float* cnt) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    const float4 v = vel[i];
    if (!isfinite(v.x) || !isfinite(v.y) || !isfinite(v.z)) return;
    // **암흑물질은 이 통계에 안 든다.** 서로 부딪히지 않는 물질이라 식지도, 압력을 내지도
    // 않는다 — 그래서 실제로도 납작해지지 못하고 넓은 구형 헤일로로 남는다. 여기에 섞으면
    // 헤일로의 무작위 속도가 원반의 「온도」로 잘못 읽혀 압력과 별 문턱이 통째로 어긋난다.
    if (v.w < -50.f) return;
    const int cx = min(max((int)(p.x * G), 0), G - 1);
    const int cy = min(max((int)(p.y * G), 0), G - 1);
    const int cz = min(max((int)(p.z * G), 0), G - 1);
    const int c  = gidx3(cx, cy, cz, G, G, periodic);
    atomicAdd(&sumX[c], v.x);
    atomicAdd(&sumY[c], v.y);
    atomicAdd(&sumZ[c], v.z);
    atomicAdd(&cnt[c], 1.0f);
}

// 냉각 2단계 — 칸 평균 쪽으로 당기고, 그 평균에서 벗어난 정도를 분산으로 쌓는다.
//
// **이것이 없으면 아무것도 뭉치지 않는다.** 중력으로 모이면 위치에너지가 운동에너지로
// 바뀌어 그 자리가 데워지고, 데워진 것은 다시 흩어진다 — 모였다 흩어졌다만 되풀이한다.
// 실제 우주에서는 그 열이 빛으로 빠져나가기 때문에 수축이 멈추지 않고 별이 태어난다.
//
// 걷어내는 것은 **칸 평균과의 차이**뿐이다. 그 칸이 통째로 흐르는 속도(회전·조류)는
// 그대로 두므로 원반이 멈추거나 은하가 주저앉지 않는다. 온도를 따로 들고 다니지 않아도
// 되는 것이 이 방식의 값어치다 — 속도 분산이 곧 온도다.
//
// **왜 이웃 27칸이 아니라 자기 칸인가 — 운동량을 지키려고.**
//
// 전에는 알갱이마다 이웃 27칸을 최대 96개까지 훑어 평균을 냈다. 그러면 이웃 목록이
// 알갱이마다 달라 주고받는 힘이 짝이 안 맞는다. 쌍 (i, j) 가 총합에 더하는 몫이
// `(vⱼ − vᵢ)·(kᵢ/nᵢ − kⱼ/nⱼ)` 인데, 이웃 수도 상한 걸림도 알갱이마다 달라 0 이 안 됐다.
//
// 그 어긋남이 알갱이를 바깥으로 밀었다 — **2026-08-16 실측에서 판의 89% 가 판 벽에
// 붙었고, 냉각만 끄면 1% 였다**(압력만 끄면 51%, 별만 끄면 77% 로 둘 다 무죄).
// 무게중심 정지(`kSubtractMeanVelDev`)는 알짜 흐름만 지우지 그 국소적 힘은 못 막는다.
//
// **같은 칸의 알갱이가 모두 같은 `v̄` 를 보면 `Σ(v̄ − vᵢ) = 0` 이라 총 운동량이 정확히
// 보존된다.** `k` 가 칸마다 달라도(재에 따라) 한 칸 안에서는 같으므로 그대로 성립한다.
//
// **덤으로 싸진다** — 이웃 96개 읽기(N=100만이면 9600만 회)가 통째로 사라지고
// 알갱이당 O(1) 만 남는다.
//
// **분산도 같은 기준으로 잰다.** 칸 평균을 빼고 재므로 원반의 차등회전(안쪽이 빨리 도는 것)이
// 분산으로 새지 않는다 — 한 칸 안의 알갱이들은 사실상 같은 반지름에 있어 회전 속도가 같다.
__global__ void kCoolCell(const float4* pos, const float4* vel, int n, int G, int periodic,
                          const float* sumX, const float* sumY, const float* sumZ,
                          const float* cellCnt,
                          float rate, float dt, float4* velOut,
                          float* dispX, float* dispY, float* dispZ, float* dispCnt,
                          const float* ashGrid, float ashCoolK) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    const float4 v = vel[i];
    velOut[i] = v;                       // 손댈 일이 없으면 그대로 넘긴다
    if (p.x < 0.f) return;
    if (v.w < -50.f) return;             // 암흑물질은 안 식는다(위 `kAccumCellVel` 주석)

    const int cx = min(max((int)(p.x * G), 0), G - 1);
    const int cy = min(max((int)(p.y * G), 0), G - 1);
    const int cz = min(max((int)(p.z * G), 0), G - 1);
    const int c  = gidx3(cx, cy, cz, G, G, periodic);

    const float nc = cellCnt[c];
    // **혼자 있으면 잴 것도 걷어낼 것도 없다.** 자기 자신이 평균이라 `v̄ − v = 0` 이고,
    // 분산도 정의되지 않는다(표본 하나). 그 0 을 격자에 쌓으면 그 칸의 압력과 별 문턱이
    // 함께 0 으로 내려가 알갱이가 통째로 별이 된다 — 2026-08-16 에 실제로 겪었다.
    if (nc < 2.f) return;

    const float inv = 1.f / nc;
    const float mvx = sumX[c] * inv, mvy = sumY[c] * inv, mvz = sumZ[c] * inv;

    // 칸 평균에서 벗어난 정도. 이것이 곧 이 알갱이의 열운동이다.
    const float dvx = mvx - v.x, dvy = mvy - v.y, dvz = mvz - v.z;

    // 분산을 격자에 쌓는다. 각 알갱이가 자기 몫(잔차 제곱)을 더하므로 칸의 합은
    // `Σ(vᵢ − v̄)²` 이 되고, 그것이 곧 ρσ² 라 `kPressure` 가 나누지 않고 바로 미분한다.
    //
    // **여기서 n 으로 나누지 않는다** — 합 자체가 필요한 값이다. 표본분산(n−1)이 필요한
    // 곳은 「그 칸의 σ²」를 쓰는 `kStarForm` 이고, 거기서 `dispCnt` 로 나눈다.
    if (dispCnt) {
        atomicAdd(&dispX[c], dvx * dvx);
        atomicAdd(&dispY[c], dvy * dvy);
        atomicAdd(&dispZ[c], dvz * dvz);
        atomicAdd(&dispCnt[c], 1.0f);
    }

    // 한 스텝에 걷어내는 몫. dt 를 곱해 배속을 바꿔도 식는 속도가 그대로이게 하고,
    // 절반에서 끊는다 — 한 스텝에 칸 평균으로 통째로 갈아타면 알갱이들이 한 덩어리로
    // 굳어 버려 흐름이 사라진다.
    float k = rate * dt * 60.0f;

    // **재가 쌓인 자리는 더 잘 식는다.** 무거운 원소가 있으면 가스가 복사로 에너지를
    // 훨씬 잘 버리기 때문이고, 그래서 초기 우주(재가 없던 시절)의 별은 거대했다.
    // 여기서 사슬이 처음으로 되돌아온다 — 터짐 → 재 → 잘 식음 → σ↓ → Jeans 문턱↓ → 작은 별.
    //
    // **칸 단위라 운동량이 안 깨진다** — 같은 칸의 알갱이는 모두 같은 `k` 를 쓴다.
    if (ashGrid && ashCoolK > 0.f) {
        const float a = ashGrid[c];
        // 로그로 눌러 담는다. 재는 계속 쌓이기만 하는 값이라 선형으로 곱하면 오래 돌린 판에서
        // 냉각률이 무한정 커져, 그 자리가 절대영도처럼 굳어 버린다.
        k *= (1.0f + ashCoolK * __logf(1.0f + a));
    }

    if (k > 0.5f) k = 0.5f;

    // **별은 식지 않는다 — 서로 부딪히지 않기 때문이다(2026-08-19).**
    //
    // 냉각이란 충돌로 무작위 운동을 잃는 것인데, 별 사이 거리는 별 지름의 수천만 배라
    // 별끼리는 충돌이 없다. 여태 별도 가스처럼 칸 평균으로 당겨져 별 원반이 「차가움」을
    // 유지하지 못하고 계속 뭉쳤고, 그것이 나선팔이 요동으로 무너지던 뿌리다(`kIntegrate` 의
    // 압력 주석과 같은 갈래).
    //
    // 분산 격자에는 **위에서 이미 쌓았다** — 별 형성 문턱(`kStarForm`)과 압력은 그 칸 전체의
    // 운동 상태를 봐야 하므로 별의 몫도 들어가야 한다. 속도만 안 건드린다.
    //
    // 폭발 중(`p.w < 0`)은 날아가는 바깥층 = 가스라 식힌다. 별(`p.w > 0`)만 뺀다.
    if (p.w > 0.f) return;               // velOut 은 맨 위에서 v 그대로 넣어 두었다

    // v + k·(v̄ − v). `v̄` 는 그 칸의 **별을 포함한** 전체 평균이다.
    //
    // **별을 뺀 뒤로는 한 칸의 운동량이 정확히 보존되지 않는다** — 가스가 전체 평균으로
    // 당겨지는데 별은 안 움직이므로 「가스 몫의 합」이 0 이 아니다. 실제로도 가스가 별의
    // 중력장 안에서 식는 것이라 별과 가스 사이에 운동량이 오가는 것이 맞고, 판 전체 합은
    // 스텝 끝의 무게중심 정지(`kMomentumAccum` 이후)가 잡는다. 이 편차가 은하를 어디로
    // 밀지는 그 무게중심 창(`totalMomentum`)으로 밖에서 본다.
    velOut[i] = make_float4(v.x + k * dvx, v.y + k * dvy, v.z + k * dvz, v.w);
}

// 격자에 쌓인 속도 분산에서 **압력 가속도**를 내어 중력 가속도에 더한다.
//
// **비용**: 격자 칸 수 × 이웃 6칸 = 209만 × 6 = 1250만 읽기(G=128).
// **알갱이 수와 무관하다** — 한 칸에 알갱이가 백만 개 몰려도 이 커널은 같은 시간에 끝난다.
// 뭉친 자리에서 폭주하는 경로가 구조적으로 없다는 뜻이라, 이 앱에서 그것만으로도 값어치가 있다.
//
// **격자에 패딩을 쓰지 않는다.** 중력(푸아송)은 아주 먼 곳까지 닿는 힘이라 고립 경계에서
// 격자를 8배로 부풀려 푸는데(S), 압력은 **바로 옆 칸만 보는 국소 미분**이라 그럴 이유가 없다.
// 그래서 인덱싱이 accG 와 같은 G³ 이고 pot 의 S³ 이 아니다 — 그냥 따라 했다면 209만이 아니라
// 1677만 칸을 돌 뻔했다.
//
// **식**:  a = -∇·(ρσ²)/ρ  의 대각 성분만 쓴다.
//   a_x = -(1/ρ)·∂(ρσ²ₓₓ)/∂x
// 여기서 재밌는 것이 하나 있다 — `dispX[c]` 는 그 칸 알갱이들의 **분산 합**이라
//   ρσ²ₓₓ = (칸의 알갱이 수) × (분산 평균) = cnt × (dispX/cnt) = dispX
// 즉 **쌓아 둔 합 자체가 이미 ρσ² 다.** 평균으로 나눴다가 다시 곱할 필요가 없다.
//
// **방향별로 따로 미분한다**(σ²ₓₓ 는 x 로, σ²yy 는 y 로). 이것이 등방 압력과 갈리는 자리다 —
// 하나로 뭉개면 원반의 수직 방향까지 좌우만큼 밀어내 판이 공처럼 부푼다. 방향을 나누면
// 위아래 분산이 작은 만큼 덜 밀려 **원반이 스스로 납작해진다**(diskThickness 를 손으로
// 정하지 않아도 되는 이유가 이것이다).
__global__ void kPressure(const float* dispX, const float* dispY, const float* dispZ,
                          const float* dispCnt, float4* accP, int G, int periodic,
                          float k, float maxAcc) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= G || y >= G || z >= G) return;

    const int c = (z * G + y) * G + x;
    const float rho = dispCnt[c];
    // 빈 칸에는 밀어낼 것이 없다. 여기서 안 걸러 내면 0 으로 나눠 무한대가 된다.
    if (rho < 1e-6f) return;

    // 이웃 인덱스는 kGridAccel 과 같은 규칙으로 잡는다(주기면 감싸고, 고립이면 가장자리에 붙인다).
    int xm, xp, ym, yp, zm, zp;
    if (periodic) {
        xm = (x - 1) & (G - 1); xp = (x + 1) & (G - 1);
        ym = (y - 1) & (G - 1); yp = (y + 1) & (G - 1);
        zm = (z - 1) & (G - 1); zp = (z + 1) & (G - 1);
    } else {
        xm = max(x - 1, 0); xp = min(x + 1, G - 1);
        ym = max(y - 1, 0); yp = min(y + 1, G - 1);
        zm = max(z - 1, 0); zp = min(z + 1, G - 1);
    }

    // 중앙차분. 칸 하나가 1/G 이므로 1/(2·cell) = G/2 다.
    const float h = 0.5f * (float)G * k / rho;
    float ax = -(dispX[(z * G + y) * G + xp] - dispX[(z * G + y) * G + xm]) * h;
    float ay = -(dispY[(z * G + yp) * G + x] - dispY[(z * G + ym) * G + x]) * h;
    float az = -(dispZ[(zp * G + y) * G + x] - dispZ[(zm * G + y) * G + x]) * h;

    // 상한. 분산이 한 칸에서만 튀면(알갱이가 몇 개뿐인 칸에서 잘 일어난다) 기울기가 커져
    // 힘이 발산하는데, 그 알갱이는 다음 스텝에 판 밖으로 날아가고 그것이 연쇄가 된다.
    // 중력 쪽 kIntegrate 도 같은 이유로 가속도를 자른다.
    ax = fminf(fmaxf(ax, -maxAcc), maxAcc);
    ay = fminf(fmaxf(ay, -maxAcc), maxAcc);
    az = fminf(fmaxf(az, -maxAcc), maxAcc);

    // **압력 전용 격자에 쓴다 — 중력과 섞지 않는다(2026-08-19).**
    //
    // 전에는 `accG` 에 더해 알갱이가 두 힘의 합을 하나로 받았다. 그러면 별도 압력을 받는데,
    // 별은 서로 부딪히지 않아 압력이 걸릴 근거가 없다(`kIntegrate` 의 주석). 따로 담아
    // 두면 적분이 가스에만 더할 수 있다. `w` 는 안 쓴다(0).
    //
    // 빈 칸(`rho < 1e-6`)은 위에서 이미 반환했는데 그 칸에 묵은 값이 남지 않게 매 스텝
    // 호출부가 먼저 비운다(`kClearF4`).
    accP[c] = make_float4(ax, ay, az, 0.f);
}

// 가스가 별이 되는 자리. **문턱을 손으로 정하지 않고 Jeans 조건으로 판정한다.**
//
// **비용**: N 스레드 × O(1). 이웃을 훑지 않는다 — `kCool` 이 격자에 남긴 값을 읽기만 한다.
// N=400만이면 400만 회이고, 그중 조건을 통과한 것만 격자 원자 연산 1회를 더 한다.
//
// **왜 Jeans 인가.** 실제 별은 중력이 압력을 이길 때 태어난다(진스 불안정). 그 조건은
//   M_J = k · σ³ / √ρ        σ = 무작위 운동의 세기, ρ = 밀도
// 이고 「그 자리 질량이 M_J 를 넘으면 무너진다」로 읽는다. 격자에서는 칸 부피가 고정이라
// M_local = ρ·V 이므로 정리하면 훨씬 간단해진다:
//   ρV > k·σ³/√ρ   →   ρ^1.5 > k'·σ³   →   **ρ > k_J · σ²**
//
// **차가우면 낮은 밀도에서도 뭉치고, 뜨거우면 더 빽빽해야 한다.** 이 한 줄이 물리 그대로다.
//
// 이것이 「이웃이 N개 이상」과 결정적으로 다른 점: 그 방식은 N 이 격자 크기와 `kCool` 의
// 96 절단에 통째로 휘둘리는 임의 숫자다. Jeans 는 상수가 `k_J` 하나뿐이고, 그 하나도
// 「별이 전체의 몇 %가 되게 할 것인가」로 눈금이 잡힌다.
//
// **덤으로 사슬 하나가 공짜로 돌아온다.** 재가 쌓인 자리는 잘 식어 σ 가 내려가는데,
// σ² 가 분모 쪽에 있으므로 문턱이 저절로 낮아져 **작은 별이 태어난다.**
// 「재가 많으면 작은 별을 만들어라」라는 줄을 코드에 적을 필요가 없다 — 그것이 연출이다.
__global__ void kStarForm(float4* pos, int n, int G, int periodic,
                          const float* dispX, const float* dispY, const float* dispZ,
                          const float* dispCnt, float kJeans, float sunMass,
                          float formEff, float dt, unsigned seed,
                          const float* ashGrid, double* bornStat, const float4* vel) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    // **암흑물질은 별이 되지 않는다** — 빛과 아무 상호작용을 안 하는 물질이라 핵융합도 없다.
    if (vel && vel[i].w < -50.f) return;
    float4 p = pos[i];
    if (p.x < 0.f) return;               // 삼켜졌거나 빈 자리
    if (p.w != 0.f) return;              // 이미 별이거나(>0) 폭발 중(<0)

    const int cx = min(max((int)(p.x * G), 0), G - 1);
    const int cy = min(max((int)(p.y * G), 0), G - 1);
    const int cz = min(max((int)(p.z * G), 0), G - 1);
    const int c  = gidx3(cx, cy, cz, G, G, periodic);

    // **판정값은 CIC 8칸으로 보간해 읽는다(2026-08-17).**
    //
    // 전에는 자기 칸 하나만 읽었다. 그러면 **한 칸 안의 알갱이가 모두 같은 문턱을 보고
    // 동시에 별이 된다** — 화면에서 네모난 영역이 통째로 켜지고, 그것이 칸 순서대로
    // 번져 보인다. 사용자가 「입자들이 네모난 영역만큼 순서대로 생성되는 것 같다」고
    // 알린 그 증상이다.
    //
    // `kScatter` 가 CIC 8칸으로 **뿌렸으니** 읽을 때도 같은 방식이어야 대칭이다. 그러면
    // 알갱이마다 위치에 따라 값이 조금씩 달라 칸 경계가 사라진다.
    //
    // **비용**: 알갱이당 8칸 × 격자 4개 = 32 읽기. 원자 연산이 아니라 읽기이고, 별이
    // 안 될 알갱이는 앞에서 대부분 걸러진다(가스가 아니면 반환).
    float cnt = 0.f, s2num = 0.f;
    {
        const float fgx = p.x * G - 0.5f, fgy = p.y * G - 0.5f, fgz = p.z * G - 0.5f;
        const int ix = (int)floorf(fgx), iy = (int)floorf(fgy), iz = (int)floorf(fgz);
        const float fx = fgx - ix, fy = fgy - iy, fz = fgz - iz;
        for (int k = 0; k < 8; ++k) {
            const int ox = k & 1, oy = (k >> 1) & 1, oz = (k >> 2) & 1;
            const float w = (ox ? fx : 1.f - fx) * (oy ? fy : 1.f - fy) * (oz ? fz : 1.f - fz);
            if (w <= 0.f) continue;
            const int nx = min(max(ix + ox, 0), G - 1);
            const int ny = min(max(iy + oy, 0), G - 1);
            const int nz = min(max(iz + oz, 0), G - 1);
            const int nc = gidx3(nx, ny, nz, G, G, periodic);
            cnt   += w * dispCnt[nc];
            s2num += w * (dispX[nc] + dispY[nc] + dispZ[nc]);
        }
    }
    // 혼자 있는 알갱이는 별이 될 수 없다. 분산도 못 재고(이웃이 없다) 질량도 하나뿐이다.
    if (cnt < 2.f) return;

    // 방향별 분산의 평균. 셋을 더해 셋으로 나누는 대신 개수로만 나누면 3σ² 가 되므로
    // 그만큼 k_J 에 흡수시킨다 — 나눗셈 하나를 아낀다.
    const float s2 = s2num / cnt;   // 위에서 8칸 보간으로 모아 둔 값

    // ρ > k_J · σ². σ² 가 0 에 가까우면(잘 식은 자리) 문턱이 0 으로 내려가는데,
    // 그때는 cnt >= 2 조건이 바닥 노릇을 한다.
    // **문턱이 날카로우면 별이 칸 단위로 우르르 태어난다 — 그게 격자 눈금의 정체다.**
    //
    // `cnt` 와 `s2` 는 여덟 칸에서 보간해 오지만, 한 칸 안의 알갱이들은 거의 같은 값을
    // 본다. `cnt > kJeans·s2` 처럼 넘느냐 마느냐로 자르면 **한 칸이 그 선을 넘는 순간
    // 그 칸의 알갱이 전체가 동시에 후보**가 되고, 칸마다 넘는 시점이 달라 사각형이
    // 하나씩 불이 켜지는 것처럼 보인다 — 2026-08-17 사용자가 「사각형 단위로 하나씩
    // 밝아진다」, 「격자무늬가 티가 날 정도로 보인다」고 두 번 알린 것이 이것이다.
    //
    // **실제 Jeans 불안정에도 그런 선이 없다.** 분자운 안은 난류로 밀도가 늘 출렁이고,
    // 임계 근처에서는 같은 평균 밀도라도 어떤 자리는 무너지고 어떤 자리는 안 무너진다.
    // 날카로운 문턱은 그 요동을 지운 근사였고, 지우니 격자가 드러났다.
    //
    // 그래서 문턱을 폭으로 바꾼다. 절반에 못 미치면 아예 안 되고, 절반에서 한 배 반
    // 사이에서 확률이 매끄럽게 올라간다(smoothstep). 이웃한 두 칸이 문턱을 사이에 두고
    // 갈려도 확률이 이어져 경계가 안 보인다.
    const float thr  = kJeans * s2;
    const float over = cnt / fmaxf(thr, 1e-6f);
    if (over <= 0.5f) return;
    const float su   = __saturatef(over - 0.5f);
    const float soft = su * su * (3.f - 2.f * su);
    {
        // **조건을 만족해도 그 스텝에 별이 되는 것은 일부다 — 별 형성 효율.**
        //
        // 실제 거대 분자운은 **1~5% 만** 별이 되고 나머지는 가스로 남는다. 별이 켜지면
        // 그 복사와 항성풍이 둘레를 흩어 다음 별이 되는 것을 막기 때문이다.
        //
        // 이것이 없으면 조건을 만족한 알갱이가 **그 자리에서 100% 별이 된다.** 그러면
        // 별이 되는 속도가 사실상 무한대라, 별이 죽어 가스로 돌아오는 속도가 아무리
        // 빨라도 평형이 「전부 별」에 선다 — 2026-08-16 실측에서 100초에 가스가 100만 중
        // 623 개, IMF 를 넣은 뒤에도 0% 였다. **속도를 유한하게 만들어야 평형점이 생긴다.**
        //
        // `dt` 를 곱해 배속을 바꿔도 같은 속도로 별이 되게 한다(`kCool` 의 `k` 와 같은 규칙).
        // 씨앗에 스텝 번호를 섞는다 — 알갱이 번호만 쓰면 매 스텝 같은 값이 나와 어떤
        // 알갱이는 영원히 별이 안 되고 어떤 알갱이는 즉시 된다.
        if (formEff > 0.f) {
            unsigned g = (unsigned)i * 747796405u + seed;
            g ^= g >> 16; g *= 2246822519u; g ^= g >> 13;
            const float r = (float)(g & 0x00FFFFFFu) * (1.0f / 16777216.0f);
            // `soft` 를 곱해 문턱 근처에서 확률이 매끄럽게 오르게 한다(바로 위 참조).
            if (r > formEff * soft * dt * 60.0f) return;
        }

        // **별 질량에 상한을 건다 — 이 상한이 없어 2026-08-16 에 시스템이 죽었다.**
        //
        // 전에는 `p.w = cnt` 였다. `cnt` 는 그 칸에 모인 알갱이 수라 **상한이 없다** —
        // 한 칸에 100만이 몰리면 별 하나가 질량 100만이 되고, 그 값이 네 곳으로 번진다:
        //   · `kScatterLight` 의 `lum = (p.w/sunMass)^3.5` → 33만^3.5 ≈ 1e19
        //   · `kStarAge` 의 수명 `sunLifeSim · ratio^-2.5` → 사실상 0, 태어나자마자 터진다
        //     (2026-08-16 실측: 알갱이의 33% 가 언제나 폭발 중, 가스는 100만 중 623개)
        //   · `ashGrid` 에 한 번에 100만씩 쌓임
        //   · 블랙홀 문턱 `ratio >= 200` 을 모든 별이 넘음
        //
        // **상한은 연출이 아니라 빠진 현실이다.** 실제 별에는 질량 상한이 있다 —
        // 너무 무거우면 자기 복사압이 자기 바깥층을 날려 버린다(에딩턴 한계). 관측된
        // 가장 무거운 별이 태양의 150~300배다. 그리고 **거대 분자운 하나가 별 하나가
        // 되지 않는다** — 여럿으로 쪼개져 성단이 된다. `cnt` 를 통째로 한 알갱이에
        // 몰아주던 것이 그 사실을 무시하고 있었다.
        //
        // 코어가 자른다(CLAUDE.md 3번) — 설정으로 열지 않는다. 밖에서 올릴 수 있으면
        // 이 안전장치가 안전장치가 아니게 된다.
        const float kEddingtonRatio = 150.0f;    // 태양질량 몇 배까지

        // **별 질량을 초기질량함수(IMF)에서 뽑는다 — `cnt` 를 그대로 쓰지 않는다.**
        //
        // 전에는 그 칸의 가스가 통째로 별 하나가 됐다. 그러면 **모든 별이 무겁다** —
        // 뭉친 칸일수록 `cnt` 가 크니 질량이 크고, 무거우면 `T ∝ M^-2.5` 로 빨리 죽어
        // 폭발이 쌓인다. 문턱(`kJeans`)을 올려 가스를 남기려 하면 더 뭉친 칸에서만 별이
        // 되어 질량이 **더** 커지는 악순환이었다(2026-08-16 실측: 문턱을 250배 올리자
        // 가스가 0.2%→6% 로 늘었지만 폭발 중이 15%→15% 그대로, 평균 질량은 15→40).
        //
        // **실제 우주는 거대 분자운 하나에서 별을 여럿 만들고, 그 질량에 분포가 있다.**
        // 관측된 기울기가 `dN/dM ∝ M^-2.35`(살페터 IMF)로, **작은 별이 압도적으로 많고
        // 무거운 별은 드물다.** 태양 100배짜리는 1배짜리보다 수만 배 희귀하다.
        //
        // 누적분포를 뒤집으면 `M = M_min · (1-u)^(-1/1.35)` 이다(u 는 [0,1) 균등).
        // u=0.5 면 태양 0.17배, u=0.99 면 3배, u=0.999 면 17배 — 그 희소성이 그대로 나온다.
        //
        // **씨앗은 알갱이 번호다.** 난수를 매번 새로 뽑지 않고 번호에서 만들어, 같은
        // 알갱이는 늘 같은 별이 된다(스펙 「같은 별은 볼 때마다 같은 모습」과 같은 원리).
        // **한계**: 정렬이 알갱이를 재배치하면 번호가 바뀌어 다른 질량이 나온다. 별이
        // 된 뒤에는 이 커널을 다시 안 타므로(`p.w != 0` 이면 반환) 이미 선 별은 안 바뀐다.
        unsigned h = (unsigned)i * 2654435761u + 1442695041u;
        h ^= h >> 15; h *= 2246822519u; h ^= h >> 13;
        const float u = (float)(h & 0x00FFFFFFu) * (1.0f / 16777216.0f);
        const float mMin = sunMass * 0.1f;                 // 실제 하한은 태양 0.08배
        float m = mMin * __powf(fmaxf(1.0f - u, 1e-6f), -0.7407f);   // -1/1.35
        m = fminf(m, sunMass * kEddingtonRatio);           // 에딩턴 한계

        // **재료가 모자라면 별이 안 된다.** 그 칸에 있는 것보다 무거운 별은 못 만든다 —
        // 이 한 줄이 가스를 남긴다. 무거운 쪽을 뽑은 알갱이는 대부분 여기서 걸러져
        // 가스로 남고, 그것이 다음에 다시 뭉칠 재료가 된다.
        if (m <= cnt) {
            p.w = m;
            pos[i] = p;
            // **폭발 자리에서 새 별이 태어나는지 보는 창.**
            //
            // 「그 별이 태어난 칸에 재가 얼마나 있었나」를 모은다. 판 전체의 칸당 재 평균과
            // 견주면 **재가 쌓인 자리(= 별이 터진 자리)에서 별이 더 잘 태어나는지**가 나온다.
            // 이 수를 안 모으면 그 항목을 스크린샷 인상으로만 판정하게 된다.
            //
            // 비용: 별이 되는 순간에만 도는 원자 연산 둘. 태어나는 수는 한 스텝에 수천이라
            // 셀 필요도 없는 양이다.
            if (bornStat && ashGrid) {
                const float ashHere = ashGrid[c];
                atomicAdd(&bornStat[0], 1.0);
                atomicAdd(&bornStat[1], (double)ashHere);

                // **껍질인가 중심인가** — 스펙의 확인 조건에 「폭발 지점 둘레에 **껍질
                // 모양**으로」가 있는데 그것을 여태 못 봤다. 폭발 지점을 따로 기억하지
                // 않고도 잴 수 있다: **껍질에서 태어난 별은 자기 칸보다 이웃 칸의 재가
                // 더 진하다**(재의 봉우리가 옆에 있다는 뜻). 중심에서 태어났다면 자기
                // 칸이 봉우리다.
                //
                // 이웃 여섯 칸만 본다(면으로 붙은 것). 스물여섯을 다 보면 네 배 비싸고,
                // 봉우리가 어느 쪽인지만 알면 되므로 여섯이면 갈린다.
                const int nb[6][3] = {{-1,0,0},{1,0,0},{0,-1,0},{0,1,0},{0,0,-1},{0,0,1}};
                float ashMax = ashHere;
                for (int k = 0; k < 6; ++k) {
                    const int nx = cx + nb[k][0], ny = cy + nb[k][1], nz = cz + nb[k][2];
                    if (nx < 0 || ny < 0 || nz < 0 || nx >= G || ny >= G || nz >= G) continue;
                    const float a = ashGrid[gidx3(nx, ny, nz, G, G, periodic)];
                    if (a > ashMax) ashMax = a;
                }
                // 1.5배는 「봉우리가 확실히 옆에 있다」의 선이다. 조금만 커도 껍질로 세면
                // 격자 잡음이 그대로 통계에 들어온다.
                if (ashMax > ashHere * 1.5f) atomicAdd(&bornStat[2], 1.0);
            }
        }
    }
}

// 재가 퍼진다 — **초신성 잔해는 한 자리에 머물지 않는다.**
//
// **왜 필요한가.** `kStarAge` 는 재를 폭발한 알갱이가 있던 **한 칸**에만 쌓는다. 알갱이는
// 폭발 킥으로 흩어지는데 재는 그 자리에 남는다 — 그래서 재의 봉우리가 점 하나이고,
// 새 별이 그 점 **위에서** 태어난다. 2026-08-17 실측: 봉우리 **둘레**에서 난 별이
// **6%** 뿐이라 스펙이 말한 「폭발 지점 둘레에 껍질 모양으로」가 안 나왔다.
//
// 실제 초신성 잔해는 퍼진다(게 성운은 천 년에 몇 광년). 무거운 원소가 잔해와 함께
// 날아가 넓은 껍질을 이루고, 그 껍질이 식어 다음 별의 재료가 된다.
//
// **이웃 여섯 칸과 섞는다.** 확산 방정식을 한 스텝 푸는 것과 같다:
//   `a' = a + k·(이웃 평균 − a)`
// 가운데를 낮추고 둘레를 올리므로 봉우리가 넓어진다. **제자리에서 고치면 옆 스레드가
// 이미 퍼진 값을 읽어 한쪽으로 쏠리므로** 결과를 다른 격자에 쓰고 바꿔 끼운다.
//
// **비용**: G³ 스레드 × 이웃 6 읽기. 128³ 이면 1200만 회이고, `doCooling` 과 같은 주기로
// 돌므로 매 스텝이 아니다.
__global__ void kDiffuseAsh(const float* src, float* dst, int G, int periodic, float k) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= G || y >= G || z >= G) return;
    const int c = gidx3(x, y, z, G, G, periodic);
    const float a = src[c];

    float sum = 0.f; int used = 0;
    const int nb[6][3] = {{-1,0,0},{1,0,0},{0,-1,0},{0,1,0},{0,0,-1},{0,0,1}};
    for (int i = 0; i < 6; ++i) {
        const int nx = x + nb[i][0], ny = y + nb[i][1], nz = z + nb[i][2];
        if (!periodic && (nx < 0 || ny < 0 || nz < 0 || nx >= G || ny >= G || nz >= G)) continue;
        sum += src[gidx3(nx, ny, nz, G, G, periodic)];
        ++used;
    }
    // 가장자리는 이웃이 모자란다 — 있는 것만으로 평균을 낸다. 없는 쪽을 0 으로 세면
    // 판 끝에서 재가 새어 나가는 것처럼 보인다.
    dst[c] = (used > 0) ? (a + k * (sum / (float)used - a)) : a;
}

// 젊고 무거운 별의 자외선이 둘레 가스를 데운다 — **HII 영역.**
//
// **왜 필요한가 — 이것이 없으면 판이 통째로 별이 된다.**
// 2026-08-17 실측: 시뮬 시간 6 에 이미 98.6%가 별이고, 가스가 4,557 → 235 로 한 번도
// 안 늘고 준다. 무거운 별이 한꺼번에 태어나 한꺼번에 죽고 나면 작은 별만 남는데
// `T ∝ M^-2.5` 라 그것들은 사실상 안 죽는다 — **가스가 돌아올 길이 없어 사슬이 멎는다.**
//
// 실제 은하에서 별 형성 효율이 1~5% 에 묶이는 주된 이유가 이것이다. 갓 태어난 O·B형 별은
// 자외선을 쏟아 둘레 수소를 이온화하고, 이온화된 가스는 1만 K 로 데워진다. 그러면
// Jeans 질량 `M_J ∝ σ³/√ρ` 이 크게 올라 **그 자리에서는 다음 별이 못 생긴다.**
// 별이 자기 재료를 스스로 태워 없애는 셈이다.
//
// **규칙을 적지 않는다.** 「별이 많으면 별을 그만 만든다」고 쓰는 것이 아니라 분산 격자에
// 열을 넣을 뿐이고, 별 형성을 막는 것은 이미 있는 Jeans 조건이다.
//
// **비용**: 별 스레드 × 3 atomicAdd. 그나마 `ratio ≥ 8` 인 것만 지나므로(초기질량함수에서
// 0.27%) 100만 알갱이에 8천 번 남짓이다. 문턱 아래 별은 첫 줄에서 반환한다.
//
// 문턱 8 은 실제 값이다 — 태양 8배 아래 별은 자외선이 약해 의미 있는 HII 영역을 못 만든다.
// 그 위는 이온화 광자 수가 질량에 급격히 붙지만, **여기서는 선형으로 둔다** — 곱의 최댓값에
// 상한이 있어야 하고(`kEddingtonRatio`=150 에서 잘린다), 지수를 올리면 그 상한이 흐려진다.
__global__ void kIonize(const float4* pos, const float4* vel, int n, int G, int periodic,
                        float* dispX, float* dispY, float* dispZ, const float* cellCnt,
                        float sunMass, float sigma2) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f || p.w <= 0.f) return;          // 가스·폭발중·빈 자리는 아니다
    if (vel[i].w < 0.f) return;                   // 잔해는 자외선을 안 낸다(핵융합이 끝났다)
    const float ratio = p.w / fmaxf(sunMass, 1e-6f);
    if (ratio < 8.0f) return;                     // O·B형만 이온화한다

    const int cx = min(max((int)(p.x * G), 0), G - 1);
    const int cy = min(max((int)(p.y * G), 0), G - 1);
    const int cz = min(max((int)(p.z * G), 0), G - 1);
    const int c  = gidx3(cx, cy, cz, G, G, periodic);

    // `kPressure` 와 `kStarForm` 은 `dispX / dispCnt` 로 **평균**을 읽는다. 그래서 평균에
    // `sigma2` 만큼을 더하려면 그 칸의 개수를 곱해 넣어야 한다.
    const float cnt = cellCnt ? cellCnt[c] : 0.f;
    if (cnt < 1.f) return;
    const float add = sigma2 * cnt * fminf(ratio / 8.0f, 20.0f);   // 곱의 최댓값을 여기서 자른다
    atomicAdd(&dispX[c], add);
    atomicAdd(&dispY[c], add);
    atomicAdd(&dispZ[c], add);
}

// 초신성이 **주변 물질을 실제로 밀어낸다.**
//
// **여태 폭발은 자기 자신만 튕겼다**(`kStarAge` 의 킥). 이웃에게는 아무 힘도 가지 않아,
// 사용자가 「주변에 폭발이 일어나서 다른 별들이 밀려나는 게 보여야되는데 그런게 없어」
// 라고 알린 그대로였다.
//
// **연출로 밀지 않는다.** 「반경 R 안의 알갱이를 바깥으로 민다」 같은 규칙을 적으면 그것은
// 손으로 그린 폭발이다. 대신 **폭발 에너지를 그 자리의 열로 넣는다** — 실제 초신성이 하는
// 일이 그것이고(10⁵¹ erg 가 주변 성간물질을 데운다), 그 다음은 이미 있는 압력이 한다.
//
// 뜨거워진 칸은 둘레보다 압력이 높아지고, `kPressure` 가 그 기울기 `−∇(ρσ²)/ρ` 로 물질을
// 바깥으로 민다. **세도프-테일러 팽창이 저절로 나온다** — 팽창 반경 `R ∝ (E t²/ρ)^(1/5)`
// 도, 짙은 쪽으로 덜 퍼지고 성긴 쪽으로 더 퍼지는 비대칭도 규칙을 안 적어도 생긴다.
// `kIonize` 가 같은 통로로 별 형성을 막는 것과 똑같은 수법이다.
//
// **주입은 앞쪽에 몰아 준다.** 실제 폭발은 순간이고 그 뒤는 팽창이다. 진행도에 따라
// 급히 줄여, 터진 직후 한 번 세게 밀고 나면 잔해가 관성으로 퍼지게 둔다.
//
// **비용**: N 스레드 × O(1), 그나마 폭발 중인 것만 3 atomicAdd. 반경 루프가 없어 한
// 스레드가 하는 일에 상한이 있다(CLAUDE.md 2번).
__global__ void kSupernovaHeat(const float4* pos, int n, int G, int periodic,
                               float* dispX, float* dispY, float* dispZ, const float* cellCnt,
                               float explodeSim, float sigma2) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f || p.w >= 0.f) return;          // 폭발 중인 것만

    // 진행도 0(막 터짐) ~ 1(끝). 앞 구간에 에너지를 몰아 준다.
    const float prog = __saturatef(1.f - (-p.w) / fmaxf(explodeSim, 1e-6f));
    const float w    = (1.f - prog) * (1.f - prog);   // 터진 직후가 가장 세다
    if (w <= 1e-4f) return;

    const int cx = min(max((int)(p.x * G), 0), G - 1);
    const int cy = min(max((int)(p.y * G), 0), G - 1);
    const int cz = min(max((int)(p.z * G), 0), G - 1);
    const int c  = gidx3(cx, cy, cz, G, G, periodic);

    // `kPressure` 는 `dispX / dispCnt` 로 **평균**을 읽으므로, 평균에 얼마를 더하려면
    // 그 칸의 개수를 곱해 넣어야 한다(`kIonize` 와 같은 규칙).
    const float cnt = cellCnt ? cellCnt[c] : 0.f;
    if (cnt < 1.f) return;
    const float add = sigma2 * cnt * w;
    atomicAdd(&dispX[c], add);
    atomicAdd(&dispY[c], add);
    atomicAdd(&dispZ[c], add);
}

// 별이 늙고, 수명이 다하면 터지고, 터진 것이 가스로 돌아온다. **사슬을 닫는 커널이다.**
//
// **비용**: N 스레드 × O(1). 이웃도 격자도 안 본다 — 자기 알갱이 하나만 읽고 쓴다.
//
// **왜 이것 없이는 별 비율이 안 잡히나.** 별이 되돌아갈 길이 없으면 판정을 반복할수록
// 쌓이기만 한다(2026-08-16 실측: 3초 76% → 60초 99.9%). 실제 은하에서 별 비율이 유지되는
// 것은 형성률과 사망률이 균형을 이루기 때문이고, **평형은 양쪽이 다 있어야 존재한다.**
//
// **상태 두 축**(design.md 1장):
//   pos.w   0 = 가스 · >0 = 별(값이 질량) · <0 = 폭발 중(|값| 이 남은 시간)
//   vel.w   ≥0 = 나이 · <0 = 잔해(더 이상 안 늙는다)
//
// **수명은 시간 배율 위에서 나온다**(`kYearsPerSimUnit`). 무거울수록 짧다:
//   T = T_sun · (M/M_sun)^-2.5      태양급 100억 년이면 20배 별은 1000만 년
// 지수가 -2.5 라 **20배 무거운 별이 천 배 빨리 죽는다.** 그래서 밝은 별이 먼저 사라지고
// 붉은 별만 남아 은하 색이 통째로 늙는다.
__global__ void kStarAge(float4* pos, float4* vel, int n, float dt,
                         float sunMass, float sunLifeSim, float explodeSim,
                         float kickSpeed, unsigned seed,
                         float* ashGrid, int G, int periodic, float ashYield,
                         float4* bhCand, float4* bhCandV, int* bhCandN, int* bhBlocked,
                         int bhSlots, float bhRatio, float windRate) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float4 p = pos[i];
    if (p.x < 0.f) return;                   // 삼켜졌거나 빈 자리

    // ── 폭발 중이면 시간만 흘려보낸다 ──────────────────────────────────
    if (p.w < 0.f) {
        p.w += dt;                            // 음수가 0 을 향해 올라온다
        if (p.w >= 0.f) {
            // 다 탔다. **심이 남는지 아닌지는 터질 때 이미 정해져 `vel.w` 에 적혀 있다.**
            //   -2 = 중성자별 심   ·   그 밖 = 가스로 돌아간다(사슬이 닫히는 자리)
            // 커널 안에서 알갱이를 둘로 쪼갤 수 없어, 하나가 심이거나 바깥층이거나다.
            if (vel[i].w < -1.5f) {
                // 찬드라세카르 한계 위·TOV 한계 아래. 실제 중성자별이 1.4 M☉ 근처에
                // 몰려 있는 것은 우연이 아니라 그 두 한계 사이가 좁기 때문이다.
                p.w = sunMass * 1.4f;
            } else {
                p.w = 0.f;
            }
        }
        pos[i] = p;
        return;
    }
    if (p.w == 0.f) return;                   // 가스는 늙지 않는다

    float4 v = vel[i];
    if (v.w < 0.f) return;                    // 잔해는 더 이상 안 늙는다

    v.w += dt;
    // 질량이 클수록 수명이 급격히 짧다. powf 가 비싸 보이지만 별인 알갱이만 지나므로
    // 실제로 도는 수는 전체의 일부다.
    float ratio = fmaxf(p.w / sunMass, 1e-3f);

    // ── 별풍 — **별은 죽을 때만 질량을 돌려주는 게 아니다** ──────────────────
    //
    // 태양도 초당 100만 톤을 잃고, O형 별은 **수명 동안 절반까지** 잃는다. 그 바람이
    // 실제 은하에서 가스를 되돌리는 큰 몫이고, 이 판에는 그것이 없어서 별이 되면 죽을
    // 때까지 아무것도 안 돌려줬다.
    //
    // 잃는 속도는 밝기에 붙는다(복사압이 바깥층을 밀어낸다) — 실제 `Ṁ ∝ L^1.6` 이라
    // 질량으로는 매우 가파르다. 여기서는 `ratio` 에 선형으로 둔다. **곱의 최댓값에 상한이
    // 있어야 하고**(에딩턴 한계 150 에서 잘린다) 지수를 올리면 그 상한이 흐려진다.
    //
    // **다 날리면 가스로 돌아간다.** 실제로는 심이 남지만(그것이 백색왜성이고 수명 끝에
    // 따로 만든다), 알갱이 하나로 심과 바깥층을 동시에 표현할 수 없다. 무거운 별일수록
    // 빨리 가벼워지고, 가벼워지면 `T ∝ M^-2.5` 로 수명이 늘어 **최후가 바뀐다** —
    // 블랙홀이 될 뻔한 별이 중성자별로 끝나는 것도 실제로 일어나는 일이다.
    if (windRate > 0.f) {
        p.w -= p.w * windRate * ratio * dt;
        if (p.w < sunMass * 0.05f) {          // 다 날아갔다 — 사슬이 여기서도 닫힌다
            pos[i] = make_float4(p.x, p.y, p.z, 0.f);
            vel[i] = make_float4(v.x, v.y, v.z, 0.f);
            return;
        }
        ratio = fmaxf(p.w / sunMass, 1e-3f);  // 줄어든 질량으로 수명을 다시 잰다
    }
    const float life  = sunLifeSim * powf(ratio, -2.5f);

    if (v.w > life) {
        // ── 최후 ────────────────────────────────────────────────────
        // 질량이 셋을 가른다. 지금은 잔해 둘을 「작고 흰 점」으로 뭉뚱그린다(스펙의 미룬 것).
        if (ratio < 8.0f) {
            // 백색왜성 — 껍질을 날리고 심만 남는다. 남은 심은 더 이상 안 늙는다.
            p.w *= 0.1f;
            v.w = -1.0f;
        } else {
            // 중성자별·블랙홀 후보는 **터진다.** 바깥층이 날아가고 그 자리가 가스로 돌아온다.
            // 블랙홀 전환은 자리가 여덟뿐이라 별도 판정이 필요하고, 이번 증분에서는
            // 폭발까지만 한다(스펙의 「최후가 셋으로 갈린다」는 아직 미충족).

            // **재를 뿌린다 — 사슬의 마지막 고리다.**
            // 무거운 별일수록 많이 뿌린다(질량에 비례). 이 재가 쌓인 칸은 잘 식고,
            // 식으면 σ² 가 내려가고, Jeans 문턱 `ρ > k_J·σ²` 가 저절로 낮아져
            // **다음 세대는 더 작은 별이 된다.** 그 규칙을 따로 적지 않는다.
            if (ashGrid) {
                const int ax_ = min(max((int)(p.x * G), 0), G - 1);
                const int ay_ = min(max((int)(p.y * G), 0), G - 1);
                const int az_ = min(max((int)(p.z * G), 0), G - 1);
                atomicAdd(&ashGrid[gidx3(ax_, ay_, az_, G, G, periodic)], p.w * ashYield);
            }

            // **가장 무거운 것만 블랙홀이 된다.** 중심이 무너져 심만 남고 바깥층은 날아간다.
            //
            // 커널은 `addBlackHole` 을 못 부르므로(호스트 함수) 자리와 질량만 남기고,
            // 호스트가 스텝 끝에서 읽어 만든다. **자리가 여덟뿐이라 넘치면 만들지 않고
            // 중성자별로 남긴다** — 기존 `addBlackHole` 처럼 가장 가벼운 것을 밀어내면
            // 그 블랙홀이 삼킨 질량이 소리 없이 사라져 보존이 깨진다.
            if (ratio >= bhRatio && bhCand && bhCandN) {
                const int slot = atomicAdd(bhCandN, 1);
                if (slot < bhSlots) {
                    // **바깥층은 날아간다 — 블랙홀도 초신성을 거쳐 생긴다.**
                    //
                    // 전에는 별 전체를 블랙홀에 넣고 그 자리에서 `return` 했다. 그래서
                    // 블랙홀이 되는 별만 **폭발을 건너뛰었고**, 화면에서는 아무 일 없이
                    // 갑자기 블랙홀이 나타났다 — 2026-08-17 사용자가 「블랙홀이 만들어지는
                    // 순간 폭발은 안 보인다」고 알린 것이 이것이다. 바로 위 주석이
                    // 「바깥층은 날아간다」라고 적어 두고도 코드가 안 날렸다.
                    //
                    // 실제 II형 초신성은 심만 무너져 블랙홀이 되고 나머지는 날아간다.
                    // 25 태양질량 별이 남기는 블랙홀이 10 태양질량 남짓이라 **4할이
                    // 심이고 6할이 날아간다.** 날아간 몫은 폭발로 보이다가 가스로 돌아가
                    // 다음 별의 재료가 된다 — 사슬이 여기서 끊기지 않는다.
                    bhCand[slot] = make_float4(p.x, p.y, p.z, p.w * 0.4f);
                    // **속도를 함께 넘긴다 — 이것이 없어 블랙홀이 은하 밖으로 튀어나갔다.**
                    //
                    // 여태 자리와 질량만 넘겼고, 받는 쪽(`addBlackHole`)이 구조체를 통째로
                    // 0 으로 밀고 시작해 **속도가 사라졌다.** 은하 회전 속도 0.25 로 돌던
                    // 별이 블랙홀이 되는 순간 그 자리에 멎는 것이라, 각운동량이 없어 중심으로
                    // 곧장 떨어지고 반대편으로 솟아 판 밖으로 나간다. 한 번 나가면 그 자리
                    // 밀도가 0 이라 동역학적 마찰의 `ga[i].w > 0` 조건이 거짓이 되어 **영원히
                    // 직진한다.** 2026-08-18 실측: 중심에서 0.46, 각운동량 0.002 로 회전을
                    // 물려받았을 때 기댓값(0.115)의 1.7% 였다.
                    //
                    // **운동량 보존이다.** 심이 무너지고 바깥층이 구형으로 날아가면 심의
                    // 속도는 원래 속도 그대로다. 실제 초신성 킥(natal kick)이 여기 더해지지만
                    // 그것은 수백 km/s 로 은하 회전(220 km/s)과 같은 규모라, 실제 항성질량
                    // 블랙홀은 은하 원반 안에 남아 계속 돈다.
                    //
                    // `v.w` 는 나이라 블랙홀에는 뜻이 없다 — xyz 만 쓴다.
                    if (bhCandV) bhCandV[slot] = make_float4(v.x, v.y, v.z, 0.f);
                    p.w = -explodeSim;      // 남은 바깥층이 폭발한다
                    // 심은 이미 블랙홀이 됐으므로 잔해를 또 남기지 않는다.
                    vel[i].w = 0.f;
                    pos[i] = p;
                    return;
                }
                // 자리가 없다. 세어 두고 아래로 떨어져 중성자별처럼 터지기만 한다.
                if (bhBlocked) atomicAdd(bhBlocked, 1);
            }

            p.w = -explodeSim;                // 폭발 시작 — 이 시간 동안 보인다

            // **심이 남을지를 질량비가 정한다.** 실제 초신성은 1.4 M☉ 남짓의 심을 남기고
            // 나머지를 통째로 뿌린다. 알갱이 하나는 둘 중 하나만 될 수 있으므로, 그 알갱이가
            // 심이 될 확률을 **심 질량 ÷ 원래 질량**으로 둔다 — 무리 전체로 보면 남는 심의
            // 총 질량이 실제 비율과 같아진다. 무거운 별일수록 뿌리는 양이 많아 확률이 낮은
            // 것도 실제 그대로다(24 M☉ 이면 17.5%, 60 M☉ 이면 7%).
            //
            // **전부 남기면 안 되는 이유가 하나 더 있다** — 폭발이 가스로 돌아가는 것이
            // 「사슬이 닫힌다」의 마지막 고리다. 다 심으로 남기면 다음 세대의 재료가 없다.
            // 2026-08-17 실측에서 이미 `cGas` 가 0 까지 내려가 있었다.
            unsigned hc = (unsigned)i * 1103515245u + 12345u;
            hc ^= hc >> 16; hc *= 2246822519u; hc ^= hc >> 13;
            const float rc = (float)(hc & 0x00FFFFFFu) * (1.0f / 16777216.0f);
            // `p.w` 는 바로 위에서 음수(남은 폭발 시간)로 덮였다 — 원래 질량은 `ratio` 에 있다.
            const float coreFrac = fminf(1.4f / ratio, 1.0f);
            v.w = (rc < coreFrac) ? -2.0f : 0.f;

            // 바깥 방향으로 튕긴다. **어느 쪽이 바깥인지 모르므로 알갱이 번호 해시로
            // 방향을 정한다** — 통계적으로 등방이라 무리 전체로 보면 사방으로 흩어진다.
            // 같은 알갱이는 언제나 같은 방향이라 판이 볼 때마다 달라지지 않는다
            // (`kInitCharge` 가 쓰는 것과 같은 수법).
            unsigned h = (unsigned)i * 2654435761u + seed;
            h ^= h >> 13; h *= 1274126177u; h ^= h >> 16;
            const float a = (float)(h & 0xFFFF) * (6.2831853f / 65536.0f);   // 방위각
            const float z = (float)((h >> 16) & 0xFFFF) * (2.0f / 65536.0f) - 1.0f;  // cos(극각)
            const float r = sqrtf(fmaxf(1.0f - z * z, 0.f));
            v.x += kickSpeed * r * __cosf(a);
            v.y += kickSpeed * r * __sinf(a);
            v.z += kickSpeed * z;
        }
        vel[i] = v;
        pos[i] = p;
        return;
    }
    vel[i] = v;
}

// 별이 몇 개인지 센다. `starCount()` 가 불릴 때만 돈다 — 매 스텝 세면 그 자체가 비용이다.
//
// 블록 안에서 모으고 블록마다 한 번만 전역에 더한다(kCountAlive 와 같은 수법).
// 알갱이를 상태별로 세고, 못 쓰게 된 값(NaN·무한대)도 함께 잡는다.
//
// **비용**: N 스레드 × O(1). `starCount()` 처럼 부를 때만 돈다.
//
// **이 커널이 「알갱이가 사라지거나 생기지 않는다」를 증명하는 유일한 수단이다.**
// 가스 + 별 + 폭발중 + 잔해 + 삼킨 수 = 총 알갱이 수 여야 한다. 이 등식이 깨지면
// 어딘가에서 상태 판정이 겹치거나(두 번 세거나) 빈다는 뜻이고, 그것은 곧 물리가 아니라
// 회계가 틀렸다는 신호다.
//
// 상태는 두 축으로 갈린다(design.md 1장):
//   pos.w   0 = 가스 · >0 = 별 · <0 = 폭발 중
//   vel.w   ≥0 = 나이 · <0 = 잔해
// **잔해를 먼저 본다** — 잔해는 `pos.w > 0` 이기도 해서 별과 겹치기 때문이다.
__global__ void kCountStates(const float4* pos, const float4* vel, int n,
                             int* out /* [5]: 가스·별·폭발·잔해·못쓸값 */) {
    // **블록 안에 모으지 않고 전역에 바로 더한다.**
    //
    // 처음에는 `kCountAlive` 처럼 shared 배열에 모아 블록마다 한 번씩 전역에 더했는데,
    // 값이 전부 0 으로 나왔다(2026-08-16 실측). shared 배열 다섯 칸을 앞 다섯 스레드가
    // 초기화하고 나머지 251개가 거기 원자 연산을 하는 구조였다.
    //
    // 여기서는 그 최적화를 포기한다. `starCount()` 처럼 **부를 때만 도는 커널**이라
    // 매 프레임 비용이 아니고, 전역 원자 연산 100만 회는 그 자리에서 감당된다.
    // 정확한 값이 안 나오는 최적화보다 느려도 맞는 쪽이 낫다.
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;                         // 삼켜졌거나 빈 자리는 세지 않는다

    const float4 v = vel[i];
    if (!isfinite(p.x) || !isfinite(p.y) || !isfinite(p.z) ||
        !isfinite(v.x) || !isfinite(v.y) || !isfinite(v.z)) {
        atomicAdd(&out[4], 1);                     // 못 쓸 값 — 하나라도 있으면 실패다
    } else if (v.w < -50.f) {
        // 암흑물질. **잔해보다 먼저 본다** — 표시가 음수라 안 그러면 잔해로 세어진다.
        atomicAdd(&out[6], 1);
    } else if (v.w < 0.f) {
        atomicAdd(&out[3], 1);                          // 잔해(별보다 먼저 본다)
        // 잔해 안에서 중성자별만 따로 센다 — 「넷을 눈으로 가른다」를 판정하려면
        // 그것이 실제로 몇 개 남는지 밖에서 볼 수 있어야 한다. **out[3] 에 포함된
        // 수라 총합 검사(가스+별+폭발+잔해=전체)를 깨지 않는다.**
        if (v.w < -1.5f) atomicAdd(&out[5], 1);
    }
    else if (p.w < 0.f)        atomicAdd(&out[2], 1);   // 폭발 중
    else if (p.w > 0.f)        atomicAdd(&out[1], 1);   // 별
    else                       atomicAdd(&out[0], 1);   // 가스
}

// **분산 텐서의 교차항이 정말 무시할 만한가** — 격자를 여섯으로 늘릴지 정하는 창.
//
// 설계 때 「원반에서 지배적인 것은 대각 성분」이라 보고 대각 셋만 들었다. 그것은 **추정**
// 이었고, 이 커널이 그 추정을 실측으로 바꾼다. 격자를 안 늘린다 — 칸마다 값이 필요한 게
// 아니라 **판 전체의 비 하나**만 알면 되므로 합만 모은다.
//
// `kCoolCell` 과 같은 방식으로 칸 평균에서의 차를 구하되, `|dvx·dvy|` 와 `dvx²` 의 합을
// 견준다. 절댓값을 쓰는 이유: 교차항은 부호가 섞여 그냥 더하면 **상쇄돼 0 으로 보인다.**
// 크기가 실제로 작은 것과 부호가 섞인 것은 다르다.
//
// **비용**: N 스레드 × 원자 연산 셋. `starCount()` 처럼 부를 때만 돈다.
__global__ void kCrossTerms(const float4* pos, const float4* vel, int n, int G, int periodic,
                            const float* sumX, const float* sumY, const float* sumZ,
                            const float* cnt, double* out) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    const float4 v = vel[i];
    if (v.w < -50.f) return;                      // 암흑물질은 이 통계에 안 든다
    if (!isfinite(v.x) || !isfinite(v.y) || !isfinite(v.z)) return;
    const int cx = min(max((int)(p.x * G), 0), G - 1);
    const int cy = min(max((int)(p.y * G), 0), G - 1);
    const int cz = min(max((int)(p.z * G), 0), G - 1);
    const int c  = gidx3(cx, cy, cz, G, G, periodic);
    const float nc = cnt[c];
    if (nc < 2.f) return;
    const float inv = 1.f / nc;
    const float dvx = sumX[c] * inv - v.x;
    const float dvy = sumY[c] * inv - v.y;
    const float dvz = sumZ[c] * inv - v.z;
    atomicAdd(&out[0], (double)(fabsf(dvx * dvy) + fabsf(dvy * dvz) + fabsf(dvz * dvx)));
    atomicAdd(&out[1], (double)(dvx * dvx + dvy * dvy + dvz * dvz));
    atomicAdd(&out[2], 1.0);
    // **부호를 살린 합.** 위 절댓값 합과 견주면 「크기가 작은 것」과 「부호가 섞여
    // 상쇄되는 것」을 가를 수 있다 — 격자에 쌓으면 실제로 일어나는 것은 후자다.
    atomicAdd(&out[3], (double)(dvx * dvy + dvy * dvz + dvz * dvx));
}

// **회전곡선** — 반지름 구간별 접선 속도의 평균. 암흑물질이 있는지 보는 창이다.
//
// 보이는 물질만 있으면 바깥으로 갈수록 도는 속도가 케플러처럼 `v ∝ 1/√r` 로 떨어져야 한다.
// 실제 은하는 **바깥에서도 안 떨어지고 평평하다** — 그것이 암흑물질 존재의 첫 증거였다
// (1970년대 루빈의 관측). 보이는 별만으로는 바깥 별이 그렇게 빨리 돌 수 없다.
//
// 접선 성분만 센다 — 안팎으로 떨어지는 속도는 회전이 아니다.
// **비용**: N 스레드 × 원자 연산 둘. `starCount()` 처럼 부를 때만 돈다.
__global__ void kRotationCurve(const float4* pos, const float4* vel, int n,
                               float cx, float cy, double* out) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    const float dx = p.x - cx, dy = p.y - cy;
    const float r = sqrtf(dx * dx + dy * dy);
    if (r < 1e-4f || r > 0.45f) return;
    const float4 v = vel[i];
    if (!isfinite(v.x) || !isfinite(v.y)) return;
    // 네 구간: ~0.1125, ~0.225, ~0.3375, ~0.45
    const int b = min((int)(r / 0.1125f), 3);
    const float vt = fabsf((-dy * v.x + dx * v.y) / r);
    atomicAdd(&out[b], (double)vt);
    atomicAdd(&out[4 + b], 1.0);
}

// 재를 **반지름 구간별로** 모은다. 「금속 기울기」가 생기는지 보는 창이다.
//
// 실제 은하는 중심이 금속(무거운 원소)이 진하고 바깥이 옅다 — 중심에서 별이 더 많이
// 태어나고 더 많이 죽었기 때문이다. **그것을 코드에 적지 않았으므로, 나오면 창발이다.**
//
// **비용**: 격자 칸 수 × O(1). 부를 때만 돈다.
__global__ void kAshRadial(const float* ash, int G, float* outSum, float* outCnt, int bins) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= G || y >= G || z >= G) return;

    // 판 중앙(0.5, 0.5, 0.5)에서의 거리. 원반은 xy 평면이므로 **반지름은 xy 로만 잰다** —
    // z 를 넣으면 원반 위아래로 벗어난 것이 「바깥」으로 잘못 분류된다.
    const float fx = ((float)x + 0.5f) / (float)G - 0.5f;
    const float fy = ((float)y + 0.5f) / (float)G - 0.5f;
    const float r  = sqrtf(fx * fx + fy * fy);      // 0 ~ 0.707

    int b = (int)(r / 0.5f * (float)bins);          // 0.5 를 판 반지름으로 본다
    if (b >= bins) b = bins - 1;

    const float a = ash[(z * G + y) * G + x];
    if (a > 0.f) { atomicAdd(&outSum[b], a); atomicAdd(&outCnt[b], 1.0f); }
}

// 모든 알갱이에서 평균 속도를 뺀다 — **무게중심을 정지시킨다.**
//
// 판을 깔 때 궤도 속도·회전·난수를 주고 나면 그 합이 정확히 0 이 되지 않는다. 그 나머지가
// **판 전체를 한 방향으로 밀어**, 은하가 통째로 흘러가 판 모서리에 붙는다.
// 2026-08-16 실측: 70초에 은하 중심이 (0.5,0.5) 에서 **(0.983, 0.859)** 까지 갔다.
//
// 그때 화면으로는 「판이 퍼졌다」처럼 보이지만 실제로는 **뭉친 채로 이사한 것**이고,
// 판 중앙을 기준으로 재는 모든 값(반지름 분포·금속 기울기)이 통째로 어긋난다.
//
// N체 시뮬레이션에서 무게중심을 정지시키는 것은 표준 관행이다 — 전체가 등속으로 움직이는
// 것은 물리적으로 아무 뜻이 없고(갈릴레이 불변) 화면만 망친다.
__global__ void kSubtractMeanVel(float4* vel, const float4* pos, int n, float3 mean) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n || pos[i].x < 0.f) return;
    float4 v = vel[i];
    v.x -= mean.x; v.y -= mean.y; v.z -= mean.z;
    vel[i] = v;
}

// 알갱이를 반지름 구간별로 센다.
//
// **재 분포가 「진짜 역전」인지 「측정 착시」인지 가르는 판별식이다.**
// 판이 한 점으로 뭉치면 안쪽 구간에 알갱이가 거의 다 들어가고 바깥에는 흩어진 소수만
// 남는데, 그때 「칸당 평균 재」는 바깥이 부풀 수 있다 — 재를 뿌린 칸이 몇 개뿐이라서다.
// 알갱이 수를 함께 보면 그 착시가 드러난다.
__global__ void kParticleRadial(const float4* pos, int n, float* outCnt, int bins) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    // 원반은 xy 평면이므로 반지름도 xy 로만 잰다(kAshRadial 과 같은 규칙이어야 견줄 수 있다).
    const float fx = p.x - 0.5f, fy = p.y - 0.5f;
    int b = (int)(sqrtf(fx * fx + fy * fy) / 0.5f * (float)bins);
    if (b >= bins) b = bins - 1;
    if (b < 0) b = 0;
    atomicAdd(&outCnt[b], 1.0f);
}

// 나선 진폭을 재는 반지름 링 개수. 링 하나가 (0.5−0.1)/16 = 0.025 —
// 그 안에서는 pitch 10° 짜리 팔도 m=2 위상이 0.18 rad(10°) 밖에 안 감겨 지워지지 않는다.
static constexpr int kSpiralBins = 16;

// 나선팔이 생겼는지 **수치로** 잰다 — 밀도의 m=2 푸리에 진폭.
//
// 두 팔 구조는 밀도가 각도에 대해 `1 + A·cos(2θ + φ)` 로 변조된다는 뜻이다.
// 그 A 를 재려면 `Σ ρ·e^{2iθ}` 를 밀도 합으로 나누면 된다:
//
//   A2 = |Σ ρ(cos2θ + i·sin2θ)| / Σ ρ
//
// **중심 근처는 뺀다.** r 이 작으면 각도가 불안정하고(중심 한 칸은 모든 각도를 갖는다)
// 팽대부가 팔과 무관하게 밝아 A2 를 흐린다.
//
// ── 반지름을 통틀어 합치면 나선을 못 잰다 (2026-08-19 에 알았다) ──────────
//
// 예전에는 r=0.1~0.5 를 **한 덩어리로** 합쳐 A2 하나를 냈다. 그것이 틀렸다.
// 나선은 반지름마다 팔의 각도가 감기는 구조다 — 그 감김이 나선의 정의다.
// 통째로 합치면 안쪽 팔과 바깥 팔의 위상이 서로 지운다.
//
// 합성 데이터로 쟀다(같은 진하기의 팔을 넣고 예전 식과 링별 식을 견줬다):
//
//   모양                    예전 식   링별 식   예전/링별
//   막대(위상 안 감김)        0.2499   0.2497     1.00
//   나선 pitch 40°           0.1729   0.2491     0.69
//   나선 pitch 20°(전형적)    0.0921   0.2463     0.37   ← 63% 가 지워진다
//   나선 pitch 10°           0.0439   0.2340     0.19   ← 81% 가 지워진다
//
// **예전 식은 막대를 1.00 배로, 나선을 0.19~0.69 배로 쟀다.** 나선일수록 작게 나오니,
// 이 값이 오르내리는 것을 보고 「팔이 생겼다 풀렸다」로 읽으면 사실은 **막대가 생겼다
// 풀렸다** 하는 것을 본 것이다. 실제로 그렇게 읽고 열한 번을 헤맸다.
//
// 그래서 링마다 따로 모은다. 링 안에서는 팔의 각도가 거의 같아 지워지지 않는다.
// 부르는 쪽이 링별로 나눈 뒤 평균하면 나선 진폭이고, 링을 다 더한 뒤 나누면
// 예전 값(= 막대 진폭)이 그대로 나온다 — 둘 다 이 한 번의 훑기로 나온다.
//
// ── 격자가 아니라 **알갱이에서 직접** 잰다 (2026-08-19 에 옮겼다) ──────────
//
// 예전에는 밀도 격자 `rho` 를 훑었다. 그것이 값을 두 개로 갈라 놓고 있었다.
//
// `rho` 는 **스텝 중에 다른 용도로 빌려 쓰인다** — 격자를 하나 더 잡지 않으려고
// 압력 쪽에서 `cellCnt`(칸에 직접 센 개수)를 그 위에 복사해 넣는다(`step` 안).
// 그래서 `measureEmergence` 가 언제 불리느냐에 따라 **CIC 로 부드럽게 뿌린 개수 밀도**
// 를 읽기도 하고 **칸에 딱 떨어지게 센 개수**를 읽기도 했다. 둘은 다른 분포다.
//
// 실측(2026-08-19): 판을 세워 두고 0.4초 간격으로 열 번 읽으니 값이 두 무리로 갈렸다 —
// 진폭 0.28 대(pitch 26°)와 0.43 대(pitch 60~66°)가 번갈아 나왔고, **각 무리 안에서는
// 매끄럽게 이어졌다.** 잡음이 아니라 서로 다른 두 신호를 번갈아 본 것이다.
// 어제 나선팔을 열한 번 시험하며 본 「요동」의 상당 부분이 이것이었다.
//
// 알갱이에서 직접 재면 빌려 쓰는 격자를 아예 안 거친다. 곁들여 격자 해상도에도
// 안 묶이고, 비용도 준다(격자 훑기 630만 → 300만 원자연산).
//
// ── 질량과 **빛**을 따로 잰다 ──────────────────────────────────────────────
//
// **눈에 보이는 나선팔은 질량이 몰린 것이 아니라 빛이 몰린 것이다.** 실제 은하에서
// 팔의 질량 대비는 10~20% 밖에 안 되는데 사진에서 뚜렷한 것은, 팔에서 가스가 압축돼
// 별이 새로 태어나고 갓 난 무거운 별이 `L ∝ M^3.5` 로 압도적으로 밝기 때문이다.
// 그 별들은 수명이 짧아 팔을 벗어나기 전에 죽으므로 팔에 갇혀 보인다.
//
// 관측도 그래서 파장을 갈라 본다 — 근적외선(늙은 별 = 질량)으로는 부드럽고 넓은
// 구조가, 푸른빛(젊은 별)으로는 좁고 뚜렷한 팔이 나온다. **둘은 다른 그림이고
// pitch 도 다를 수 있다.** 그래서 여기서도 둘 다 낸다.
//
// **암흑물질은 뺀다.** 구형으로 퍼져 m=2 가 0 인데 분모만 키워 팔 신호를 희석한다
// (`v.w < -50` 이 그 표시 — `kCountStates` 와 같은 규칙).
//
// 비용: N 스레드 × 최대 6 atomicAdd = 6N. N=100만이면 600만 회. status 를 물을 때만 돈다.
__global__ void kSpiralM2(const float4* pos, const float4* vel, int n, int bins,
                          float sunMass,
                          double* out /* [0..3B): 질량, [3B..6B): 빛 — 링마다 re,im,sum */) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;                          // 죽은 자리
    const float4 v = vel[i];
    if (v.w < -50.f) return;                        // 암흑물질 — 구형이라 신호를 흐린다

    const float fx = p.x - 0.5f, fy = p.y - 0.5f;   // 판 중심이 (0.5, 0.5)
    const float r2 = fx * fx + fy * fy;
    if (r2 < 0.01f || r2 > 0.25f) return;           // 반지름 0.1~0.5 만 본다

    // 0.1~0.5 를 bins 등분. 위쪽 경계(r=0.5)가 그대로 bins 가 되므로 잘라 준다 —
    // 안 자르면 out 배열 밖에 쓴다(이 판에서 배열 밖 쓰기는 시스템을 재부팅시킨다).
    int b = (int)((sqrtf(r2) - 0.1f) / 0.4f * (float)bins);
    if (b < 0) b = 0;
    if (b >= bins) b = bins - 1;

    const float th2 = 2.0f * atan2f(fy, fx);
    const float c = __cosf(th2), s = __sinf(th2);

    // 질량 쪽 — 가스·별·잔해를 고르게 하나씩(`kScatter` 도 질량을 안 곱하고 개수를 뿌린다).
    atomicAdd(&out[3 * b + 0], (double)c);
    atomicAdd(&out[3 * b + 1], (double)s);
    atomicAdd(&out[3 * b + 2], 1.0);

    // 빛 쪽 — 별만, `kScatterLight` 와 같은 식으로 밝기를 매긴다.
    // 잔해(`v.w < 0`)는 뺀다: 백색왜성은 반지름이 태양의 100분의 1 이라 같은 질량비를
    // 주계열 식에 넣으면 만 배 밝게 세어진다.
    if (p.w > 0.f && v.w >= 0.f) {
        const double lum = (double)__powf(fmaxf(p.w / sunMass, 1e-3f), 3.5f);
        const int o = 3 * bins;
        atomicAdd(&out[o + 3 * b + 0], lum * (double)c);
        atomicAdd(&out[o + 3 * b + 1], lum * (double)s);
        atomicAdd(&out[o + 3 * b + 2], lum);
    }
}

// 한 칸에 알갱이가 얼마나 몰렸는지 — **원자 연산 경합의 선행 지표다.**
// 이 값이 치솟는 순간이 곧 커널 하나가 수십 배 느려지는 순간이고, 그것이 드라이버
// 타임아웃으로 이어진 것이 2026-08-14 재부팅의 경로였다.
__global__ void kMaxCellCount(const int* cellStart, const int* cellEnd, int cells, int* out) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= cells) return;
    const int s0 = cellStart[i], e0 = cellEnd[i];
    if (s0 < 0 || e0 <= s0) return;
    atomicMax(out, e0 - s0);
}

// 총 운동량. **폭발이 없던 운동량을 만들지 않는지** 보는 창이다.
// 등방으로 뿌리므로 무리 전체의 합은 폭발 전후로 크게 안 변해야 한다.
__global__ void kMomentumAccum(const float4* pos, const float4* vel, int n, double* out) {
    // 위 `kCountStates` 와 같은 이유로 shared 배열을 안 쓴다.
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n || pos[i].x < 0.f) return;
    const float4 v = vel[i];
    if (!isfinite(v.x) || !isfinite(v.y) || !isfinite(v.z)) return;
    atomicAdd(&out[0], (double)v.x);
    atomicAdd(&out[1], (double)v.y);
    atomicAdd(&out[2], (double)v.z);
    // 개수도 같이 센다 — 매 스텝 무게중심을 세우려면 평균을 GPU 안에서 내야 하고,
    // 그러려면 나눌 수도 GPU 안에 있어야 한다. 호스트로 가져와 나누면 스텝마다
    // `cudaMemcpy` 동기화가 들어가 GPU 가 그때마다 멈춘다.
    // **부르는 쪽은 out 을 네 칸으로 비워야 한다** — 세 칸만 비우면 넷째에 지난 값이 남는다.
    atomicAdd(&out[3], 1.0);
}

// 모든 알갱이에서 평균 속도를 뺀다. 위 `kSubtractMeanVel` 과 같은 일이지만 평균을
// 호스트가 아니라 **GPU 안에서** 읽는다 — 매 스텝 돌릴 것이라 동기화가 있으면 안 된다.
//
// **왜 매 스텝인가.** reset 때 한 번 빼는 것으로는 못 잡는다. 2026-08-16 실측에서
// 알짜 운동량을 만드는 것은 초기 배치가 아니라 **매 스텝 도는 냉각**이었다
// (냉각만 켠 판이 40초에 0.303 이사, 운동량 128,426. 압력만·별만 켠 판은 0.0003 · 211 · 0.2).
//
// 냉각이 운동량을 안 지키는 이유는 `kCool` 에 적었다. 여기서는 그 결과를 지운다 —
// **판 전체가 등속으로 흐르는 것은 물리적으로 아무 뜻이 없고**(갈릴레이 불변) 화면만
// 망친다. N체 시뮬레이션에서 무게중심을 정지시키는 것은 표준 관행이다.
//
// 비용: N 스레드 × O(1). 앞의 `kMomentumAccum` 과 합쳐 5N 인데, `kCool` 이 이웃을
// 96개까지 훑는 96N 에 비하면 5% 다.
__global__ void kSubtractMeanVelDev(float4* vel, const float4* pos, int n, const double* acc) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n || pos[i].x < 0.f) return;
    const double cnt = acc[3];
    if (cnt < 1.0) return;
    float4 v = vel[i];
    v.x -= (float)(acc[0] / cnt);
    v.y -= (float)(acc[1] / cnt);
    v.z -= (float)(acc[2] / cnt);
    vel[i] = v;
}

// 판 벽에 붙어 있는 알갱이를 센다.
//
// **왜 필요한가.** 고립 경계는 판 끝에서 알갱이를 붙잡고(`p.x = 0.998f`) 벽에 **수직인**
// 속도만 죽인다 — 나란한 성분은 그대로라 알갱이가 벽면을 타고 미끄러진다. 화면에서
// 「보이지 않는 벽을 타고 이동하는」 것으로 보이고, 실제로 그렇게 보인다는 지적을 받았다.
//
// 고치는 방향(판을 떠난 것은 안 돌아오게 지운다)을 고르기 전에 **몇 개나 되는지** 알아야
// 한다. 몇 개 안 되면 지워도 표가 안 나지만, 판이 통째로 퍼져 벽에 밀리는 중이라면
// 지우는 순간 알갱이가 계속 사라진다. 그 둘은 수를 세야만 갈린다.
//
// 벽에 「붙었다」의 기준은 붙잡는 자리(0.002 / 0.998)에서 격자 한 칸 안쪽까지다 —
// 정확히 그 값만 세면 부동소수 때문에 놓친다.
//
// 비용: N 스레드 × O(1).
__global__ void kCountAtWall(const float4* pos, int n, float margin, int* out) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    const bool atWall = (p.x < margin) || (p.x > 1.f - margin) ||
                        (p.y < margin) || (p.y > 1.f - margin) ||
                        (p.z < margin) || (p.z > 1.f - margin);
    if (atWall) atomicAdd(out, 1);
}

// 원반이 실제로 얼마나 두꺼운지 — **공간** 두께다.
//
// 방향별 속도 분산(`dispZZ`)이 「위아래로 덜 밀린다」를 말한다면 이 값은 그래서
// **판이 실제로 얼마나 얇은가**를 말한다. 둘은 다른 것이라 하나가 다른 하나를 대신하지
// 못한다 — 속도가 작아도 처음부터 두껍게 깔았으면 두껍고, 속도가 커도 중력이 되당기면
// 얇을 수 있다. 「`diskThickness` 를 손으로 안 정해도 두께가 생기는가」는 공간 쪽 질문이다.
//
// 표준편차라 √(E[z²] − E[z]²) 이고, 그러려면 z 합·z² 합·개수 셋이 필요하다.
// **평균을 0.5 로 가정하지 않는다** — 판이 통째로 위아래로 옮겨 가도 두께는 그대로여야
// 하고, round-19 에서 은하가 실제로 판 밖으로 나가는 것을 봤다.
//
// 비용: N 스레드 × 3 atomicAdd = 3N. N=100만이면 300만 회.
__global__ void kDiskThickness(const float4* pos, int n, double* out) {
    // 위 `kCountStates`·`kMomentumAccum` 과 같은 이유로 shared 배열을 안 쓴다.
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f || !isfinite(p.z)) return;
    const double z = (double)p.z;
    atomicAdd(&out[0], z);
    atomicAdd(&out[1], z * z);
    atomicAdd(&out[2], 1.0);
}

// 개수와 **질량 합**을 함께 센다. 평균 별 질량이 있어야 「1세대가 나중 세대보다 무거운가」를
// 볼 수 있고, 그것이 재 사슬이 실제로 도는지를 보여 주는 유일한 수치다.
__global__ void kCountStars(const float4* pos, int n, int* outCount, double* outMass) {
    __shared__ int   sn;
    __shared__ double sm;
    if (threadIdx.x == 0) { sn = 0; sm = 0.0; }
    __syncthreads();
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n && pos[i].x >= 0.f && pos[i].w > 0.f) {
        atomicAdd(&sn, 1);
        atomicAdd(&sm, (double)pos[i].w);
    }
    __syncthreads();
    if (threadIdx.x == 0) { atomicAdd(outCount, sn); atomicAdd(outMass, sm); }
}

// 살아 있는 알갱이를 센다.
//
// 블랙홀이 삼킨 것은 자리에 구멍(pos.x < 0)으로 남는다. active 는 「앞쪽 이만큼이
// 유효한 자리」라는 뜻을 겸해서(addShape 가 그 자리부터 뿌린다) 삼킨 만큼 줄일 수가
// 없다 — 줄이면 살아 있는 알갱이를 덮어쓴다. 그래서 보여 줄 수는 따로 센다.
//
// 블록 안에서 먼저 모으고 블록마다 한 번만 전역에 더한다. 알갱이마다 전역 원자 연산을
// 하면 399만 개가 같은 주소에 줄을 서서 그 커널 하나가 프레임을 먹는다.
__global__ void kCountAlive(const float4* pos, int n, int* out) {
    __shared__ int s;
    if (threadIdx.x == 0) s = 0;
    __syncthreads();
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n && pos[i].x >= 0.f) atomicAdd(&s, 1);
    __syncthreads();
    if (threadIdx.x == 0 && s > 0) atomicAdd(out, s);
}

// 알갱이마다 +/- 부호를 준다(전자기력용). temp 배열을 그대로 쓴다 —
// 온도는 이 판에서 계산하지 않고, 정렬·압축이 이미 이 배열을 함께 옮겨 주기 때문이다.
__global__ void kInitCharge(float* charge, int n, unsigned seed) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    unsigned h = (unsigned)i * 2654435761u + seed;
    h ^= h >> 15; h *= 2246822519u; h ^= h >> 13;
    charge[i] = (h & 1u) ? 1.0f : -1.0f;
}

// **약한핵력** — 힘이 아니라 바뀜이다. 부호가 이따금 뒤집힌다(베타 붕괴가 하는 일).
// 전자기력으로 굳어 있던 배치가 스스로 풀려 다시 자리를 잡는 것이 이 힘의 얼굴이다.
__global__ void kWeakDecay(float* charge, const float4* pos, int n, float p, unsigned seed) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    if (pos[i].x < 0.f) return;
    unsigned h = (unsigned)i * 2654435761u + seed;
    h ^= h >> 15; h *= 2246822519u; h ^= h >> 13;
    if ((h & 0xFFFFu) < (unsigned)(p * 65535.0f)) charge[i] = -charge[i];
}

// 판 전체에 회전을 얹는다 — 세로축(z) 을 중심으로 통째로 돈다.
//
// **회전이 없으면 뭉친 것이 공이나 실이 된다.** 중력으로 모일 때 각운동량이 없으면
// 사방에서 곧장 한 점으로 떨어지기 때문이다. 회전이 있으면 그 각운동량이 보존되어
// 한 점으로 못 모이고 축과 나란한 방향으로만 납작해진다 — 그것이 원반이고, 실제
// 은하가 납작한 이유다. 나선팔도 그 원반 위에서 자란다.
//
// 더하는 속도는 ω × r 이다(축에서 멀수록 빠르다). 원궤도 속도를 대신하는 것이 아니라
// 그 위에 얹는 것이라, 장면이 이미 가진 궤도는 그대로 남는다.
__global__ void kAddSpin(const float4* pos, float4* vel, int n, float omega) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    const float dx = p.x - 0.5f, dy = p.y - 0.5f;
    float4 v = vel[i];
    v.x += -omega * dy;
    v.y +=  omega * dx;
    vel[i] = v;
}

// **허블 팽창** — 알갱이를 중심에서 바깥으로, 거리에 비례해 민다(`v = H·r`).
//
// 이것이 우주 그물을 만드는 열쇠다. 팽창이 없으면 판이 통째로 한 점으로 무너져
// 필라멘트가 아니라 공이 된다(2026-08-19 실측: 점유셀 183만 → 5.8만).
// 팽창이 그 전체 붕괴를 붙잡아 두면 **국소 요동만 자라** 그물이 남는다.
//
// 강체 회전(`kAddSpin`)과 달리 **방향이 지름 방향**이라 각운동량을 안 만든다 —
// 실제 우주 팽창도 회전이 아니다.
//
// 비용: N 스레드 × O(1). 판을 깔 때 한 번.
__global__ void kAddHubble(const float4* pos, float4* vel, int n, float H) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    float4 v = vel[i];
    v.x += H * (p.x - 0.5f);
    v.y += H * (p.y - 0.5f);
    v.z += H * (p.z - 0.5f);
    vel[i] = v;
}

// **속도 분산 — 무작위 속도로 구를 떠받친다.**
//
// 팽창 대신 이것으로 무너짐을 막는다. 실제 은하단·타원 은하가 그렇게 버틴다(비리얼 평형)
// — 전체로는 회전도 팽창도 안 하는데, 별들이 제각기 다른 방향으로 도느라 안 무너진다.
//
// 필요한 세기는 비리얼 정리가 정해 준다. 균일 구의 위치에너지가 `U = -(3/5)GM²/R` 이고
// 평형 조건이 `2K + U = 0` 이므로:
//
//   v²_rms = (3/5)·GM/R      R=0.40, GM=0.9 이면 v_rms = 1.16
//
// 방향을 고르게 뽑아야 한다 — 성분마다 따로 난수를 뽑으면 정육면체 쪽으로 치우친다.
// 구면에서 방향을 뽑고 크기를 따로 준다.
//
// 비용: N 스레드 × O(1). 판을 깔 때 한 번.
__global__ void kAddDispersion(const float4* pos, float4* vel, int n, float vrms, unsigned seed) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    if (pos[i].x < 0.f) return;
    const unsigned s = (unsigned)i * 2654435761u + seed;

    // 방향 — 구면에 고르게
    const float cz = rnd01(s * 3u + 1u) * 2.0f - 1.0f;
    const float sz = sqrtf(fmaxf(1.0f - cz * cz, 0.0f));
    const float ph = rnd01(s * 7u + 5u) * 6.2831853f;

    // 크기 — 셋을 더해 가우시안에 가깝게 만든다(중심극한). 평균이 vrms 가 되게 맞춘다.
    const float g = (rnd01(s * 11u + 3u) + rnd01(s * 13u + 7u) + rnd01(s * 17u + 9u)) / 1.5f;

    float4 v = vel[i];
    v.x += vrms * g * sz * __cosf(ph);
    v.y += vrms * g * sz * __sinf(ph);
    v.z += vrms * g * cz;
    vel[i] = v;
}

// 셀 키(정렬용). 빈 슬롯은 -1 로 두어 뒤로 밀린다.
__global__ void kCellKey(const float4* pos, int n, int G, int* keys, int* idx) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    idx[i] = i;
    if (p.x < 0.f) { keys[i] = -1; return; }
    const int cx = min(max((int)(p.x * G), 0), G - 1);
    const int cy = min(max((int)(p.y * G), 0), G - 1);
    const int cz = min(max((int)(p.z * G), 0), G - 1);
    keys[i] = (cz * G + cy) * G + cx;
}

__global__ void kReorder(const float4* srcP, const float4* srcV, const float* srcT,
                         const int* order, float4* dstP, float4* dstV, float* dstT, int n) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const int j = order[i];
    dstP[i] = srcP[j]; dstV[i] = srcV[j];
    if (srcT && dstT) dstT[i] = srcT[j];
}

// ---------------------------------------------------------------------------
// 화면에 넘길 2D 투영
//
// 화면은 위에서 내려다본다. 3D 밀도를 z 방향으로 합치면 「위에서 본 밀도」가 된다 —
// 실제 은하 사진이 그렇게 찍힌다(시선 방향으로 다 겹쳐 보인다).
//
// 비용: G³ 스레드 × 1 atomicAdd. G=128 이면 200만 회.
// ---------------------------------------------------------------------------
// 보는 방향. 화면은 오래 「위에서 곧장 내려다보는」 하나뿐이었는데, 3D 가 되고 나니
// 그 한 방향으로는 두께가 보이지 않는다 — 나선팔이 원반인지 공인지 알 수가 없다.
//
// on 이 0 이면 예전 경로 그대로 z 로 곧장 합친다. 각도를 안 돌린 사람에게 회전 계산
// 비용을 물리지 않으려는 것이다(격자 209만 칸을 매 프레임 도는 자리다).
// (`ViewRot`·`rotPoint` 를 `ViewRot.h` 로 옮겼다 — 2026-08-18. 여기에만 있어서 점
//  렌더(`RenderField.cu` 의 `kSplatPoints`)가 회전을 못 받았고, 화면이 통째로 점 렌더인
//  배율에서는 우클릭이 아무 일도 하지 않았다. 자세한 근거는 그 헤더 주석.)

// 격자 칸 하나를 같은 규칙으로 옮긴다.
__device__ inline bool rotCell(int x, int y, int z, int G, const ViewRot& r,
                               int& sx, int& sy) {
    const float inv = 1.0f / (float)G;
    float ox, oy;
    if (!rotPoint((x + 0.5f) * inv, (y + 0.5f) * inv, (z + 0.5f) * inv, r, ox, oy))
        return false;
    sx = (int)(ox * (float)G);
    sy = (int)(oy * (float)G);
    return (sx >= 0 && sx < G && sy >= 0 && sy < G);
}

__global__ void kProjectXY(const float* grid3, float* out2, int G, int S, ViewRot rot) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= G || y >= G || z >= G) return;
    const float v = grid3[(z * S + y) * S + x];
    if (!rot.on) { atomicAdd(&out2[y * G + x], v); return; }
    if (v == 0.f) return;                       // 빈 칸은 돌릴 것도 없다
    int sx, sy;
    if (!rotCell(x, y, z, G, rot, sx, sy)) return;
    atomicAdd(&out2[sy * G + sx], v);
}

// 속도 분산 — 은하에서 「온도」에 해당하는 값.
//
// 별들이 나란히 돌면 차가운 것이고, 제각각 움직이면 뜨거운 것이다. 그 무질서한 속도가
// 원반이 조각나지 않게 버티는 힘이라, 실제로 온도와 같은 자리에 선다.
//
// 시선 방향(z)으로 합쳐 보므로 화면에는 「그 자리에서 별들이 얼마나 흩어져 움직이나」가 뜬다.
// 두 격자에 나눠 쌓고 나중에 나눈다 — 합만으로는 알갱이가 많은 곳이 무조건 뜨거워 보인다.
//
// 비용: N 스레드 × 4 atomicAdd(2D 라 8칸이 아니라 4칸이다). N=100만이면 400만 회.
__global__ void kScatterDispersion(const float4* pos, const float4* vel, int n, int G,
                                   float* num, float* den, ViewRot rot) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    const float4 v = vel[i];
    const float v2 = v.x * v.x + v.y * v.y + v.z * v.z;

    float ux = p.x, uy = p.y;
    if (rot.on && !rotPoint(p.x, p.y, p.z, rot, ux, uy)) return;
    const float gx = ux * G - 0.5f, gy = uy * G - 0.5f;
    const int ix = (int)floorf(gx), iy = (int)floorf(gy);
    const float fx = gx - ix, fy = gy - iy;
    for (int k = 0; k < 4; ++k) {
        const int ox = k & 1, oy = (k >> 1) & 1;
        const int cx = min(max(ix + ox, 0), G - 1);
        const int cy = min(max(iy + oy, 0), G - 1);
        const float w = (ox ? fx : 1.f - fx) * (oy ? fy : 1.f - fy);
        atomicAdd(&num[cy * G + cx], w * v2);
        atomicAdd(&den[cy * G + cx], w);
    }
}

// 합을 밀도로 나눠 평균으로 만든다. 빈 칸은 0 으로 둔다.
// 별이 내는 빛을 화면 격자에 뿌린다.
//
// **비용**: N 스레드 × CIC 4칸 × 격자 2개(밝기·온도) = 400만 × 8 = 3200만 atomicAdd.
// 온도 축을 나누며 두 배가 됐다. `kScatterDispersion`(1600만)의 두 배이고, 이 커널은
// 매 스텝이 아니라 **화면을 그릴 때만** 돈다 — 빛 모드가 아니면 아예 안 돈다.
//
// **밝기는 질량의 3.5제곱이다.** 이 지수 하나가 밀도 그림과 빛 그림을 완전히 갈라놓는다 —
// 태양 20배짜리 별은 3만 6천 배 밝다. 밀도로 보면 알갱이 20개일 뿐인데 빛으로 보면
// 주변 수만 개를 합친 것보다 밝다. **그것이 실제 밤하늘이다.**
//
// 가스(`pos.w == 0`)는 스스로 빛나지 않아 여기서 0 이다. 별빛을 받아 빛나는 반사광은
// 별빛을 퍼뜨리는 계산이 따로 필요해 이번 판에서는 넣지 않는다(스펙의 다음 항목).
// 폭발 중(`pos.w < 0`)인 것은 **아주 밝게** 친다 — 초신성은 은하 전체보다 밝다.
// 별의 표면 온도(켈빈). **밝기와 다른 축이다 — 이 함수가 있어야 넷을 눈으로 가른다.**
//
// `L = 4πR²σT⁴` 라 밝기는 **크기와 온도 둘 다**에 달려 있다. 그래서 작고 뜨거운 것은
// 어두우면서 푸르고, 크고 미지근한 것은 밝으면서 붉다. 밝기 하나로 색을 정하면
// 그 조합이 통째로 표현되지 않는다 — 백색왜성이 「어두우니 붉다」로 그려진다.
//
// 상태마다 온도의 출처가 다르다:
//   주계열   T = T_sun·(M/M_sun)^0.5   — L∝M^3.5, R∝M^0.8 에서 나온다
//   백색왜성 15,000K 고정               — 관측 범위 8,000~40,000K 의 중간. 질량과 무관하게
//                                        핵융합이 끝난 심의 잔열이라 M 으로 못 구한다
//   중성자별 1,000,000K                 — 갓 태어난 것은 실제로 백만 K 대다
//   폭발 중   30,000K                    — 초신성 광구
//
// **잔해 두 종류는 `vel.w` 의 음수 값으로 갈린다**(-1 백색왜성, -2 중성자별).
__device__ __forceinline__ float starTempK(float pw, float vw, float sunMass) {
    if (pw < 0.f) return 30000.f;                     // 폭발 중
    if (vw < -1.5f) return 1000000.f;                 // 중성자별
    if (vw < 0.f)   return 15000.f;                   // 백색왜성
    return 5800.f * __fsqrt_rn(fmaxf(pw / sunMass, 1e-3f));
}

__global__ void kScatterLight(const float4* pos, const float4* vel, int n, int G,
                              float* out, float* outT, ViewRot rot,
                              float sunMass, float novaBoost, float explodeSim,
                              float embedSim) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;

    float lum;
    if (p.w > 0.f) {
        // 별. L = (M/M_sun)^3.5
        lum = __powf(fmaxf(p.w / sunMass, 1e-3f), 3.5f);
    } else if (p.w < 0.f) {
        // ── 초신성 광도 곡선 ────────────────────────────────────────────────
        //
        // **여태 상수 하나였다.** 그래서 터지는 순간부터 꺼질 때까지 밝기가 똑같았고,
        // 사용자가 「순간적으로 훨씬 밝아져야되는데 그런게 없어」라고 알린 것이 이것이다.
        // 터졌다는 것을 알 수 있는 신호가 화면에 없었다.
        //
        // 실제 II형 초신성의 광도 곡선은 **며칠 만에 최대까지 치솟고, 그 뒤 몇 달에 걸쳐
        // 지수적으로 잦아든다.** 오르는 것이 내리는 것보다 훨씬 빠른 비대칭이 특징이고,
        // 내려가는 쪽이 지수인 것은 그 빛의 출처가 방사성 붕괴(⁵⁶Ni → ⁵⁶Co → ⁵⁶Fe)이기
        // 때문이다. ⁵⁶Co 의 반감기가 77일이라 그 시간 눈금으로 어두워진다.
        //
        // `p.w` 는 남은 폭발 시간(음수)이라 진행도를 그대로 낼 수 있다.
        const float prog = __saturatef(1.f - (-p.w) / fmaxf(explodeSim, 1e-6f));  // 0=터짐 1=끝
        // 상승 — 앞 8% 구간에서 최대까지. 실제 비율(며칠 : 몇 달)에 맞춘 값이다.
        const float kRise = 0.08f;
        // 감쇠 — ⁵⁶Co 지수. 폭발 길이 동안 e^-4 (약 1.8%)까지 내려간다.
        const float rise  = fminf(prog / kRise, 1.f);
        const float decay = __expf(-4.f * fmaxf(prog - kRise, 0.f) / (1.f - kRise));
        lum = novaBoost * rise * decay;
    } else {
        return;                                  // 가스는 스스로 안 빛난다
    }

    // 잔해는 밝기를 실제 크기에서 다시 잡는다. `kStarAge` 가 백색왜성을 `p.w *= 0.1` 로
    // 남기는데 그 값을 그대로 `M^3.5` 에 넣으면 **주계열 별의 식**을 잔해에 쓰는 것이 된다.
    // 실제 백색왜성은 반지름이 태양의 100분의 1 이라 같은 온도라도 만분의 1 로 어둡고,
    // 중성자별은 10km 라 사실상 안 보인다 — 그것이 「어두운데 푸르다」의 밝기 쪽 절반이다.
    float tempK;
    if (vel) {
        const float vw = vel[i].w;
        tempK = starTempK(p.w, vw, sunMass);
        if (p.w > 0.f && vw < 0.f) {
            lum *= (vw < -1.5f) ? 1e-6f : 1e-3f;   // 중성자별 · 백색왜성
        } else if (p.w > 0.f) {
            // **배태 단계 — 갓 태어난 별은 아직 고치 안에 있다**(근거는 `StarLook.h`).
            //
            // `vw` 는 별이 된 뒤 흐른 시간이다. 이것이 없을 때는 별이 되는 순간 밝기가
            // 0 에서 `ratio^3.5` 로 한 프레임에 뛰었고, 무리로 태어나는 자리가 통째로
            // 번쩍였다. 먼지가 걷히는 동안 어둡고 붉게, 걷히면 제 밝기·제 색으로 온다.
            //
            // 점 렌더(`RenderField.cu` 의 `kSplatPoints`)에 **같은 두 줄이 있다** —
            // 한쪽만 고치면 화면과 격자가 다른 색을 낸다.
            const float veil = starVeil(vw, p.w / sunMass, embedSim);
            lum  *= veil;
            tempK = dustRedden(tempK, veil);
        }
    } else {
        tempK = starTempK(p.w, 0.f, sunMass);
    }

    float ux = p.x, uy = p.y;
    if (rot.on && !rotPoint(p.x, p.y, p.z, rot, ux, uy)) return;
    const float gx = ux * G - 0.5f, gy = uy * G - 0.5f;
    const int ix = (int)floorf(gx), iy = (int)floorf(gy);
    const float fx = gx - ix, fy = gy - iy;
    for (int k = 0; k < 4; ++k) {
        const int ox = k & 1, oy = (k >> 1) & 1;
        const int cx = min(max(ix + ox, 0), G - 1);
        const int cy = min(max(iy + oy, 0), G - 1);
        const float w = (ox ? fx : 1.f - fx) * (oy ? fy : 1.f - fy);
        atomicAdd(&out[cy * G + cx], w * lum);
        // **밝기로 가중한 온도를 쌓는다.** 한 칸에 여러 별이 겹치면 밝은 쪽 색이 이겨야
        // 한다 — 어두운 적색왜성 백 개와 청색거성 하나가 겹친 자리는 푸르게 보이는 것이
        // 맞다. 나중에 이 합을 밝기 합으로 나누면 그 가중평균이 나온다.
        if (outT) atomicAdd(&outT[cy * G + cx], w * lum * tempK);
    }
}

// (`kBlurLine`(별빛 흐리기)·`kAddNebula`(성운)를 지웠다 — 2026-08-18)
//
// 별빛 격자를 흐려 「퍼진 별빛」을 만들고, 그것을 가스에 곱해 성운으로 빛나게 하던 것이다.
// 사용자 요청 — 「이런식으로 주위가 밝게 나오는거 제거해줘」 — 로 걷어냈다.
//
// 08-17 에 같은 이유로 별 후광(`kAddGlow`)을 껐는데, 그때 흐린 격자는 성운이 쓰므로
// 남겼었다. 이제 성운도 없으니 흐리기 자체가 쓸 데가 없다. **빛은 그 빛을 내는 것이
// 있는 자리에서만 난다** — 별은 `kScatterLight` 가 자기 칸에 뿌리는 것으로 끝난다.
//
// 실측(2026-08-18 A/B): `nebulaK` 0.02 → 0 으로 밝은 덩어리마다 둘러 있던 주황 후광이
// 통째로 사라졌고, 배경의 별 알갱이는 그대로였다. 즉 후광은 별이 아니라 성운이었다.

__global__ void kDivideInto(const float* num, const float* den, float* out, int n) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float d = den[i];
    // 속도 제곱의 평균이라 제곱근을 씌워 「속도」 단위로 돌려놓는다 — 그래야 색의 폭이 고르다.
    out[i] = (d > 1e-6f) ? sqrtf(fmaxf(num[i] / d, 0.f)) : 0.f;
}

// ---------------------------------------------------------------------------
// 측정
// ---------------------------------------------------------------------------
// 격자 하나를 통째로 더한다.
//
// 블록 안에서 먼저 모으고 블록마다 한 번만 전역에 더한다 — 칸마다 전역 원자 연산을 하면
// 209만 칸이 같은 주소에 줄을 서서 이 측정 하나가 프레임을 먹는다(kCountAlive 와 같은 수법).
// 합이 double 인 이유는 209만 칸을 float 으로 더하면 뒤쪽 값이 반올림에 먹히기 때문이다.
__global__ void kSumFloatGrid(const float* g, int n, double* out) {
    __shared__ double s;
    if (threadIdx.x == 0) s = 0.0;
    __syncthreads();
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) atomicAdd(&s, (double)g[i]);
    __syncthreads();
    if (threadIdx.x == 0) atomicAdd(out, s);
}

__global__ void kCountOccupied(const float* g, int n, int* out, float eps) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n && g[i] > eps) atomicAdd(out, 1);
}

// 질량중심. 화면이 xy 만 보므로 x, y 만 모은다.
__global__ void kCentroidAccum(const float4* pos, int n, double* sx, double* sy, int* cnt) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    atomicAdd(sx, (double)p.x);
    atomicAdd(sy, (double)p.y);
    atomicAdd(cnt, 1);
}

// 가장 빽빽한 칸을 찾는다. 밀도를 위쪽 32비트에 실어 64비트 최댓값 하나로 겨룬다 —
// 밀도와 칸 번호를 한 번에 비교할 수 있어 두 번 훑지 않아도 된다.
__global__ void kFindDensestCell(const float* g, int G, int S, unsigned long long* out) {
    const int x = blockIdx.x * blockDim.x + threadIdx.x;
    const int y = blockIdx.y * blockDim.y + threadIdx.y;
    const int z = blockIdx.z * blockDim.z + threadIdx.z;
    if (x >= G || y >= G || z >= G) return;
    const float d = g[(z * S + y) * S + x];
    if (d <= 0.f) return;
    const unsigned long long key = ((unsigned long long)(unsigned)(d * 256.0f) << 32)
                                 | (unsigned long long)(unsigned)((z * G + y) * G + x);
    atomicMax(out, key);
}

// 회전곡선 — 반지름 고리마다 회전 속도를 모은다.
//
// 회전 속도는 속도 벡터에서 **접선 성분**만 뽑은 것이다. 중심을 향하거나 멀어지는 성분과
// 위아래 성분은 회전과 무관하다. 부호를 없애 크기만 더하는 이유는, 반대로 도는 알갱이가
// 섞여 있어도 「얼마나 빨리 도는가」를 보고 싶기 때문이다.
//
// 비용: N 스레드 × 2 atomicAdd.
__global__ void kRotationAccum(const float4* pos, const float4* vel, int n,
                               float* sumV, float* cnt, int bins, float maxR) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    const float dx = p.x - 0.5f, dy = p.y - 0.5f;
    const float r = sqrtf(dx * dx + dy * dy);
    if (r < 1e-5f || r > maxR) return;
    const int b = min((int)(r / maxR * bins), bins - 1);
    const float4 v = vel[i];
    // 접선 방향 단위벡터는 (-dy, dx)/r 다.
    const float vt = (-dy * v.x + dx * v.y) / r;
    atomicAdd(&sumV[b], fabsf(vt));
    atomicAdd(&cnt[b], 1.0f);
}

__global__ void kKineticAccum(const float4* pos, const float4* vel, int n, double* out) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    if (pos[i].x < 0.f) return;
    const float4 v = vel[i];
    atomicAdd(out, (double)(v.x * v.x + v.y * v.y + v.z * v.z) * 0.5);
}

// 살아 있는 알갱이를 앞으로 모은다(지우개가 만든 구멍 메우기).
__global__ void kMarkAlive(const float4* pos, int n, int* flag) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) flag[i] = (pos[i].x >= 0.f) ? 1 : 0;
}
__global__ void kCompact(const float4* sp, const float4* sv, const float* st,
                         const int* flag, const int* scan, int n,
                         float4* dp, float4* dv, float* dt) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n || !flag[i]) return;
    const int j = scan[i];
    dp[j] = sp[i]; dv[j] = sv[i];
    if (st && dt) dt[j] = st[i];
}
__global__ void kHideRange(float4* pos, float4* vel, int from, int to) {
    const int i = from + blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= to) return;
    pos[i] = make_float4(-1.f, -1.f, -1.f, 0.f);
    vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
}

// ---------------------------------------------------------------------------
// 마우스 도구
// ---------------------------------------------------------------------------

// 형태 하나를 빈 슬롯 구간에 채운다. 화면이 xy 를 보므로 두께는 얇게 준다.
//
// 전하 배열(`temp`)은 건드리지 않는다. reset() 의 `kInitCharge` 가 빈 슬롯까지 전체를
// ±1 로 깔아 두므로 여기 들어오는 알갱이도 그 부호를 그대로 물려받는다. 온도 배열이던
// 시절의 0.02/0.6 쓰기는 지웠다 — 그것이 남아 있어 전자기력을 켠 채 형태를 놓으면 그
// 알갱이만 전부 같은 부호가 되고 있었다.
__global__ void kFillShape(float4* pos, float4* vel, int from, int count,
                           float cx, float cy, int kind, float R, float thickness,
                           unsigned seed) {
    const int t = blockIdx.x * blockDim.x + threadIdx.x;
    if (t >= count) return;
    const int i = from + t;
    const unsigned s = (unsigned)i * 2654435761u + seed;
    const float u1 = rnd01(s), u2 = rnd01(s * 3u + 1u), u3 = rnd01(s * 7u + 5u);

    float x, y, z = 0.5f + rndNormal(s ^ 0x2545F491u) * thickness;

    if (kind == 0) {                       // 은하 — 도는 원반
        const float3 p = diskPoint(R, thickness, s ^ 0x9E3779B9u);
        x = cx + p.x; y = cy + p.y; z = 0.5f + p.z;
    } else if (kind == 1) {                // 태양 — 가운데로 갈수록 빽빽하다
        const float3 b = bulgePoint(R, s);
        x = cx + b.x; y = cy + b.y; z = 0.5f + b.z;
    } else if (kind == 2) {                // 고리 — 가운데가 빈 도넛
        const float th = u1 * 6.2831853f;
        const float r = R * (0.72f + 0.22f * u2);
        x = cx + r * __cosf(th); y = cy + r * __sinf(th);
    } else if (kind == 3) {                // 구름 — 넓게 퍼진 성운
        // **공 안에 고르게** 뿌린다. bulgePoint 는 r = R·u² 라 중심에 몰리는 분포라,
        // 그걸 키워 쓰면 태양과 비슷하게 뭉쳐 「성기게 퍼진 성운」이 되지 않는다
        // (2026-08-14 실측: 구름 최대 밀도가 태양의 2/3 까지 올라갔다).
        // 부피가 r³ 에 비례하므로 세제곱근을 씌워야 고르게 찬다.
        const float rr = R * 1.5f * cbrtf(fmaxf(u1, 1e-6f));
        const float cz2 = u2 * 2.0f - 1.0f;
        const float sz2 = sqrtf(fmaxf(1.0f - cz2 * cz2, 0.0f));
        const float ph2 = rnd01(s * 17u + 9u) * 6.2831853f;
        x = cx + rr * sz2 * __cosf(ph2);
        y = cy + rr * sz2 * __sinf(ph2);
        z = 0.5f + rr * cz2;
    } else if (kind == 5) {                // 토성 — 가운데 공에 아주 얇은 고리
        if (u3 < 0.42f) {                  // 본체
            const float3 b = bulgePoint(R * 0.34f, s);
            x = cx + b.x; y = cy + b.y; z = 0.5f + b.z;
        } else {                           // 고리 — 두께가 지름의 백분의 몇밖에 안 된다
            const float th = u1 * 6.2831853f;
            const float rr = R * (0.60f + 0.36f * u2);
            x = cx + rr * __cosf(th); y = cy + rr * __sinf(th);
            z = 0.5f + rndNormal(s ^ 0x68E31DA4u) * thickness * 0.12f;
        }
    } else {                               // 여기로 오지 않는다(블랙홀은 알갱이를 놓지 않는다)
        const float th = u1 * 6.2831853f;
        const float r = R * sqrtf(u2);
        x = cx + r * __cosf(th); y = cy + r * __sinf(th);
    }

    pos[i] = make_float4(x, y, z, 0.f);
    vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
}

// 방금 넣은 구간에만 궤도 속도를 준다.
__global__ void kSetOrbitAt(float4* vel, const float4* pos, const float* accMag,
                            int from, int count, float cx, float cy) {
    const int t = blockIdx.x * blockDim.x + threadIdx.x;
    if (t >= count) return;
    const int i = from + t;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    const float dx = p.x - cx, dy = p.y - cy;
    const float r = sqrtf(dx * dx + dy * dy);
    if (r < 1e-5f) return;
    const float v = sqrtf(fmaxf(accMag[i], 0.f) * r);
    vel[i] = make_float4(-dy / r * v, dx / r * v, 0.f, 0.f);
}

// 브러시 — 밀어내기(strength>0) 또는 끌어당기기(strength<0).
__global__ void kBrushPush(float4* pos, float4* vel, int n, float cx, float cy,
                           float radius, float strength) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    // 화면에서 고른 자리라 깊이(z)는 판 가운데를 기준으로 본다.
    const float dx = p.x - cx, dy = p.y - cy, dz = p.z - 0.5f;
    const float d2 = dx * dx + dy * dy + dz * dz;
    if (d2 > radius * radius) return;
    const float d = sqrtf(fmaxf(d2, 1e-12f));
    const float w = 1.0f - d / radius;
    float4 v = vel[i];
    v.x += strength * w * dx / d;
    v.y += strength * w * dy / d;
    v.z += strength * w * dz / d;
    vel[i] = v;
}

// 지우개 — 브러시 안의 알갱이를 지우고 개수를 센다.
__global__ void kEraseIn(float4* pos, float4* vel, int n, float cx, float cy,
                         float radius, int* count) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;
    const float dx = p.x - cx, dy = p.y - cy;
    if (dx * dx + dy * dy > radius * radius) return;   // 화면에서 고르므로 깊이는 보지 않는다
    pos[i] = make_float4(-1.f, -1.f, -1.f, 0.f);
    vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
    atomicAdd(count, 1);
}

// 가장 빠른 알갱이의 속력(CFL 조건에 쓴다).
__global__ void kMaxSpeed(const float4* vel, const float4* pos, int n, float* out) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    if (pos[i].x < 0.f) return;
    const float4 v = vel[i];
    const float s = sqrtf(v.x * v.x + v.y * v.y + v.z * v.z);
    atomicMax((int*)out, __float_as_int(s));   // 속력은 음수가 아니라 정수 비교가 그대로 통한다
}

} // namespace

// ---------------------------------------------------------------------------
// Impl
// ---------------------------------------------------------------------------
struct Sim::Impl {
    SimConfig cfg;
    SimTimings tm;
    double simTime = 0.0;

    float4 *pos = nullptr, *vel = nullptr;
    float4 *posTmp = nullptr, *velTmp = nullptr;
    float  *temp = nullptr, *tempTmp = nullptr;
    float4 *accG = nullptr;          // 격자 가속도 G³
    float4 *accPress = nullptr;      // 압력 가속도 G³ — 가스만 받는다(별은 안 부딪힌다)
    float4 *accContact = nullptr;    // 접촉 가속도 N
    float  *rho = nullptr;           // 밀도(패딩 포함) S³
    float  *pot = nullptr;           // 퍼텐셜(패딩 포함) S³
    float  *proj = nullptr;          // 화면에 넘길 2D 투영 G²
    float  *projA = nullptr, *projB = nullptr;   // 속도 분산을 구할 때 쓰는 두 격자 G²
    // (`projLight`(성운 전 별빛)·`projTB`(퍼뜨린 온도)를 지웠다 — 2026-08-18. 성운을
    //  걷어내며 함께 없앴다. 이제 `proj` 가 곧 순수 별빛이라 정규화 기준을 따로 둘
    //  이유가 없고, 퍼뜨릴 것이 없으니 온도 임시 격자도 필요 없다.)
    //
    // **밝기로 가중한 온도의 합** G². 색을 밝기와 다른 축에서 정하는 자리다 —
    // 이것을 밝기 합으로 나누면 그 픽셀의 대표 온도가 나온다.
    float  *projT = nullptr;
    // 「폭발 자리에서 새 별이 태어나는가」를 보는 창. [0] 태어난 수, [1] 그 자리 재의 합.
    // **누적이라 비우지 않는다** — 판이 열린 뒤 지금까지의 평균을 본다.
    double *bornStat = nullptr;
    float  *accMag = nullptr;        // 궤도 속도용 N

    // ── 압력 (속도 분산 텐서의 대각 성분) ──────────────────────────────────
    //
    // 방향별로 따로 든다. 하나로 뭉개면 원반의 수직 방향까지 좌우만큼 밀어내 판이
    // 공처럼 부푼다(kPressure 주석 참조).
    //
    // **패딩을 안 쓴다 — G³ 다.** 중력은 먼 곳까지 닿아 고립 경계에서 S³(8배)로 푸는데,
    // 압력은 옆 칸만 보는 국소 미분이라 그럴 이유가 없다. 128³ × 4B × 4개 = 33 MB 이고,
    // 패딩을 그대로 따라 했다면 268 MB 였다.
    //
    // dispCnt 는 그 칸에 쌓인 알갱이 수(ρ). dispX 등은 분산의 **합**이라 그 자체가
    // 이미 ρσ² 이고, 그래서 kPressure 가 나누지 않고 바로 미분한다.
    float  *dispX = nullptr, *dispY = nullptr, *dispZ = nullptr, *dispCnt = nullptr;

    // 칸별 속도 합. 나누면 그 칸의 평균 흐름이 된다.
    //
    // **왜 격자로 두나 — 운동량을 지키려고.** 전에는 알갱이마다 자기 이웃 27칸을 훑어
    // 평균을 냈는데, 이웃 목록이 알갱이마다 달라서 주고받는 힘이 짝이 안 맞았다. 그
    // 어긋남이 알갱이를 바깥으로 밀어 2026-08-16 실측에서 **판의 89% 가 벽에 붙었다**
    // (냉각을 끄면 1%). 같은 칸의 알갱이가 **모두 같은 평균**을 보면 `Σ(v̄ − vᵢ) = 0` 이라
    // 총 운동량이 정확히 보존된다.
    //
    // 덤으로 싸진다 — 이웃 96개 읽기가 사라지고 알갱이당 원자 연산 셋만 남는다.
    float  *velSumX = nullptr, *velSumY = nullptr, *velSumZ = nullptr;

    // ── 재(무거운 원소) ────────────────────────────────────────────────────
    //
    // **알갱이가 아니라 격자에 든다.** 폭발은 자기 자신이 아니라 **그 자리 주변**을
    // 오염시키고, 다음에 그 자리를 지나는 알갱이가 그 영향을 받아야 하기 때문이다.
    // 알갱이에 붙이면 터진 알갱이만 재를 갖고 다니게 되어 사슬이 끊긴다.
    //
    // 재가 쌓이면 그 칸이 잘 식고(kCool), 식으면 σ² 가 내려가고, Jeans 문턱이
    // `ρ > k_J·σ²` 라 **저절로 낮아져 작은 별이 태어난다.** 「재가 많으면 작은 별」이라는
    // 규칙을 코드에 적지 않아도 그 사슬이 도는 것이 이 배열의 값어치다.
    //
    // 128³ × 4B = 8 MB.
    float  *ashGrid = nullptr;

    // ── 블랙홀 후보 (커널 → 호스트 다리) ──────────────────────────────────
    //
    // **커널은 `addBlackHole` 을 부를 수 없다** — 그것은 호스트 함수이고 `bhs[]` 배열과
    // `bhCount` 를 만진다. 그래서 커널은 「여기 블랙홀이 될 별이 있다」고 자리와 질량만
    // 남기고, 호스트가 스텝 끝에서 읽어 실제로 만든다.
    //
    // 한 스텝에 여러 개가 동시에 수명을 다할 수 있어 배열로 받되, 자리가 여덟뿐이라
    // 그 이상은 받지 않는다. 넘친 것은 `bhBlockedCount` 로 세어 **중성자별로 남긴다** —
    // 기존 `addBlackHole` 처럼 가장 가벼운 것을 밀어내면 그 블랙홀이 삼킨 질량이
    // 소리 없이 사라져 보존이 깨진다(설계 2.4).
    float4 *bhCand = nullptr;        // [kMaxBlackHoles] 자리(xyz) + 질량(w)
    float4 *bhCandV = nullptr;       // [kMaxBlackHoles] 물려줄 속도(xyz) — 운동량 보존
    int    *bhCandN = nullptr;       // 이번 스텝의 후보 수
    int    *bhBlockedCount = nullptr;// 자리가 없어 중성자별로 남은 누적 횟수
    int     bhBlockedHost = 0;       // 호스트 쪽 사본(사고 기록·상태 표시용)

    cufftComplex *specRho = nullptr, *specGreen = nullptr;
    cufftHandle planR2C = 0, planC2R = 0;
    bool planReady = false;

    int *keys = nullptr, *order = nullptr, *cellStart = nullptr, *cellEnd = nullptr;
    int *flag = nullptr, *scan = nullptr;
    void *sortTmp = nullptr; size_t sortTmpBytes = 0;
    void *redTmp = nullptr;  size_t redTmpBytes = 0;
    double *redD = nullptr;
    int    *redI = nullptr;
    unsigned long long *redU = nullptr;
    float  *redF = nullptr;

    int allocN = 0, allocG = 0;
    Boundary allocBoundary = Boundary::Isolated;
    int requestedN = -1, requestedG = -1;
    Boundary requestedBoundary = Boundary::Isolated;

    int active = 0;
    // 보여 줄 「살아 있는 수」. active 는 자리 관리용이라 삼킨 만큼 줄일 수 없어서
    // 따로 센다(kCountAlive). -1 이면 아직 세지 않았다는 뜻이고 그때는 active 를 쓴다.
    int aliveShown = -1;
    int stepCount = 0;
    // 형태를 놓을 자리를 가리키는 커서. 빈 자리가 다 차면 앞으로 돌아와 먼저 넣은 것을
    // 덮어쓴다 — 그래야 계속 놓아도 총수가 상한을 넘지 않으면서 새로 놓은 것이 항상 보인다.
    int ringCursor = 0;

    // ── 블랙홀 (여럿) ─────────────────────────────────────────────────────
    //
    // 오래 하나였다. 하나뿐이면 새로 놓을 때마다 앞의 것이 사라져, 둘이 서로를 끌어당기는
    // 것도 합쳐지는 것도 볼 수 없었다 — 이 장면에서 가장 볼 만한 일이 그것인데도.
    BlackHoleState bhs[kMaxBlackHoles];
    // (자라는 기준값 `bhMassAtBirth`·`bhRsAtBirth` 를 지웠다 — 2026-08-18. 지평선이
    //  이제 질량 하나에서 `2GM/c²` 로 나오므로 기준점이 필요 없다.)
    int   bhCount = 0;
    // 이번 스텝에 삼킨 수 — 블랙홀마다 하나씩.
    int *eaten = nullptr;
    // 이번 스텝에 삼킨 물질의 속도 합(블랙홀당 x·y·z 셋). 개수가 곧 질량이라
    // 이 합을 개수로 나누면 삼킨 물질의 평균 속도가 나온다 — 동역학적 마찰의 재료다.
    float *eatenP = nullptr;
    // 각 블랙홀이 놓인 자리의 격자 가속도(둘레 물질이 블랙홀을 끄는 힘).
    // 커널이 채우고 host 가 읽어 블랙홀을 움직인다.
    float4 *bhAcc = nullptr;

    // 보는 방향. 단위행렬이면 위에서 곧장 내려다보던 예전 그대로다.
    // 각도 둘이 아니라 행렬인 까닭은 `ViewRot.h` 맨 위 주석(짐벌락)에 있다.
    float viewM[9] = { 1.f,0.f,0.f, 0.f,1.f,0.f, 0.f,0.f,1.f };
    // **격자 렌더는 화면 이동(pan)을 자기가 따로 처리한다**(`kShade` 의 `- panX`).
    // 그래서 여기서는 넣지 않는다 — 넣으면 두 번 적용되어 그림이 어긋난다.
    // 식은 `ViewRot.h` 의 `makeViewRot` 하나로 둔다 — 점 렌더도 같은 것을 쓴다.
    ViewRot viewRot() const { return makeViewRot(viewM); }

    // 가장 무거운 것. 오래 「판에 하나」였던 자리들이 이것을 본다.
    BlackHoleState heaviest() const {
        BlackHoleState best;
        for (int i = 0; i < bhCount; ++i)
            if (bhs[i].active && bhs[i].mass > best.mass) best = bhs[i];
        return best;
    }

    cudaEvent_t evA = nullptr, evB = nullptr;
    // 구간별 시간을 재는 이벤트. **동기화는 스텝 끝에서 한 번만 한다** —
    // 구간마다 `cudaEventSynchronize` 를 부르면 그 자체가 GPU 를 세워, 재는 행위가
    // 재려는 대상을 바꾼다. 찍기만 하고 마지막에 몰아서 읽는다.
    //   ev1 중력(정렬 + scatter + 푸아송 + 격자가속도 + 압력) 끝
    //   ev2 냉각·압력 격자 갱신 + 별 판정 끝
    //   ev3 적분 + 블랙홀 끝
    cudaEvent_t ev1 = nullptr, ev2 = nullptr, ev3 = nullptr;

    // 패딩 포함 한 변. 고립 경계는 합성곱이 반대편으로 감기지 않게 두 배로 잡는다.
    int  stride() const { return (cfg.boundary == Boundary::Isolated) ? allocG * 2 : allocG; }
    size_t padCells() const { const size_t s = (size_t)stride(); return s * s * s; }
    bool periodic() const { return cfg.boundary == Boundary::Periodic; }

    // 격자 퍼텐셜을 가속도로 바꿀 때 곱하는 배율.
    // 알갱이 하나의 질량을 1/N 로 둔다 — 그래야 총질량이 1 로 고정되어 개수를 바꿔도
    // 중력의 세기가 그대로다.
    float potScale() const {
        return cfg.gravity / (float)(allocN > 0 ? allocN : 1);
    }
    float horizonOf(float eatenCount) const {
        const float M = eatenCount / (float)(allocN > 0 ? allocN : 1);
        // 길이 눈금을 늘리면 광속이 그만큼 느려지고, 지평선은 c² 에 반비례하므로
        // 눈금 제곱만큼 커진다 — 판을 크게 볼수록 같은 질량의 지평선이 화면에서
        // 작아 보이는 것과 앞뒤가 맞는다(`lightSpeedFor` 참조).
        return 2.0f * cfg.gravity * M / lightSpeedSqFor(cfg.lengthScale, cfg.timeUnitScale);
    }

    // 커널에 넘길 블랙홀 묶음을 만든다. 삼킴 반경의 바닥(격자 한 칸)도 여기서 건다.
    BHPack packBH() const;
    // i 번째 지평선을 그 질량에서 다시 낸다.
    void   setRsFrom(int i);
    // 블랙홀을 하나 더한다. 자리가 없으면 가장 가벼운 것을 밀어낸다. 그 번호를 돌려준다.
    // 속도는 기본이 0 이다 — 사용자가 마우스로 놓는 것과 판을 열 때 중심에 두는 것은
    // 멈춘 채로 시작하는 것이 맞다. **별이 무너져 생기는 것만** 원래 속도를 물려준다.
    int    addBlackHole(float x, float y, float z, float mass, bool born,
                        float vx = 0.f, float vy = 0.f, float vz = 0.f);
    // 블랙홀을 한 스텝 움직이고, 겹친 것끼리 합친다.
    void   advanceBlackHoles(float dt);

    void freeAll();
    void allocate();
    void buildGreen();
    void solvePoisson();
    void scatterMass();
    void computeAccel();
    void placeInitial();
    void giveOrbits();
    void sortParticles();
    // 살아 있는 알갱이를 세어 aliveShown 에 담는다. 삼킨 뒤에만 부른다.
    void countAlive();
    void doContact();
    // 이웃과의 무작위 운동을 걷어낸다(냉각). dt 를 받아야 배속과 무관하게 식는다.
    void doCooling(float dt);
    void checkCollapse();
};

namespace {
// 3D 커널을 띄울 때 쓰는 블록 모양. 8×8×8 = 512 스레드.
inline dim3 blk3() { return dim3(8, 8, 8); }
inline dim3 grd3(int G) { return dim3((G + 7) / 8, (G + 7) / 8, (G + 7) / 8); }
} // namespace

// bhs[0, bhCount) 는 **모두 살아 있다**는 것이 이 배열의 불변식이다.
// 가운데를 비워 두면 커널에 넘기는 묶음의 번호와 「삼킨 수」 배열의 번호가 어긋나,
// 한 블랙홀이 삼킨 것이 다른 블랙홀의 질량으로 들어간다. 지울 때는 뒤를 당긴다.
BHPack Sim::Impl::packBH() const {
    BHPack pk;
    // **삼키는 반경 = 실제 사건의 지평선.** 부풀리지 않는다(2026-08-18).
    //
    // 여태 `max(rs*0.5, 격자 한 칸)` 이었고, 그 `rs` 조차 화면용으로 부풀린 값이라
    // 삼킴 반경이 진짜 지평선의 **97~650배**였다. 그것이 사슬의 뿌리였다:
    //
    //   반경 과대 → 궤도가 성립할 공간(ISCO 바깥)이 통째로 삼킴 구 안 → 다 삼켜 판이 빔
    //   → 못 삼키게 **에딩턴 대기열**을 붙임 → 막힌 알갱이가 지평선 안에 남아 튐
    //   → 가라앉히려고 **v *= 0.90** → 그래도 튀니 **중력을 끔(continue)**
    //   → 그래서 「경계에 입자가 붙어 멈춰 있고, 지평선 안이 화면에 보인다」
    //
    // 반경을 97분의 1 로 되돌리면 삼키는 부피가 90만분의 1 이라 과도한 삼킴 자체가
    // 없어진다 — 위 셋(대기열·감쇠·중력 끄기)이 함께 필요 없어진다.
    //
    // **격자 한 칸 바닥을 뺐다.** 그 바닥은 「지평선 바로 밖 한 칸이 삼켜지지 않아
    // 알갱이가 끝없이 쌓이는」 것을 막으려던 것인데, 쌓이던 진짜 이유는 그 알갱이들이
    // 중력을 못 받아(`continue`) 궤도를 못 돌았기 때문이다. 이제 지평선 밖에서는 언제나
    // 측지선 중력을 받으므로 각운동량이 있는 것은 돌고, 없는 것은 지나쳐 간다.
    // **다만 이것이 2026-08-14 에 시스템을 여섯 번 죽인 자리이므로 한 칸 점유 수
    // (`peakCellCount`)를 반드시 함께 본다.**
    const float inv  = 1.0f / (float)(allocN > 0 ? allocN : 1);
    for (int i = 0; i < bhCount && i < kMaxBlackHoles; ++i) {
        // 지평선은 질량에서 나온다 — `horizonOf` 가 곧 `2GM/c²` 다.
        const float rs = horizonOf(bhs[i].mass);
        pk.p[i] = make_float4(bhs[i].x, bhs[i].y, bhs[i].z, rs);
        // 셋째 칸은 예전에 에딩턴 몫이었다. **지평선 안은 예외 없이 삼키므로 안 쓴다.**
        //
        // 에딩턴 한계는 복사압이 물질을 **바깥으로** 밀어 유입을 늦추는 것이라, 바깥을
        // 향한 세계선이 없는 지평선 안에서는 성립할 수 없다. 실제로 제한이 걸리는 곳은
        // 원반이고, 그 자리에서는 이미 마찰(점성)이 각운동량을 뽑는 속도가 유입을 정한다.
        // 넷째 칸은 **중력 소프트닝 길이의 제곱**이다. 격자 중력과 같은 눈금을 쓴다 —
        // `softeningCells` 칸만큼. 격자보다 작은 구조는 어차피 표현하지 못하므로 그 아래에서
        // 힘이 발산하지 않게 무른다(자세한 근거는 `kIntegrate` 의 소프트닝 주석).
        const float cell = 1.0f / (float)(allocG > 0 ? allocG : 1);
        const float eps  = fmaxf(cfg.softeningCells, 0.5f) * cell;
        pk.q[i] = make_float4(cfg.gravity * bhs[i].mass * inv, rs, 0.f, eps * eps);
    }
    pk.n = (bhCount < kMaxBlackHoles) ? bhCount : kMaxBlackHoles;
    return pk;
}

void Sim::Impl::setRsFrom(int i) {
    if (i < 0 || i >= kMaxBlackHoles) return;
    // **지평선은 질량에 정비례한다 — `rs = 2GM/c²`.** 그것이 슈바르츠실트 해의 정의다.
    //
    // 여태 「처음 크기를 보이게 부풀린 값 × 질량의 세제곱근」이었다(부풀림까지 선형으로
    // 자라는 되먹임을 막으려고 세제곱근을 썼다). M^(1/3) 은 어떤 시공간 해에도 없고,
    // 「화면의 4분의 1」 상한은 아예 물리량이 아니었다.
    //
    // 화면에서 안 보이는 것은 **그릴 때 최소 크기를 줘서** 푼다 — `Sim.h` 의
    // `Sim.h` 의 `kLightSpeed` 주석이 그 근거다.
    bhs[i].rs = horizonOf(bhs[i].mass);
}

int Sim::Impl::addBlackHole(float x, float y, float z, float mass, bool born,
                            float vx, float vy, float vz) {
    // 상한은 두지 않는다. 크게 놓으면 크게 되는 것이 맞고, 무게는 부르는 쪽에서 정한다
    // (마우스로 놓는 것은 addShape 이 개수의 50분의 1 로 낮춰 넘긴다).
    if (mass < 1.0f) mass = 1.0f;

    int i;
    if (bhCount < kMaxBlackHoles) {
        i = bhCount++;
    } else {
        // 자리가 없으면 가장 가벼운 것을 밀어낸다. 눌렀는데 아무 일도 안 일어나는 것보다
        // 낫다 — 새로 놓은 것은 언제나 보여야 한다.
        i = 0;
        for (int j = 1; j < bhCount; ++j) if (bhs[j].mass < bhs[i].mass) i = j;
    }

    bhs[i] = BlackHoleState{};
    bhs[i].active = true;
    bhs[i].born = born;
    bhs[i].x = x; bhs[i].y = y; bhs[i].z = z;
    // **속도를 물려받는다 — 이 줄이 없어 블랙홀이 은하 밖으로 튀어나갔다.**
    //
    // 구조체를 통째로 0 으로 밀고 시작하므로, 여기서 다시 넣지 않으면 속도가 사라진다.
    // 은하 회전 속도로 돌던 별이 블랙홀이 되는 순간 멎어 각운동량이 없어지고, 중심으로
    // 자유낙하해 반대편으로 솟아 판 밖으로 나간다(자세한 근거는 `kStarAge` 의 후보 기록).
    bhs[i].vx = vx; bhs[i].vy = vy; bhs[i].vz = vz;
    bhs[i].mass = mass;
    // **지평선은 질량에서만 나온다** — `setRsFrom` 이 `2GM/c²` 하나로 낸다.
    // 「처음 크기 × 세제곱근 성장」과 그 기준값(`bhMassAtBirth`·`bhRsAtBirth`)은
    // 부풀리기용이라 함께 지웠다(2026-08-18).
    setRsFrom(i);
    // 이 자리에 남아 있던 삼킨 수를 지운다 — 안 지우면 새 블랙홀의 질량에 얹힌다.
    if (eaten) CK(cudaMemset(eaten + i, 0, sizeof(int)));
    return i;
}

// 블랙홀을 한 스텝 움직이고, 겹친 것끼리 합친다.
//
// **블랙홀도 질량이 있으니 중력을 받는다.** 오래 고정된 점이었는데, 여럿을 놓을 수 있게
// 되면서 그 고정이 눈에 걸린다 — 둘이 서로를 돌다 합쳐지는 것이 이 장면에서 가장 볼 만한
// 일이고, 움직이지 않으면 그 일이 아예 일어나지 않는다.
//
// 받는 힘은 둘이다. 둘레 물질이 끄는 힘(격자에서 뽑아 온다)과 다른 블랙홀이 끄는 힘.
// 뒤엣것은 여덟 개면 64번이라 host 에서 해도 티가 나지 않는다.
void Sim::Impl::advanceBlackHoles(float dt) {
    if (bhCount <= 0 || g_failed) return;

    float4 ga[kMaxBlackHoles] = {};
    CK(cudaMemcpy(ga, bhAcc, sizeof(float4) * bhCount, cudaMemcpyDeviceToHost));
    if (g_failed) return;

    const float inv = 1.0f / (float)(allocN > 0 ? allocN : 1);

    for (int i = 0; i < bhCount; ++i) {
        float ax = ga[i].x, ay = ga[i].y, az = ga[i].z;
        for (int j = 0; j < bhCount; ++j) {
            if (j == i) continue;
            const float dx = bhs[i].x - bhs[j].x;
            const float dy = bhs[i].y - bhs[j].y;
            const float dz = bhs[i].z - bhs[j].z;
            // 무름 길이. 없으면 가까워지는 순간 힘이 발산해 서로를 튕겨 내고, 합쳐지기는
            // 커녕 판 밖으로 날아간다.
            //
            // **격자 한 칸을 바닥으로 쓴다(2026-08-18).** 전에는 `max(rs 합, 1e-4)` 였는데,
            // 지평선이 실제 크기가 되면서 rs 합이 1.2e-6 이라 임의 상수 1e-4 가 늘 이겼다.
            // 그 값에서 최대 가속도가 4.6e5 라 **두 블랙홀이 만나면 광속의 7배로 튕겨
            // 나갔다**(블랙홀은 광속 절단을 안 받는다). 격자 한 칸보다 가까운 것은 이 판이
            // 원리적으로 구분하지 못하므로, 알갱이 쪽 소프트닝과 같은 눈금을 쓰는 것이 맞다.
            const float cell = 1.0f / (float)(allocG > 0 ? allocG : 1);
            const float soft = fmaxf(bhs[i].rs + bhs[j].rs, cell);
            const float r2 = dx * dx + dy * dy + dz * dz + soft * soft;
            const float r  = sqrtf(r2);
            const float m  = -cfg.gravity * bhs[j].mass * inv / (r2 * r);
            ax += m * dx; ay += m * dy; az += m * dz;
        }

        // ── 동역학적 마찰 (찬드라세카르) ────────────────────────────────────
        //
        // **무거운 것일수록 느려야 하는데 반대였다** — 2026-08-18 사용자가 「제일 무거운
        // 블랙홀이 제일 빠르게 움직이고있어」로 알렸다.
        //
        // 위 격자 가속도는 **단위질량당**이라 질량과 무관하다(등가원리). 그것은 맞다.
        // 빠진 것은 **감속**이다. 여태 감속 기제가 「직접 삼킨 물질의 운동량 흡수」 하나뿐
        // 이었는데, 그것은 지평선 안에 들어온 것만 세므로 실제 마찰의 아주 작은 몫이다.
        //
        // 실제로는 **삼키지 않고 스쳐 가는 물질**이 블랙홀 중력에 끌려 뒤쪽에 밀집대를
        // 만들고, 그 밀집대가 블랙홀을 뒤로 잡아당긴다. 찬드라세카르가 푼 그 힘은
        //
        //     a_df = −4π ln(Λ) G² M ρ / v³ · v⃗
        //
        // 이고 **블랙홀 질량 M 에 비례한다.** 그래서 무거울수록 빨리 느려져 은하 중심에
        // 가라앉고, 실제 초대질량 블랙홀이 중심에 거의 붙박여 있는 이유가 이것이다.
        // 가벼운 것은 마찰이 약해 오래 떠돈다 — 사용자가 본 순서가 뒤집힌다.
        //
        // **연출이 아니다.** 새 힘을 지어내는 것이 아니라 빠져 있던 항을 넣는 것이고,
        // 값도 그 자리의 실제 밀도(`kSampleAccAtBH` 가 격자에서 읽어 온 것)와 실제 질량·
        // 속도로 낸다. 물질이 없는 곳(ρ=0)에서는 저절로 0 이다.
        //
        // 속도가 0 에 가까울 때 `1/v³` 이 발산하므로 무름 속도를 더한다. 실제 공식의
        // `erf(X) − 2X e^(−X²)/√π` 항이 하는 일 — 주변 속도 분산보다 느린 것은 마찰이
        // 급격히 줄어든다 — 을 같은 모양으로 대신한다.
        // **밖에서 볼 창을 먼저 채운다.** 조건문 안에 두면 마찰이 안 걸린 스텝에 값이
        // 남아 있어, 「안 걸렸다」와 「걸렸는데 약하다」가 구분되지 않는다. `drag` 를
        // 0 으로 두고 시작해 실제로 건 스텝에만 덮는다.
        bhs[i].rho  = ga[i].w * inv;
        bhs[i].drag = 0.f;
        if (cfg.bhFrictionK > 0.f && ga[i].w > 0.f && bhs[i].mass > 0.f) {
            const float vx = bhs[i].vx, vy = bhs[i].vy, vz = bhs[i].vz;
            const float v2 = vx * vx + vy * vy + vz * vz;
            // 무름 속도 = 이 판의 회전 속도 눈금(실측 0.25)의 1/5. 이보다 느려지면
            // 마찰이 빠르게 사라져 중심에서 떨리지 않고 멎는다.
            const float vSoft = 0.05f;
            const float vs = v2 + vSoft * vSoft;
            // 실제 질량은 「삼킨 개수 ÷ 총 개수」다(총질량 1 눈금). 밀도 격자 값도
            // 알갱이 수 단위라 같은 눈금으로 맞춘다.
            const float M   = bhs[i].mass * inv;
            const float rho = ga[i].w * inv;
            // 4π·ln(Λ) 를 묶은 계수. ln(Λ)≈10 이 은하 눈금의 표준값이라 4π·10 ≈ 126 이다.
            const float kDF = 126.0f * cfg.bhFrictionK;
            float mag = kDF * cfg.gravity * cfg.gravity * M * rho / (vs * sqrtf(vs));
            // **한 스텝에 속도를 뒤집지 않는다.** 마찰은 감속이지 반사가 아니다 —
            // `mag·dt > 1` 이 되면 속도 부호가 뒤바뀌어 블랙홀이 튕겨 나간다.
            // 밀도가 아주 높은 칸(은하 중심)에서 실제로 그 값이 나온다.
            const float maxMag = 0.5f / fmaxf(dt, 1e-9f);
            if (mag > maxMag) mag = maxMag;
            ax -= mag * vx; ay -= mag * vy; az -= mag * vz;
            bhs[i].drag = mag;               // 밖에서 보는 창(바로 위 참조)
        }

        bhs[i].vx += ax * dt;
        bhs[i].vy += ay * dt;
        bhs[i].vz += az * dt;
    }

    for (int i = 0; i < bhCount; ++i) {
        bhs[i].x += bhs[i].vx * dt;
        bhs[i].y += bhs[i].vy * dt;
        bhs[i].z += bhs[i].vz * dt;

        if (periodic()) {
            bhs[i].x -= floorf(bhs[i].x);
            bhs[i].y -= floorf(bhs[i].y);
            bhs[i].z -= floorf(bhs[i].z);
        } else {
            // 판 밖으로 나가면 붙잡고 되튄다. 알갱이에 쓰는 규칙과 같다.
            if (bhs[i].x < 0.01f) { bhs[i].x = 0.01f; bhs[i].vx = fabsf(bhs[i].vx) * 0.25f; }
            if (bhs[i].x > 0.99f) { bhs[i].x = 0.99f; bhs[i].vx = -fabsf(bhs[i].vx) * 0.25f; }
            if (bhs[i].y < 0.01f) { bhs[i].y = 0.01f; bhs[i].vy = fabsf(bhs[i].vy) * 0.25f; }
            if (bhs[i].y > 0.99f) { bhs[i].y = 0.99f; bhs[i].vy = -fabsf(bhs[i].vy) * 0.25f; }
            if (bhs[i].z < 0.01f) { bhs[i].z = 0.01f; bhs[i].vz = fabsf(bhs[i].vz) * 0.25f; }
            if (bhs[i].z > 0.99f) { bhs[i].z = 0.99f; bhs[i].vz = -fabsf(bhs[i].vz) * 0.25f; }
        }
    }

    // 겹친 것끼리 합친다 — **질량과 운동량을 지킨다.**
    // 이 자리가 실제 우주에서 중력파를 내는 사건이고, 화면에서도 가장 볼 만하다.
    for (int i = 0; i < bhCount; ++i) {
        for (int j = i + 1; j < bhCount; ++j) {
            const float dx = bhs[i].x - bhs[j].x;
            const float dy = bhs[i].y - bhs[j].y;
            const float dz = bhs[i].z - bhs[j].z;
            const float d  = sqrtf(dx * dx + dy * dy + dz * dz);
            // **격자 한 칸 안에 들면 합친다(2026-08-18).**
            //
            // 실제 병합은 두 지평선이 닿을 때 일어난다. 그런데 지금 지평선 합은 1.2e-6 이고
            // 한 스텝 이동은 2.15e-4 라 **180배를 건너뛴다** — 판정선을 지평선에 두면 두
            // 블랙홀이 서로를 그냥 통과해 영원히 안 합쳐진다. 실제 우주에서 그 간격을 좁히는
            // 것은 중력파 방출인데 이 판에는 그 항이 없다.
            //
            // 격자 한 칸보다 가까운 두 점질량은 이 판의 중력이 이미 하나로 취급한다(위
            // 무름 길이와 같은 근거). 그 자리에서 합치는 것이 계산과 앞뒤가 맞는다.
            const float cellM = 1.0f / (float)(allocG > 0 ? allocG : 1);
            if (d > fmaxf(bhs[i].rs + bhs[j].rs, cellM)) continue;

            const float mi = bhs[i].mass, mj = bhs[j].mass;
            const float mt = fmaxf(mi + mj, 1e-6f);
            bhs[i].x  = (bhs[i].x  * mi + bhs[j].x  * mj) / mt;
            bhs[i].y  = (bhs[i].y  * mi + bhs[j].y  * mj) / mt;
            bhs[i].z  = (bhs[i].z  * mi + bhs[j].z  * mj) / mt;
            bhs[i].vx = (bhs[i].vx * mi + bhs[j].vx * mj) / mt;
            bhs[i].vy = (bhs[i].vy * mi + bhs[j].vy * mj) / mt;
            bhs[i].vz = (bhs[i].vz * mi + bhs[j].vz * mj) / mt;
            bhs[i].mass = mt;
            setRsFrom(i);

            // j 를 빼고 뒤를 당긴다 — 가운데를 비워 두면 번호가 어긋난다(맨 위 불변식).
            for (int k = j; k + 1 < bhCount; ++k) {
                bhs[k]           = bhs[k + 1];
            }
            --bhCount;
            bhs[bhCount] = BlackHoleState{};
            --j;
            // 「삼킨 수」는 이 스텝에서 이미 다 읽어 0 으로 비워 둔 뒤라, 당겨도 섞이지 않는다.
        }
    }
}

void Sim::Impl::freeAll() {
    auto F = [](void*& p) { if (p) { cudaFree(p); p = nullptr; } };
    F((void*&)pos); F((void*&)vel); F((void*&)posTmp); F((void*&)velTmp);
    F((void*&)temp); F((void*&)tempTmp);
    F((void*&)accG); F((void*&)accPress); F((void*&)accContact); F((void*&)rho); F((void*&)pot);
    F((void*&)proj); F((void*&)projA); F((void*&)projB); F((void*&)accMag);
    F((void*&)projT); F((void*&)bornStat);
    F((void*&)dispX); F((void*&)dispY); F((void*&)dispZ); F((void*&)dispCnt);
    F((void*&)velSumX); F((void*&)velSumY); F((void*&)velSumZ);
    F((void*&)ashGrid);
    F((void*&)bhCand); F((void*&)bhCandV); F((void*&)bhCandN); F((void*&)bhBlockedCount);
    F((void*&)specRho); F((void*&)specGreen);
    F((void*&)keys); F((void*&)order); F((void*&)cellStart); F((void*&)cellEnd);
    F((void*&)flag); F((void*&)scan);
    F(sortTmp); F(redTmp);
    F((void*&)redD); F((void*&)redI); F((void*&)redU); F((void*&)redF);
    F((void*&)eaten); F((void*&)eatenP); F((void*&)bhAcc);
    sortTmpBytes = 0; redTmpBytes = 0;
    if (planReady) { cufftDestroy(planR2C); cufftDestroy(planC2R); planReady = false; }
}

void Sim::Impl::allocate() {
    freeAll();
    const int N = allocN, G = allocG, S = stride();
    const size_t cells = padCells();
    const size_t spec = (size_t)S * S * (S / 2 + 1);

    CK(cudaMalloc(&pos, sizeof(float4) * N));
    CK(cudaMalloc(&vel, sizeof(float4) * N));
    CK(cudaMalloc(&posTmp, sizeof(float4) * N));
    CK(cudaMalloc(&velTmp, sizeof(float4) * N));
    CK(cudaMalloc(&temp, sizeof(float) * N));
    CK(cudaMalloc(&tempTmp, sizeof(float) * N));
    CK(cudaMalloc(&accMag, sizeof(float) * N));
    CK(cudaMalloc(&accContact, sizeof(float4) * N));
    CK(cudaMalloc(&accG, sizeof(float4) * (size_t)G * G * G));
    // 압력 가속도 격자. `accG` 와 같은 G³ 이고, **잡은 직후 비운다** — 압력이 꺼져 있으면
    // 아무도 안 쓰는데 적분이 읽으므로 미초기화 값이 그대로 힘이 된다.
    CK(cudaMalloc(&accPress, sizeof(float4) * (size_t)G * G * G));
    CK(cudaMemset(accPress, 0, sizeof(float4) * (size_t)G * G * G));
    // 압력 격자 넷. **패딩 없이 G³ 이다**(kPressure 주석 참조 — 국소 미분이라 패딩이 필요 없다).
    // 잡은 직후에 반드시 비운다. 미초기화 값을 분산으로 읽으면 첫 스텝에 판이 통째로 터진다 —
    // 이 프로젝트에서 미초기화 배열로 죽은 적이 이미 있다.
    {
        const size_t gcells = (size_t)G * G * G;
        CK(cudaMalloc(&dispX, sizeof(float) * gcells));
        CK(cudaMalloc(&dispY, sizeof(float) * gcells));
        CK(cudaMalloc(&dispZ, sizeof(float) * gcells));
        CK(cudaMalloc(&dispCnt, sizeof(float) * gcells));
        CK(cudaMemset(dispX, 0, sizeof(float) * gcells));
        CK(cudaMemset(dispY, 0, sizeof(float) * gcells));
        CK(cudaMemset(dispZ, 0, sizeof(float) * gcells));
        CK(cudaMemset(dispCnt, 0, sizeof(float) * gcells));
        // 칸별 속도 합. 냉각 1단계가 채우고 2단계가 읽는다.
        CK(cudaMalloc(&velSumX, sizeof(float) * gcells));
        CK(cudaMalloc(&velSumY, sizeof(float) * gcells));
        CK(cudaMalloc(&velSumZ, sizeof(float) * gcells));
        CK(cudaMemset(velSumX, 0, sizeof(float) * gcells));
        CK(cudaMemset(velSumY, 0, sizeof(float) * gcells));
        CK(cudaMemset(velSumZ, 0, sizeof(float) * gcells));
        // 재는 **분산과 달리 매 바퀴 비우지 않는다** — 쌓이는 것이 그 자체로 역사다.
        // 그래서 여기서만 초기화한다. 안 비우면 미초기화 값이 냉각률로 들어가 판이 터진다.
        CK(cudaMalloc(&ashGrid, sizeof(float) * gcells));
        CK(cudaMemset(ashGrid, 0, sizeof(float) * gcells));
    }
    // 블랙홀 후보 다리. 잡은 직후 반드시 비운다 — 미초기화 후보 수를 읽으면
    // 쓰레기 좌표로 블랙홀이 생긴다.
    CK(cudaMalloc(&bhCand, sizeof(float4) * kMaxBlackHoles));
    CK(cudaMalloc(&bhCandV, sizeof(float4) * kMaxBlackHoles));
    CK(cudaMalloc(&bhCandN, sizeof(int)));
    CK(cudaMalloc(&bhBlockedCount, sizeof(int)));
    CK(cudaMemset(bhCand, 0, sizeof(float4) * kMaxBlackHoles));
    CK(cudaMemset(bhCandV, 0, sizeof(float4) * kMaxBlackHoles));
    CK(cudaMemset(bhCandN, 0, sizeof(int)));
    CK(cudaMemset(bhBlockedCount, 0, sizeof(int)));
    CK(cudaMalloc(&rho, sizeof(float) * cells));
    CK(cudaMalloc(&pot, sizeof(float) * cells));
    CK(cudaMalloc(&proj, sizeof(float) * (size_t)G * G));
    CK(cudaMalloc(&projA, sizeof(float) * (size_t)G * G));
    CK(cudaMalloc(&projB, sizeof(float) * (size_t)G * G));
    // 온도 격자. 화면 격자라 128² × 4B = 65 KB 밖에 안 든다.
    CK(cudaMalloc(&projT, sizeof(float) * (size_t)G * G));
    CK(cudaMemset(projT, 0, sizeof(float) * (size_t)G * G));
    CK(cudaMalloc(&bornStat, sizeof(double) * 4));
    CK(cudaMemset(bornStat, 0, sizeof(double) * 4));
    CK(cudaMalloc(&specRho, sizeof(cufftComplex) * spec));
    CK(cudaMalloc(&specGreen, sizeof(cufftComplex) * spec));
    CK(cudaMalloc(&keys, sizeof(int) * N));
    CK(cudaMalloc(&order, sizeof(int) * N));
    CK(cudaMalloc(&flag, sizeof(int) * N));
    CK(cudaMalloc(&scan, sizeof(int) * N));
    CK(cudaMalloc(&cellStart, sizeof(int) * (size_t)G * G * G));
    CK(cudaMalloc(&cellEnd, sizeof(int) * (size_t)G * G * G));
    // **2 에서 4 로 늘렸다(2026-08-16).** 총 운동량이 x·y·z 세 칸을 쓴다 —
    // 2칸짜리에 3칸을 `cudaMemset` 하면 범위 밖 쓰기이고, 그 뒤 커널들이 조용히 실패한다.
    // 4 → 12 로 늘렸다(2026-08-17). 회전곡선이 반지름 네 구간의 합·개수로 8칸을 쓴다.
    // 12 → 64 로 늘렸다(2026-08-19). 나선 진폭이 링 16 개 × (re,im,sum) 로 48칸을 쓴다.
    // 64 → 128 로 늘렸다(같은 날). 질량과 빛을 따로 재면서 그 두 배가 됐다(96칸).
    CK(cudaMalloc(&redD, sizeof(double) * 128));
    // 상태별 개수 5칸 + 셀 최대 점유 1칸 + 여유. 늘려 두어도 32바이트다.
    CK(cudaMalloc(&redI, sizeof(int) * 8));
    CK(cudaMalloc(&redU, sizeof(unsigned long long)));
    CK(cudaMalloc(&redF, sizeof(float)));
    // 삼킨 수와 블랙홀 자리의 가속도는 블랙홀마다 하나씩. 잡은 직후에 반드시 비운다 —
    // 미초기화 값을 그대로 읽어 질량에 더하면 블랙홀이 난데없이 무거워진다.
    CK(cudaMalloc(&eaten, sizeof(int) * kMaxBlackHoles));
    CK(cudaMalloc(&eatenP, sizeof(float) * 3 * kMaxBlackHoles));
    CK(cudaMemset(eatenP, 0, sizeof(float) * 3 * kMaxBlackHoles));
    CK(cudaMalloc(&bhAcc, sizeof(float4) * kMaxBlackHoles));
    CK(cudaMemset(eaten, 0, sizeof(int) * kMaxBlackHoles));
    CK(cudaMemset(bhAcc, 0, sizeof(float4) * kMaxBlackHoles));

    if (!g_failed) {
        FK(cufftPlan3d(&planR2C, S, S, S, CUFFT_R2C));
        FK(cufftPlan3d(&planC2R, S, S, S, CUFFT_C2R));
        planReady = !g_failed;
    }
    if (!evA) {
        CK(cudaEventCreate(&evA)); CK(cudaEventCreate(&evB));
        CK(cudaEventCreate(&ev1)); CK(cudaEventCreate(&ev2)); CK(cudaEventCreate(&ev3));
    }
}

// 고립 경계용 그린함수를 미리 변환해 둔다. 격자가 바뀔 때만 다시 만든다.
void Sim::Impl::buildGreen() {
    if (periodic() || g_failed || !planReady) return;
    const int S = stride();
    const float soft = fmaxf(cfg.softeningCells, 0.5f);
    kGreen<<<grd3(S), blk3()>>>(pot, S, allocG, soft);
    FK(cufftExecR2C(planR2C, pot, specGreen));
    CK(cudaGetLastError());
}

void Sim::Impl::scatterMass() {
    if (g_failed) return;
    const size_t cells = padCells();
    kClearF<<<(int)((cells + 255) / 256), 256>>>(rho, (int)cells);
    kScatter<<<(allocN + 255) / 256, 256>>>(pos, allocN, rho, allocG, stride(), periodic() ? 1 : 0);
    CK(cudaGetLastError());
}

void Sim::Impl::solvePoisson() {
    if (g_failed || !planReady) return;
    const int S = stride();
    const size_t spec = (size_t)S * S * (S / 2 + 1);
    const float norm = 1.0f / (float)((double)S * S * S);

    FK(cufftExecR2C(planR2C, rho, specRho));
    if (periodic()) {
        // 3D 뉴턴 중력은 주파수공간에서 -1/k² 다. 배율에 FFT 정규화를 함께 싣는다.
        const float scale = norm / (4.0f * 3.14159265f * 3.14159265f);
        dim3 b(8, 8, 8), g((S / 2 + 1 + 7) / 8, (S + 7) / 8, (S + 7) / 8);
        kPoissonPeriodic<<<g, b>>>(specRho, S, scale, cfg.softeningCells);
    } else {
        kMulSpec<<<(int)((spec + 255) / 256), 256>>>(specRho, specGreen, (int)spec, norm);
    }
    FK(cufftExecC2R(planC2R, specRho, pot));
    CK(cudaGetLastError());
}

void Sim::Impl::computeAccel() {
    if (g_failed) return;
    scatterMass();
    solvePoisson();
    kGridAccel<<<grd3(allocG), blk3()>>>(pot, accG, allocG, stride(), potScale(),
                                         periodic() ? 1 : 0);

    // 압력을 중력 **위에 더한다**. kGridAccel 이 accG 를 덮어쓰므로 반드시 그 뒤여야 한다.
    //
    // **분산 격자는 8스텝에 한 번 갱신되는데(doCooling) 압력은 매 스텝 더한다.**
    // 일부러 그렇게 나눴다 — 분산을 매 스텝 다시 재려면 399만 개를 매 스텝 줄 세워야 하고,
    // 그것이 2026-08-14 에 드라이버를 죽인 바로 그 일이다. 분산은 천천히 변하는 값이라
    // 여덟 스텝 묵은 값을 써도 힘이 튀지 않는다.
    // 압력 격자는 **매 스텝 먼저 비운다.** `kPressure` 는 알갱이가 있는 칸에만 쓰므로,
    // 비우지 않으면 알갱이가 떠난 칸에 지난 스텝의 힘이 남아 다음에 지나가는 것을 민다.
    // 압력이 꺼져 있으면 비워진 채로 있어 적분이 0 을 더한다.
    {
        const int gcells = allocG * allocG * allocG;
        kClearF4<<<(gcells + 255) / 256, 256>>>(accPress, gcells);
    }
    if (cfg.pressureEnabled) {
        // 상한은 중력 쪽과 같은 자리에서 잘라야 뜻이 있다. kIntegrate 가 쓰는 값과 맞춘다.
        constexpr float kMaxPressureAcc = 5.0f;
        kPressure<<<grd3(allocG), blk3()>>>(dispX, dispY, dispZ, dispCnt, accPress,
                                            allocG, periodic() ? 1 : 0,
                                            cfg.pressureK, kMaxPressureAcc);
    }
    CK(cudaGetLastError());
}

void Sim::Impl::placeInitial() {
    if (g_failed) return;
    const int preset = (cfg.preset == Preset::SpiralDisk) ? 0
                     : (cfg.preset == Preset::Filament)   ? 1 : 2;
    // **씨앗 12345 는 `giveOrbits` 의 `kSetOrbit` 도 그대로 받아야 한다** — 두 커널이 같은
    // 해시로 CGM 가스를 골라내므로, 씨앗이 다르면 자리와 속도가 서로 다른 알갱이에 간다.
    kPlace<<<(allocN + 255) / 256, 256>>>(pos, vel, allocN, preset,
                                          cfg.bulgeFraction, cfg.bulgeRadius,
                                          cfg.diskThickness, 12345u,
                                          cfg.darkMatterFraction,
                                          (preset == 0) ? cfg.haloGasFraction : 0.f,
                                          (preset == 0) ? cfg.sphereStart : 0.f,
                                          (preset == 1) ? cfg.bigBangShrink : 0.f);
    CK(cudaGetLastError());
    active = (preset == 2) ? 0 : allocN;
    aliveShown = -1;                       // 판을 새로 열었으니 세어 둔 값은 버린다
}

void Sim::Impl::giveOrbits() {
    // 필라멘트는 원 궤도를 주지 않는다 — 판 전체가 우주 한 조각이라 「무엇을 도는가」가
    // 없다. 각운동량은 `cfg.spin` 이 판 전체에 주는 회전으로 들어간다(`kAddSpin`).
    if (g_failed || cfg.preset == Preset::Empty || cfg.preset == Preset::Filament) return;
    computeAccel();
    // 적분기가 쓰는 힘을 그대로 넘긴다 — 하나라도 빠지면 궤도가 어긋나 원반이 무너진다.
    kAccelMag<<<(allocN + 255) / 256, 256>>>(accG, pos, accMag, allocN, allocG,
                                             periodic() ? 1 : 0, packBH());
    // 은하 충돌은 둘을 서로에게 밀어 준다. 나머지는 제자리에서 돈다.
    const float2 base = make_float2(0.f, 0.f);
    // CGM 가스에 느린 회전을 주려면 **`placeInitial` 이 쓴 것과 같은 씨앗**이 필요하다
    // (`kPlace` 의 12345). 그 사이에 정렬이 없어 알갱이 번호가 유지되므로, 같은 해시가
    // 같은 알갱이를 가리킨다.
    const bool haloScene = (cfg.preset == Preset::SpiralDisk);
    kSetOrbit<<<(allocN + 255) / 256, 256>>>(vel, pos, accMag, allocN,
                                             cfg.bulgeRadius, base, cfg.diskThickness,
                                             12345u, haloScene ? cfg.haloGasFraction : 0.f,
                                             fmaxf(cfg.diskDispersion, 0.f),
                                             fminf(fmaxf(cfg.diskSpinLag, 0.f), 0.9f));
    CK(cudaGetLastError());
}

void Sim::Impl::sortParticles() {
    if (g_failed || allocN <= 0) return;
    kCellKey<<<(allocN + 255) / 256, 256>>>(pos, allocN, allocG, keys, order);
    size_t need = 0;
    cub::DeviceRadixSort::SortPairs(nullptr, need, keys, keys, order, order, allocN);
    if (need > sortTmpBytes) {
        if (sortTmp) cudaFree(sortTmp);
        CK(cudaMalloc(&sortTmp, need));
        sortTmpBytes = need;
    }
    if (g_failed) return;
    cub::DeviceRadixSort::SortPairs(sortTmp, sortTmpBytes, keys, keys, order, order, allocN);
    kReorder<<<(allocN + 255) / 256, 256>>>(pos, vel, temp, order, posTmp, velTmp, tempTmp, allocN);
    std::swap(pos, posTmp); std::swap(vel, velTmp); std::swap(temp, tempTmp);
    CK(cudaGetLastError());
}

void Sim::Impl::doContact() {
    // 세 힘 중 하나라도 켜져 있으면 이웃을 훑는다 — 넷이 같은 이웃 목록을 나눠 쓴다.
    const bool wantAny = cfg.contactEnabled || cfg.strongForceEnabled || cfg.emForceEnabled;
    if (g_failed || !wantAny) return;
    const int G = allocG;

    // **밖에서 켜 달라고 해도 코어가 자른다.**
    //
    // 이 이웃 훑기는 매 스텝 알갱이를 줄 세우고 27칸을 뒤진다. 알갱이가 판을 꽉 채우면
    // 그 값이 감당 못 할 만큼 오르는데, 설정 창은 그 선을 알고 막아도(ContactFitsCount)
    // 제어 채널로 들어오는 값은 그 창을 지나지 않는다. 같은 선을 여기서 다시 건다
    // — 한계를 아는 쪽이 코어다. (기준: N ≤ 0.764·G³, 격자 128 이면 160만)
    if ((double)allocN > 0.764 * (double)G * (double)G * (double)G) return;
    const size_t cells = (size_t)G * G * G;
    // 정렬해 둬야 칸별 구간을 뽑을 수 있다.
    sortParticles();
    kFillInt<<<(int)((cells + 255) / 256), 256>>>(cellStart, (int)cells, -1);
    kFillInt<<<(int)((cells + 255) / 256), 256>>>(cellEnd, (int)cells, -1);
    kBuildCellRange<<<(allocN + 255) / 256, 256>>>(keys, allocN, cellStart, cellEnd);
    // 반지름은 격자 칸의 절반. 지름이 정확히 한 칸이라 이웃 27칸만 보면 충분하다.
    const float radius = 0.5f / (float)G;
    ForcePack fp{};
    // **새 힘이 켜져 있으면 접촉은 물러난다.**
    //
    // 강한핵력이 이미 「가까우면 밀어낸다」를 하므로 하는 일이 겹치고, 무엇보다 접촉의
    // 강성 1e6 은 명시적 적분에 과하다 — 겹침이 깊어지면 한 스텝에 속도가 11 씩 뛰어
    // 어떤 감쇠로도 못 잡는다(2026-08-15 실측: 접촉만 켜도 광속의 절반을 넘겼고, 이는
    // 세 힘이 없는 0.6.2 에서도 같다). 겹치지 않게 하는 일은 강한핵력에 맡긴다.
    const bool contactOn = cfg.contactEnabled
                        && !cfg.strongForceEnabled && !cfg.emForceEnabled;
    fp.contact = contactOn ? 1 : 0;
    fp.strong  = cfg.strongForceEnabled ? 1 : 0;
    fp.em      = cfg.emForceEnabled     ? 1 : 0;
    fp.strongK = cfg.strongForceK;
    fp.emK     = cfg.emForceK;
    fp.damp    = cfg.newForceDamping;
    fp.charge  = cfg.emForceEnabled ? temp : nullptr;
    kContact<<<(allocN + 255) / 256, 256>>>(pos, vel, allocN, G, G, periodic() ? 1 : 0,
                                            cellStart, cellEnd, radius,
                                            cfg.contactStiffness, cfg.contactDamping,
                                            fp, accContact);
    // 약한핵력은 부호를 뒤집을 뿐이라 힘 계산과 따로 돈다. 전자기력이 꺼져 있으면
    // 부호를 아무도 보지 않으므로 돌릴 까닭이 없다.
    if (cfg.weakForceEnabled && cfg.emForceEnabled)
        kWeakDecay<<<(allocN + 255) / 256, 256>>>(temp, pos, allocN,
                                                  cfg.weakForceRate * 0.02f,
                                                  (unsigned)(stepCount * 7919 + 13));
    CK(cudaGetLastError());
}

void Sim::Impl::countAlive() {
    if (g_failed || allocN <= 0 || !redI) return;
    CK(cudaMemset(redI, 0, sizeof(int)));
    kCountAlive<<<(allocN + 255) / 256, 256>>>(pos, allocN, redI);
    int n = 0;
    CK(cudaMemcpy(&n, redI, sizeof(int), cudaMemcpyDeviceToHost));
    if (!g_failed) aliveShown = n;
}

void Sim::Impl::doCooling(float dt) {
    // 이름은 냉각이지만 실제로는 **이웃 훑기 한 판**이다 — 냉각과 속도 분산(압력의 재료)이
    // 둘 다 여기서 나온다. 둘 중 하나만 켜도 돌아야 하므로 조건을 따로 본다.
    const bool wantCool     = cfg.coolingEnabled && cfg.coolingRate > 0.f;
    const bool wantPressure = cfg.pressureEnabled;
    if (g_failed || dt <= 0.f) return;
    if (!wantCool && !wantPressure) return;
    const int G = allocG;

    // **몇 스텝에 한 번만 식힌다. 매 스텝 하면 시스템이 죽는다.**
    //
    // 식히려면 이웃을 알아야 하고, 이웃을 알려면 알갱이를 칸 순서로 줄 세워야 한다.
    // 접촉이 꺼져 있으면 그 줄 세우기를 여기서 해야 하는데, 그것을 매 스텝 하도록
    // 두었더니 알갱이 399만에서 초당 60번씩 radix sort + 격자 209만 칸 초기화가 돌았고
    // 드라이버가 타임아웃돼 시스템이 재부팅됐다(2026-08-14 22:58, BugCheck 0xD1).
    //
    // 여덟 스텝에 한 번 하고 dt 를 그만큼 곱한다. 식히기는 여러 스텝에 걸친 평균이라
    // 결과가 같고, 값은 8분의 1이 된다. 접촉이 켜져 있으면 그쪽이 이미 매 스텝
    // 줄을 세워 두므로 얹혀 간다(공짜다).
    // **압력을 쓰면 주기를 짧게 한다.** 압력은 이 격자를 매 스텝 읽는데, 여덟 스텝 묵은
    // 기울기로 계속 밀면 **위상이 어긋난 힘이 일을 한다** — 이미 밀려난 자리를 같은 방향으로
    // 또 밀어 매번 에너지가 들어간다(round-02 실측: 냉각 없이 40초에 온도 2.2배).
    // 정렬 비용이 네 배가 되지만 에너지가 새는 것보다는 싸다.
    const int every = cfg.contactEnabled ? 1 : (cfg.pressureEnabled ? 2 : 8);
    if ((stepCount % every) != 0) return;
    dt *= (float)every;

    if (!cfg.contactEnabled) {
        const size_t cells = (size_t)G * G * G;
        sortParticles();
        kFillInt<<<(int)((cells + 255) / 256), 256>>>(cellStart, (int)cells, -1);
        kFillInt<<<(int)((cells + 255) / 256), 256>>>(cellEnd, (int)cells, -1);
        kBuildCellRange<<<(allocN + 255) / 256, 256>>>(keys, allocN, cellStart, cellEnd);
    }
    if (g_failed) return;

    // 분산을 쌓기 전에 **반드시 비운다.** 안 비우면 지난 번 값 위에 계속 더해져 압력이
    // 스텝마다 커지고, 몇 판 안 가 판이 통째로 날아간다.
    const size_t gcells = (size_t)G * G * G;
    if (wantPressure) {
        CK(cudaMemset(dispX, 0, sizeof(float) * gcells));
        CK(cudaMemset(dispY, 0, sizeof(float) * gcells));
        CK(cudaMemset(dispZ, 0, sizeof(float) * gcells));
        CK(cudaMemset(dispCnt, 0, sizeof(float) * gcells));
    }

    // **1단계 — 칸마다 속도를 모은다.** 여기서 나온 평균이 2단계의 기준이 된다.
    //
    // `dispCnt` 와 별개로 개수를 또 세는 이유: `dispCnt` 는 2단계가 「분산을 실제로 쌓은
    // 알갱이 수」로 채우고, 여기 `velSumCnt` 는 「그 칸에 있는 알갱이 수」다. 혼자 있는
    // 알갱이는 2단계에서 걸러지므로 둘이 달라진다.
    CK(cudaMemset(velSumX, 0, sizeof(float) * gcells));
    CK(cudaMemset(velSumY, 0, sizeof(float) * gcells));
    CK(cudaMemset(velSumZ, 0, sizeof(float) * gcells));
    // 개수는 `dispCnt` 가 안 쓰일 때(압력 꺼짐)도 필요하다. 임시로 `rho` 를 빌리지 않고
    // 1단계가 자기 것을 쓰게 두면 두 값의 뜻이 안 섞인다 — `velSumZ` 다음 칸을 쓰는 식의
    // 꼼수를 두지 않는다(그런 자리가 이 프로젝트에서 범위 밖 쓰기로 이어진 적이 있다).
    float* cellCnt = wantPressure ? dispCnt : nullptr;
    if (!cellCnt) {
        // 압력이 꺼져 있으면 분산 격자를 안 쓰지만 개수는 있어야 한다. 그때만 비워서 쓴다.
        CK(cudaMemset(dispCnt, 0, sizeof(float) * gcells));
        cellCnt = dispCnt;
    }
    kAccumCellVel<<<(allocN + 255) / 256, 256>>>(pos, vel, allocN, G, periodic() ? 1 : 0,
                                                 velSumX, velSumY, velSumZ, cellCnt);
    CK(cudaGetLastError());

    // 1단계가 채운 개수를 2단계가 평균의 분모로 쓰고, 2단계는 자기 몫을 다시 `dispCnt` 에
    // 쌓는다. **같은 배열을 읽으면서 쓰면 값이 섞이므로** 2단계는 읽기용으로 이 사본을 본다.
    // 격자 하나를 더 잡지 않으려고 `rho` 를 빌린다 — 이 시점의 `rho` 는 이번 스텝 중력에
    // 쓰이고 나서 다음 스텝 시작에 다시 채워지므로, 여기서 덮어써도 잃는 것이 없다.
    CK(cudaMemcpy(rho, cellCnt, sizeof(float) * gcells, cudaMemcpyDeviceToDevice));
    if (wantPressure) {
        CK(cudaMemset(dispCnt, 0, sizeof(float) * gcells));
    }

    // **2단계 — 칸 평균 쪽으로 당기고 분산을 쌓는다.**
    //
    // 제자리에서 고치면 옆 스레드가 이미 식은 값을 읽어 한쪽으로 쏠린다. 정렬이 쓰는
    // 임시 버퍼에 새 속도를 쓰고 통째로 바꿔 끼운다.
    //
    // 냉각이 꺼져 있으면 rate 에 0 을 넘긴다 — 커널 안에서 k=0 이 되어 속도가 그대로 나오고
    // 분산만 쌓인다.
    kCoolCell<<<(allocN + 255) / 256, 256>>>(pos, vel, allocN, G, periodic() ? 1 : 0,
                                             velSumX, velSumY, velSumZ, rho,
                                             wantCool ? cfg.coolingRate : 0.f, dt, velTmp,
                                             wantPressure ? dispX : nullptr,
                                             wantPressure ? dispY : nullptr,
                                             wantPressure ? dispZ : nullptr,
                                             wantPressure ? dispCnt : nullptr,
                                             ashGrid, cfg.ashCoolK);
    std::swap(vel, velTmp);
    CK(cudaGetLastError());

    // 광전리 되먹임 — 젊고 무거운 별이 둘레 가스를 데운다. **별 판정보다 먼저 돌아야**
    // 그 열이 이번 스텝의 Jeans 문턱에 반영된다(자세한 근거는 `kIonize` 주석).
    if (wantPressure && cfg.starIonizeK > 0.f) {
        kIonize<<<(allocN + 255) / 256, 256>>>(pos, vel, allocN, G, periodic() ? 1 : 0,
                                               dispX, dispY, dispZ, dispCnt,
                                               fmaxf(cfg.starSunMass, 1.0f),
                                               cfg.starIonizeK * 1.85e-4f);
        CK(cudaGetLastError());
    }

    // 초신성이 그 자리를 데운다 — 그 열을 압력이 받아 주변을 밀어낸다(위 커널 주석).
    // 이온화와 같은 통로라 나란히 둔다. 압력이 꺼져 있으면 밀 수단이 없으므로 함께 건다.
    if (wantPressure && cfg.starFormationEnabled && cfg.novaEnergyK > 0.f) {
        kSupernovaHeat<<<(allocN + 255) / 256, 256>>>(
            pos, allocN, G, periodic() ? 1 : 0, dispX, dispY, dispZ, dispCnt,
            fmaxf(cfg.starExplodeSim, 1e-4f), cfg.novaEnergyK * 1.85e-4f);
        CK(cudaGetLastError());
    }

    // 별 판정. **방금 갱신한 분산을 그대로 읽으므로 이웃을 다시 훑지 않는다** — O(N) 이다.
    // 압력이 꺼져 있으면 σ² 가 없어 Jeans 조건을 세울 수 없으므로 함께 켜져 있을 때만 돈다.
    if (wantPressure && cfg.starFormationEnabled) {
        kStarForm<<<(allocN + 255) / 256, 256>>>(pos, allocN, G, periodic() ? 1 : 0,
                                                 dispX, dispY, dispZ, dispCnt,
                                                 cfg.starJeansK,
                                                 fmaxf(cfg.starSunMass, 1.0f),
                                                 cfg.starFormEfficiency, dt,
                                                 (unsigned)(stepCount * 2246822519u + 374761393u),
                                                 ashGrid, bornStat, vel);
        CK(cudaGetLastError());
    }

    // 재 확산 — **별 판정 뒤에 돈다.** 이번 스텝의 별은 퍼지기 전 재를 보고 정해져야
    // 순서가 앞뒤로 안 섞인다. 임시 격자는 `velSumX` 를 빌린다 — 같은 G³ 이고 이 시점에는
    // 1단계가 쓰고 2단계가 다 읽은 뒤라 자유롭다(자세한 근거는 `kDiffuseAsh` 주석).
    if (ashGrid && cfg.ashDiffuseK > 0.f) {
        // **0.4 에서 자른다.** 명시적 확산은 계수가 0.5 를 넘으면 값이 진동하며 발산한다.
        const float k = fminf(cfg.ashDiffuseK * dt * 60.0f, 0.4f);
        kDiffuseAsh<<<grd3(G), blk3()>>>(ashGrid, velSumX, G, periodic() ? 1 : 0, k);
        CK(cudaGetLastError());
        CK(cudaMemcpy(ashGrid, velSumX, sizeof(float) * gcells, cudaMemcpyDeviceToDevice));
    }
}

// 한 칸에 중력이 접촉을 이길 만큼 쌓이면 그 자리가 무너져 블랙홀이 된다.
void Sim::Impl::checkCollapse() {
    // 자리가 다 차면 더 만들지 않는다. 밀어내기(addBlackHole)는 사용자가 놓을 때의 규칙이고,
    // 저절로 생기는 쪽이 남의 자리를 빼앗으면 놓아 둔 것이 소리 없이 사라진다.
    if (g_failed || !cfg.collapseEnabled || bhCount >= kMaxBlackHoles) return;
    const int G = allocG, S = stride();
    CK(cudaMemset(redU, 0, sizeof(unsigned long long)));
    kFindDensestCell<<<grd3(G), blk3()>>>(rho, G, S, redU);
    unsigned long long key = 0;
    CK(cudaMemcpy(&key, redU, sizeof(key), cudaMemcpyDeviceToHost));
    const float dens = (float)(unsigned)(key >> 32) / 256.0f;
    const float mean = (float)allocN / (float)((double)G * G * G);
    if (dens < cfg.collapseDensity * fmaxf(mean, 1e-9f)) return;

    const unsigned cell = (unsigned)(key & 0xFFFFFFFFull);
    const int cx = cell % G, cy = (cell / G) % G, cz = cell / (G * G);
    // 무너진 칸에 **쌓여 있던 질량**이 그대로 블랙홀이 된다.
    //
    // 전에는 질량을 0 으로 두고 지평선만 알갱이 하나분으로 냈다. 그러면 지평선이
    // 2·G·(1/N)/c² 라 사실상 0 이고, 화면에는 「블랙홀이 되었습니다 · 삼킨 알갱이 0 ·
    // 지평선 0.0000」이라는 앞뒤 안 맞는 말이 뜬다 — 실체 없는 블랙홀이었다.
    const int i = addBlackHole((cx + 0.5f) / G, (cy + 0.5f) / G, (cz + 0.5f) / G, dens, true);
    // 저절로 생긴 것은 지평선을 실제 식에서 낸다. 사용자가 놓은 것과 달리 「이만큼 모였다」가
    // 이미 정해져 있어, 보이게 부풀릴 근거가 그 최소 크기뿐이다.
    setRsFrom(i);
}

// ---------------------------------------------------------------------------
// 공개 인터페이스
// ---------------------------------------------------------------------------
Sim::Sim() : impl_(new Impl) {}
Sim::~Sim() { impl_->freeAll(); delete impl_; }

bool Sim::deviceAvailable() {
    int n = 0;
    return cudaGetDeviceCount(&n) == cudaSuccess && n > 0;
}
std::string Sim::deviceName() {
    cudaDeviceProp p{};
    if (cudaGetDeviceProperties(&p, 0) != cudaSuccess) return "unknown";
    return p.name;
}
std::string Sim::deviceDriver() {
    // NVIDIA 드라이버 번호(555.99 같은 것)는 여기서 알 수 없다 — 그건 NVML 이 준다.
    // 대신 그 드라이버가 지원하는 CUDA 판을 적는다.
    int v = 0;
    if (cudaDriverGetVersion(&v) != cudaSuccess || v <= 0) return "";
    char buf[32];
    snprintf(buf, sizeof(buf), "CUDA %d.%d", v / 1000, (v % 1000) / 10);
    return buf;
}
size_t Sim::deviceFreeBytes() {
    size_t f = 0, t = 0;
    if (cudaMemGetInfo(&f, &t) != cudaSuccess) return 0;
    return f;
}
int Sim::deviceMultiProcessors() {
    cudaDeviceProp p{};
    if (cudaGetDeviceProperties(&p, 0) != cudaSuccess) return 0;
    return p.multiProcessorCount;
}

// 이 설정으로 잡아야 할 VRAM.
//
// 3D 라 격자 쪽이 세제곱으로 자란다 — 고립 경계는 한 변을 두 배로 잡으므로 8배가 더 붙는다.
size_t Sim::estimateBytes(int particleCount, int gridSize, Boundary boundary) {
    const size_t N = (size_t)(particleCount > 0 ? particleCount : 1);
    const size_t G = (size_t)(gridSize > 0 ? gridSize : 1);
    const size_t S = (boundary == Boundary::Isolated) ? G * 2 : G;
    const size_t cells = S * S * S;
    const size_t spec = S * S * (S / 2 + 1);

    size_t b = 0;
    b += sizeof(float4) * N * 4;      // pos, vel, posTmp, velTmp
    b += sizeof(float)  * N * 3;      // temp, tempTmp, accMag
    b += sizeof(float4) * N;          // accContact
    b += sizeof(int)    * N * 4;      // keys, order, flag, scan
    b += sizeof(float4) * G * G * G;  // accG
    b += sizeof(float4) * G * G * G;  // accPress
    b += sizeof(float)  * cells * 2;  // rho, pot
    b += sizeof(cufftComplex) * spec * 2;
    b += sizeof(int) * G * G * G * 2; // cellStart, cellEnd
    // 압력 격자 넷(dispX/Y/Z/Cnt). **패딩 없이 G³ 이라 cells 가 아니라 G³ 로 센다** —
    // 고립 경계에서 cells 는 G³ 의 여덟 배고, 그걸로 세면 실제의 여덟 배를 잡아 둔 것으로
    // 계산해 알갱이 상한이 까닭 없이 내려간다. 128³ 에서 이 넷은 33 MB 다.
    b += sizeof(float) * G * G * G * 4;
    // 칸별 속도 합 셋(velSumX/Y/Z). 냉각이 칸 평균으로 당기려면 필요하고, 역시 G³ 다.
    // 128³ 에서 25 MB. 대신 알갱이당 이웃 96개 읽기가 사라졌다.
    b += sizeof(float) * G * G * G * 3;

    // **우리가 안 잡는데 우리 몫으로 잡히는 것 — CUDA 컨텍스트와 cuFFT 플랜.**
    //
    // 2026-08-17 실측: 100만·격자 128·고립에서 이 함수는 472 MB 를 냈는데
    // `nvidia-smi` 로 잰 실제 점유는 683 MB 였다. 알갱이를 20만·40만·60만으로
    // 내려도 595·623·651 MB 로, 알갱이에 비례하는 몫(110 바이트) 말고 **573 MB 짜리
    // 상수항**이 있다는 뜻이다.
    //
    // 그 상수는 우리가 `cudaMalloc` 한 것이 아니다 — CUDA 런타임이 컨텍스트를 만들 때
    // 커널 코드·상수 메모리·디바이스 힙으로 잡는 몫과 `cufftPlan3d` 가 내부에 잡는
    // 작업 버퍼다. 우리 배열 목록에는 안 나타나지만 **카드에서는 우리 프로세스 몫으로
    // 세어지므로**, 여유를 견줄 때 빼놓으면 없는 여유를 있다고 믿는다.
    //
    // 격자·알갱이와 무관한 고정 몫이라 상수로 더한다. 이 항을 넣으면 100만 추정이
    // 692 MB 로 실측 683 MB 와 맞는다.
    b += 220ull * 1024 * 1024;
    b += sizeof(float) * G * G * G;   // ashGrid — 재도 패딩 없이 G³ 다
    // 위 두 줄은 화면용 격자를 안 센다 — proj·projA·projB·projT 넷을 합쳐도
    // 128² 에서 256 KB 라 어림에 영향이 없다(하나가 64 KB).

    // cuFFT 작업 공간 — **어림하지 말고 물어본다.**
    //
    // 전에는 `cells * 2` 바이트로 어림했다. 512³ 에서 그것은 268 MB 인데, 실제로 잡히는
    // 것은 그 몇 배다. 게다가 플랜을 R2C·C2R 두 개 만드므로 두 번 든다. 어림이 작으면
    // maxParticlesFor 가 남는 양을 실제보다 크게 보고 알갱이를 그만큼 더 허락하는데,
    // 그 차이는 VRAM 이 바닥나는 자리에서 드러난다 — 가장 나쁜 시점이다.
    //
    // cufftEstimate3d 는 플랜을 만들지 않고도 필요한 양을 알려 준다. 못 물으면 그때만
    // 보수적인 어림(격자 하나 크기)으로 물러난다.
    {
        size_t wsR2C = 0, wsC2R = 0;
        const int s = (int)S;
        if (cufftEstimate3d(s, s, s, CUFFT_R2C, &wsR2C) != CUFFT_SUCCESS)
            wsR2C = sizeof(float) * cells;
        if (cufftEstimate3d(s, s, s, CUFFT_C2R, &wsC2R) != CUFFT_SUCCESS)
            wsC2R = sizeof(float) * cells;
        b += wsR2C + wsC2R;
    }
    return b;
}

// 이 카드의 메모리 대역폭(GB/s). 감당할 수 있는 격자를 어림하는 데 쓴다 —
// 격자 계산은 순전히 대역폭이 정하기 때문이다(FFT 는 산술보다 옮기는 일이 많다).
// 못 읽으면 0.
double Sim::deviceBandwidthGBs() {
    // CUDA 13 에서 cudaDeviceProp 의 memoryClockRate·memoryBusWidth 가 빠졌다.
    // 같은 값을 속성으로 물어본다.
    int kHz = 0, bits = 0;
    if (cudaDeviceGetAttribute(&kHz, cudaDevAttrMemoryClockRate, 0) != cudaSuccess) return 0.0;
    if (cudaDeviceGetAttribute(&bits, cudaDevAttrGlobalMemoryBusWidth, 0) != cudaSuccess) return 0.0;
    if (kHz <= 0 || bits <= 0) return 0.0;
    // kHz → Hz, bit → byte. DDR 이라 한 주기에 두 번 오간다.
    return (double)kHz * 1000.0 * ((double)bits / 8.0) * 2.0 / 1.0e9;
}

// 이 격자로 한 스텝을 도는 데 드는 시간(ms) 어림.
//
// **격자 쪽이 지배한다.** 푸아송을 푸는 동안 rho·pot·주파수 배열을 여러 번 오가는데,
// 그 양이 한 변의 세제곱으로 자라기 때문이다. 알갱이 쪽은 개수에 정비례할 뿐이다.
//
// 계수는 실측이 아니라 「옮기는 바이트 ÷ 대역폭」이다. FFT 는 R2C·C2R 왕복에 여러 패스를
// 돌므로 격자 한 칸당 대략 스무 번의 읽기·쓰기가 일어난다고 본다. 정확한 값이 목적이
// 아니라 **512³ 이 128³ 보다 여덟 배 무겁다**는 규모를 놓치지 않는 것이 목적이다.
double Sim::estimateStepMs(int particleCount, int gridSize, Boundary boundary) {
    const double bw = deviceBandwidthGBs();
    if (bw <= 0.0) return 0.0;
    const double eff = bw * 0.70 * 1.0e9;   // 실효 대역폭(초당 바이트)

    const double G = (double)(gridSize > 0 ? gridSize : 1);
    const double S = (boundary == Boundary::Isolated) ? G * 2.0 : G;
    const double cells = S * S * S;

    // **계수를 실측에 맞췄다(2026-08-17). 전 값은 3.4배 과소평가했고, 그 오차가
    // 알갱이 상한을 3000만으로 밀어 올려 여섯 번의 재부팅에 깔려 있었다.**
    //
    // 실측(RTX 3070 Ti · 608 GB/s · 격자 128 · 고립):
    //   알갱이 20만 → 7.12 ms,  100만 → 11.24 ms
    //   전수 테스트 100만 여덟 케이스 → 9.64 ~ 12.79 ms
    // 전 계수(격자 20왕복 · 알갱이 80바이트)는 100만을 **3.34 ms** 로 봤다.
    //
    // 빠져 있던 것이 셋이다. **대역폭만 세면 이 커널들의 실제 비용이 안 나온다:**
    //   · `atomicAdd` 경합 — 뭉친 칸에 수십만이 몰리면 같은 주소를 줄 세워 기다린다
    //     (2026-08-16 실측: 한 칸 최대 점유가 10만→92만이 되며 중력이 3.35→14.31 ms)
    //   · 커널이 열 몇 개 — 하나하나에 실행·동기화 오버헤드가 붙고 그것은 대역폭이 아니다
    //   · cuFFT 의 실제 왕복 — 20회로 잡았지만 전·후처리와 작업 버퍼가 더 든다
    //
    // 두 점(20만 7.12 · 100만 11.24)에서 직선을 뽑으면 알갱이당 5.15e-6 ms 이고,
    // 실효 대역폭으로 환산하면 **2200 바이트/알갱이**다(80 의 27배). 상수항 6.09 ms 는
    // **39 왕복**에 해당한다. 이 값으로 100만이 11.3 ms 로 나와 실측과 맞고, 상한은
    // 3000만에서 **약 500만**으로 내려온다.
    //
    // **선형 근사라 뭉친 뒤의 경합 폭증은 여전히 못 본다** — 그래서 위 워치독과
    // 프레임 예산이 함께 있어야 하고, 이 추정 하나에 안전을 걸지 않는다.
    const double gridBytes = 39.0 * cells * 4.0;                // 푸아송 왕복 + 부대 비용
    const double partBytes = (double)particleCount * 2200.0;    // 격자 훑기·경합까지 포함
    return (gridBytes + partBytes) / eff * 1000.0;
}

int Sim::maxParticlesFor(int gridSize, Boundary boundary, size_t freeBytes) {
    // 격자가 먼저 자리를 차지한다. 남는 것으로 알갱이를 잡는다.
    const size_t gridPart = estimateBytes(1, gridSize, boundary);
    if (freeBytes <= gridPart) return 0;
    const size_t perParticle = sizeof(float4) * 5 + sizeof(float) * 3 + sizeof(int) * 4;
    // 8할만 쓴다 — 드라이버와 화면 버퍼가 쓸 몫을 남긴다.
    const size_t usable = (size_t)((freeBytes - gridPart) * 0.8);
    const size_t n = usable / perParticle;
    return (n > 100000000ull) ? 100000000 : (int)n;
}

void Sim::init(const SimConfig& c) {
    impl_->cfg = c;
    reconfigure(c);
}

void Sim::reconfigure(const SimConfig& c) {
    Impl& d = *impl_;
    // 밖에서 무엇을 요청하든 여기서 자른다.
    //
    // 3D 는 격자가 세제곱으로 자란다. 2D 시절의 값이 그대로 들어오면 4096³ = 687억 칸을
    // 잡으려 들고, 고립 경계는 패딩까지 붙어 8192³ = 5500억 칸이 된다. 2026-08-14 에
    // 회귀 테스트가 G=4096 을 요청했다가 시스템 메모리가 통째로 치솟았다 —
    // **한계를 아는 쪽이 코어이므로 코어가 막아야 한다.**
    const int gCap = maxGridSize(c.boundary);
    int g = (c.gridSize > 0) ? c.gridSize : 64;
    if (g > gCap) g = gCap;
    if (g < 16) g = 16;
    // 2의 거듭제곱으로 내린다 — 주기 wrap 을 비트 마스크로 처리하므로 그래야 맞는다.
    { int p = 16; while (p * 2 <= g) p *= 2; g = p; }

    const bool structural = (c.particleCount != d.requestedN) ||
                            (g != d.requestedG) ||
                            (c.boundary != d.requestedBoundary);
    d.cfg = c;
    d.cfg.gridSize = g;
    if (!structural) return;

    d.requestedN = c.particleCount;
    d.requestedG = g;
    d.requestedBoundary = c.boundary;

    // 가용 VRAM 안에 들어가게 깎는다. 3D 는 격자가 크므로 이 판정이 2D 보다 자주 걸린다.
    int n = c.particleCount;
    const size_t freeB = deviceFreeBytes();
    if (freeB > 0) {
        const int cap = maxParticlesFor(g, c.boundary, freeB);
        // 격자만으로 이미 가용량을 넘으면 알갱이를 하나도 못 잡는다. 그때는 판을 열지 않는다 —
        // 그대로 할당을 시도하면 드라이버가 수십 GB 를 잡으려다 시스템을 끌어내린다.
        if (cap <= 0) {
            markFailure("이 격자는 이 카드에 들어가지 않습니다", __FILE__, __LINE__);
            return;
        }
        if (n > cap) n = cap;
    }
    d.allocN = (n > 0) ? n : 1;
    d.allocG = g;
    d.allocBoundary = c.boundary;

    // **재할당은 이 프로젝트에서 가장 위험한 동작이다.** 이것이 프레임마다 일어나 드라이버가
    // 무너진 적이 세 번 있다. 그래서 일어날 때마다 디스크까지 남긴다 — 로그에 이 줄이
    // 촘촘히 찍혀 있으면 그 자체가 원인이고, 한 번뿐이면 원인은 다른 데 있다.
    fx::mark("버퍼 다시 잡음: 알갱이 %d, 격자 %d(실제 %d), 경계 %s, 어림 %.0f MB, 여유 %.0f MB",
             d.allocN, g, d.stride(), d.periodic() ? "주기" : "고립",
             estimateBytes(d.allocN, g, c.boundary) / 1048576.0, freeB / 1048576.0);

    d.allocate();
    d.buildGreen();
    reset();
}

// 이 경계에서 격자 한 변이 가질 수 있는 최대값.
//
// 고립 경계는 합성곱이 감기지 않게 한 변을 두 배로 잡으므로 실제로는 512³ 을 쓴다.
// 그 하나가 537 MB 이고 퍼텐셜·주파수 배열까지 하면 1.6 GB 다.
int Sim::maxGridSize(Boundary b) { return (b == Boundary::Isolated) ? 256 : 512; }

void Sim::reset() {
    Impl& d = *impl_;
    if (g_failed) return;
    d.simTime = 0.0;
    d.stepCount = 0;
    d.bhCount = 0;
    for (int i = 0; i < kMaxBlackHoles; ++i) {
        d.bhs[i] = BlackHoleState{};
    }

    // 블랙홀은 알갱이를 놓기 **전에** 세운다. 나중에 세우면 초기 궤도 속도가
    // 블랙홀 없는 중력만 보고 정해져, 원반이 통째로 빨려 든다.
    // (마우스로 놓는 쪽은 그럴 수 없으므로 그때는 둘레에 궤도를 따로 준다 — addShape 참조.)
    // 장면이 아니라 설정으로 켠다(2026-08-19 에 블랙홀 장면을 지웠다).
    if (d.cfg.blackHoleEnabled) {
        // **질량을 먼저 정하고 지평선을 거기서 낸다.** 반대로 하면 안 된다.
        //
        // 지평선 크기(0.006)에서 질량을 역산하면 rs·c²/(2G) = 1.5 — 판의 모든 알갱이를
        // 합친 것의 1.5배다. 은하보다 무거우니 원반이 통째로 곧장 빨려 들었다
        // (2026-08-14 실측). 실제 은하의 중심 블랙홀은 은하 질량의 0.1% 안팎이다.
        //
        // 여기서는 2% 로 둔다. 0.1% 로 하면 물리적으로는 옳지만 원반이 블랙홀을 거의
        // 못 느껴 「블랙홀 장면」이라는 이름이 무색해진다. 2% 면 안쪽이 눈에 띄게 감기면서도
        // 원반은 살아남아, 회전하며 빨려 드는 모습이 보인다.
        //
        // **그 2% 를 `centralBHFraction` 으로 빼냈다(2026-08-18).** 여기 박혀 있어 밖에서
        // 만질 수 없었고, 「별에서 생긴 것보다 몇 배로 볼 것인가」를 시험할 방법이 없었다.
        // 기본값은 그대로 0.02 라 이 변경만으로는 어떤 장면도 달라지지 않는다.
        const int i = d.addBlackHole(0.5f, 0.5f, 0.5f,
                                     fmaxf(d.cfg.centralBHFraction, 0.f) * (float)d.allocN, false);
        // 그 질량의 지평선은 화면에서 점보다 작다. 삼킴 판정과 그리기에 쓸 최소 크기를 준다.
        d.setRsFrom(i);
    }
    CK(cudaMemset(d.eaten, 0, sizeof(int) * kMaxBlackHoles));
    CK(cudaMemset(d.bhAcc, 0, sizeof(float4) * kMaxBlackHoles));
    d.placeInitial();
    // 전자기력이 쓸 +/- 부호를 깐다. 켜져 있지 않아도 미리 깔아 두어야, 켜는 순간
    // 부호가 0 인 알갱이만 잔뜩 있는 판이 되지 않는다.
    if (d.temp)
        kInitCharge<<<(d.allocN + 255) / 256, 256>>>(d.temp, d.allocN,
                                                     (unsigned)((int)d.cfg.preset * 2917 + 7));
    d.giveOrbits();
    // 판 전체 회전은 궤도를 준 **뒤에** 얹는다. 먼저 얹으면 giveOrbits 가 속도를
    // 통째로 덮어써 사라진다.
    if (d.cfg.spin != 0.0f)
        kAddSpin<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, d.cfg.spin);
    // 팽창은 회전 **뒤에** 얹는다. 둘은 방향이 달라(지름 대 접선) 순서가 결과를 안 바꾸지만,
    // 회전을 먼저 두어야 「도는 판이 부푼다」는 읽는 순서와 맞는다.
    if (d.cfg.hubble != 0.0f)
        kAddHubble<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, d.cfg.hubble);
    // 속도 분산은 맨 마지막에 얹는다 — 회전·팽창 위에 무작위를 더하는 순서다.
    if (d.cfg.velDispersion > 0.0f)
        kAddDispersion<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN,
                                                        d.cfg.velDispersion, 24680u);

    // **무게중심을 정지시킨다.** 궤도 속도·회전·난수를 다 주고 나면 그 합이 정확히 0 이
    // 되지 않고, 그 나머지가 판 전체를 한 방향으로 민다. 2026-08-16 실측: 70초에 은하
    // 중심이 (0.5,0.5) → **(0.983, 0.859)** 로 판 모서리까지 갔다. 화면으로는 「퍼졌다」로
    // 보이지만 실제로는 뭉친 채 이사한 것이고, 판 중앙 기준으로 재는 값이 전부 어긋난다.
    if (!g_failed && d.allocN > 0) {
        // 네 칸이다 — `kMomentumAccum` 이 넷째에 개수를 센다(그 커널 주석).
        CK(cudaMemset(d.redD, 0, sizeof(double) * 4));
        kMomentumAccum<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, d.redD);
        double m[3] = {0.0, 0.0, 0.0};
        CK(cudaMemcpy(m, d.redD, sizeof(double) * 3, cudaMemcpyDeviceToHost));
        // 살아 있는 수로 나눈다. 삼킨 자리는 `kMomentumAccum` 이 이미 건너뛰었다.
        const int alive = (d.aliveShown > 0) ? d.aliveShown : d.active;
        if (alive > 0) {
            const float3 mean = make_float3((float)(m[0] / alive),
                                            (float)(m[1] / alive),
                                            (float)(m[2] / alive));
            kSubtractMeanVel<<<(d.allocN + 255) / 256, 256>>>(d.vel, d.pos, d.allocN, mean);
            CK(cudaGetLastError());
            fx::mark("무게중심 정지: 평균 속도 (%.5f, %.5f, %.5f) 를 뺐다", mean.x, mean.y, mean.z);
        }
    }

    d.computeAccel();
}

void Sim::step() {
    Impl& d = *impl_;
    if (g_failed || d.allocN <= 0) return;

    CK(cudaEventRecord(d.evA));

    // 성능을 위해 가끔 알갱이를 칸 순서로 재배치한다. 정확성과는 무관하다.
    if (d.cfg.sortInterval > 0 && (d.stepCount % d.cfg.sortInterval) == 0 && !d.cfg.contactEnabled)
        d.sortParticles();

    d.computeAccel();
    d.doContact();
    CK(cudaEventRecord(d.ev1));      // 여기까지가 중력(+압력 적용)

    // CFL — 한 스텝에 한 칸을 넘게 가면 격자가 그 움직임을 못 따라가 알갱이가 튄다.
    CK(cudaMemset(d.redF, 0, sizeof(float)));
    kMaxSpeed<<<(d.allocN + 255) / 256, 256>>>(d.vel, d.pos, d.allocN, d.redF);
    float vmax = 0.f;
    CK(cudaMemcpy(&vmax, d.redF, sizeof(float), cudaMemcpyDeviceToHost));
    const float cell = 1.0f / (float)d.allocG;
    // **배속을 1 위로는 `dt` 에 안 싣는다(2026-08-17에 고친 이중 적용).**
    //
    // `App::tick` 이 이미 배속만큼 **스텝을 여러 번** 돌린다(`reps`). 그런데 여기서 `dt`
    // 에도 곱하고 있어서 **둘이 곱해졌다** — 배속 2.8 이면 `dt` 2.8배 × 스텝 3번 =
    // **8.4배**로 흘렀다.
    //
    // 더 나쁜 것은 `dt` 를 늘린 쪽이다. `App::tick` 의 주석이 「시간 간격을 늘려서는 못
    // 낸다(CFL 안정성 한계)」고 적어 두었는데 그 금지가 여기서 깨지고 있었다. 실측에서
    // 최고 속도가 **광속의 82%** 까지 갔고, 우주가 「굉장히 역동적으로」 보인다는 지적이
    // 거기서 나왔다.
    //
    // 1 아래로는 그대로 곱한다 — 느리게 볼 때는 스텝 수를 못 줄이므로 `dt` 로 낮춘다.
    float dt = 0.0016f * fminf(d.cfg.timeScale, 1.0f);
    const float dtMax = (vmax > 1e-6f) ? (0.8f * cell / vmax) : dt;
    if (dt > dtMax) dt = dtMax;

    // **CFL 은 속도만 본다. 힘이 정하는 시간 폭은 따로 지켜야 한다.**
    //
    // 용수철 상수 k 인 힘을 명시적으로 적분하려면 dt < 2/√k 여야 한다. 접촉의 강성은
    // 1e6 이라 그 한계가 0.002 인데 기본 dt 가 0.0016 이었다 — 여유가 거의 없었고,
    // 식히기로 뭉쳐 겹침이 깊어지자 한 스텝에 속도가 11 씩 뛰었다(f = 1e6·0.007 = 7000,
    // ×dt = 11.2). 어떤 감쇠로도 막을 수 없는 자리다 — 감쇠를 5700배로 올렸더니
    // 오히려 나빠졌다(9.97 → 12.20, 2026-08-15 실측).
    //
    // 한계의 4분의 1 로 잡아 여유를 둔다. 접촉을 켜면 그만큼 시간이 느리게 흐르지만,
    // 그것이 이 힘을 쓰는 값이다.
    if (d.cfg.contactEnabled) {
        const float dtStiff = 0.5f / sqrtf(fmaxf(d.cfg.contactStiffness, 1.0f));
        if (dt > dtStiff) dt = dtStiff;
    }
    // **바닥을 두지 않는다.**
    //
    // 「블랙홀을 놓으면 시간이 멎는다」를 고치려고 여기에 dt 하한을 넣은 적이 있다.
    // 그것은 CFL 을 무력화하는 짓이었다 — CFL 은 「한 스텝에 격자 한 칸을 넘지 마라」는
    // 물리적 안전장치이고, 넘는 순간 알갱이가 격자를 건너뛰어 힘이 엉뚱해지고 더 튄다.
    // 블랙홀이 둘이면 가속도가 배가 되어 그 선을 훨씬 쉽게 넘는다.
    // 2026-08-14 실측: 블랙홀 두 개를 놓자 화면이 멎고 시스템이 재부팅됐다.
    //
    // 시간이 안 흐르는 문제는 dt 를 억지로 키워 푸는 것이 아니라, **빠른 알갱이를 없애서**
    // 푼다 — 지평선 안으로 들어온 것은 삼켜 지운다(아래 bhEatRs). 그러면 vmax 가 내려가고
    // dt 가 저절로 회복된다.
    d.tm.dtUsed = dt; d.tm.maxSpeed = vmax;

    // 식히는 것은 힘을 더하기 전에 한다 — 이번 스텝의 dt 로 이웃과의 무작위 운동을 걷어낸다.
    // 속도를 줄이는 쪽이라 방금 CFL 이 정한 dt 를 위태롭게 하지 않는다.
    d.doCooling(dt);

    // **무게중심을 세운다 — 매 스텝.**
    //
    // reset 에서 한 번 빼는 것으로는 못 잡는다. 알짜 운동량을 만드는 것은 초기 배치가
    // 아니라 매 스텝 도는 냉각이고(`kCool` 끝 주석), 그래서 은하가 통째로 흘러 판
    // 모서리에 눌러붙었다 — 2026-08-16 실측에서 100초에 무게중심이 (0.98, 0.92) 였고,
    // 그 상태로는 반지름으로 재는 값(금속 기울기·성단·나선팔)이 전부 어긋난다.
    //
    // **조건을 안 건다.** 냉각이 가장 큰 원천이지만 접촉·경계 되튕김·광속 절단도 전부
    // 비탄성이라 알짜 운동량을 만들 수 있고, 어느 쪽이든 판 전체의 등속 운동은 물리적으로
    // 뜻이 없다(갈릴레이 불변).
    //
    // 평균을 호스트로 가져오지 않는다 — `cudaMemcpy` 는 GPU 를 멈추고, 스텝마다 멈추면
    // 위에서 아낀 시간이 다 사라진다. `kMomentumAccum` 이 넷째 칸에 개수까지 세어 두고
    // 나눗셈은 커널 안에서 한다. **그래서 여기 memset 은 세 칸이 아니라 네 칸이다.**
    // **이 자리에서는 안 지운다 — 폭발 킥이 아직 안 일어났다.**
    //
    // 스텝 순서가 `냉각 → 여기 → 적분 → kStarAge(폭발 킥)` 이라, 여기서 무게중심을 세우면
    // **그 뒤에 터진 폭발이 만든 알짜 운동량이 그 스텝에 안 지워지고 다음으로 넘어간다.**
    // 폭발이 드물던 시절에는 티가 안 났는데(round-24 에서 운동량 89), 별 형성 효율을
    // 고쳐 폭발이 계속 일어나게 되자 **6,399 까지 쌓였다**(2026-08-17 실측: 화면이
    // 0.4초마다 74% 바뀌었고 사용자가 「굉장히 역동적」이라고 알렸다).
    //
    // 그래서 이 블록을 `kStarAge` **뒤로** 옮겼다. 아래에서 찾을 것.

    CK(cudaEventRecord(d.ev2));      // 여기까지가 냉각·분산 갱신·별 판정

    // **삼키는 반경은 그리는 반경보다 훨씬 작다.** (아래 값은 packBH 가 만든다.)
    //
    // rs 는 화면에서 보이게 하려고 실제 지평선보다 크게 부풀린 값이다. 그 부풀린 반경을
    // 삼킴 판정에 그대로 쓰면, 실제로는 지평선 밖에 있어야 할 알갱이까지 먹는다. 그러면
    // 질량이 늘고 → 중력이 세지고 → 원반이 더 빨려들어, 몇 초 만에 판을 통째로 먹는다
    // (2026-08-14 실측: 4초에 45%, 14초에 전부).
    //
    // 실제 비율(136분의 1)로 두면 아무것도 안 먹으므로, 눈에 띄되 폭주하지 않는 선으로
    // 그리는 반경의 절반을 쓴다.
    //
    // 이 반경은 안전장치이기도 하다. 지평선 가까이 온 알갱이는 가속도가 폭발해 CFL 이
    // dt 를 극단으로 깎는데, 삼켜서 없애면 그 원인이 사라진다. 15% 로 너무 조여 두었더니
    // 빠른 알갱이가 지평선 밖에 남아 시간이 흐르지 않았다.
    //
    // **그리고 격자 한 칸보다 작아서는 안 된다 — 이 앱에서 시스템이 죽은 원인이다.**
    //
    // 삼킴 반경이 한 칸보다 작으면 지평선 바로 바깥 한 칸이 삼켜지지 않는 자리가 된다.
    // 블랙홀은 계속 끌어당기므로 그 칸에 알갱이가 끝없이 쌓이는데, 질량을 격자에 더하는
    // 일(kScatter)은 칸마다 원자 연산이라 **같은 주소에 몰린 수만큼 차례를 기다린다.**
    // 수백만 개가 한 칸에 겹치면 그 커널 하나가 드라이버 타임아웃(2초)을 넘기고,
    // 강제 리셋 과정에서 커널 자료구조가 깨져 시스템이 재부팅된다
    // (2026-08-14 실측: 100만 질량 블랙홀의 삼킴 반경 0.0066 < 128³ 한 칸 0.0078).
    //
    // 한 칸을 바닥으로 두면 그 자리에 쌓이기 전에 삼켜져 사라진다. 물리적으로도 옳다 —
    // 격자 한 칸보다 작은 것은 이 시뮬레이션이 아예 구분하지 못하는 크기다.
    const BHPack bhPack = d.packBH();

    kIntegrate<<<(d.allocN + 255) / 256, 256>>>(
        d.accG, d.pos, d.vel, d.allocN, d.allocG, dt, d.periodic() ? 1 : 0,
        bhPack, lightSpeedSqFor(d.cfg.lengthScale, d.cfg.timeUnitScale), d.eaten, d.eatenP,
        // 세 힘 중 하나라도 켜져 있으면 그 가속도를 함께 넘긴다.
        (d.cfg.contactEnabled || d.cfg.strongForceEnabled || d.cfg.emForceEnabled)
            ? d.accContact : nullptr,
        // 압력 가속도 — 적분이 **가스에만** 더한다. 별은 서로 부딪히지 않는다.
        d.accPress,
        // 구형 경계(0 이면 예전 큐브 벽). 주기 경계에서는 애초에 안 쓴다.
        d.periodic() ? 0.f : fmaxf(d.cfg.softBoundR, 0.f),
        d.cfg.darkEnergy);
    CK(cudaGetLastError());

    if (d.bhCount > 0) {
        // 블랙홀이 놓인 자리의 격자 가속도를 뽑아 둔다 — 둘레 물질이 블랙홀을 끄는 힘이다.
        // 블랙홀 수만큼만 도는 커널이라 값이 거의 안 든다.
        kSampleAccAtBH<<<1, kMaxBlackHoles>>>(d.accG, d.rho, d.allocG, d.stride(),
                                              d.periodic() ? 1 : 0, bhPack, d.bhAcc);
        CK(cudaGetLastError());

        // 삼킨 만큼 무거워지고 지평선이 자란다.
        int e[kMaxBlackHoles] = {0};
        CK(cudaMemcpy(e, d.eaten, sizeof(int) * d.bhCount, cudaMemcpyDeviceToHost));
        // 삼킨 물질의 속도 합. 이제 지평선 안은 예외 없이 삼키므로 **센 수가 곧 삼킨 수**다
        // (에딩턴 몫으로 되돌려보내는 갈래가 없어져 여기서 다시 자를 것도 없다).
        float ep[3 * kMaxBlackHoles] = {0.f};
        CK(cudaMemcpy(ep, d.eatenP, sizeof(float) * 3 * d.bhCount, cudaMemcpyDeviceToHost));
        bool any = false;
        for (int i = 0; i < d.bhCount; ++i) {
            if (e[i] <= 0) continue;
            // **운동량을 받는다 — 질량만 늘리면 보존이 깨지고 감속 기제가 없어진다.**
            //
            // `v_new = (M·v_bh + Σm·v_p) / (M + Σm)` 이고 알갱이 하나의 질량이 1 이라
            // `Σm = e[i]` 다. **질량을 더하기 전에 계산해야** `M` 이 삼키기 전 값이다.
            //
            // 이것이 동역학적 마찰이다 — 블랙홀이 둘레 물질보다 빠르면 느린 물질을 삼켜
            // 느려지고, 느리면 빨라진다. 그래서 실제 블랙홀은 은하 중심에 가라앉아 거의
            // 안 움직인다. 전에는 이 항이 없어 중력으로만 계속 가속됐다.
            {
                const float M   = d.bhs[i].mass;
                const float m   = (float)e[i];
                const float inv = 1.0f / fmaxf(M + m, 1e-6f);
                d.bhs[i].vx = (M * d.bhs[i].vx + ep[i * 3 + 0]) * inv;
                d.bhs[i].vy = (M * d.bhs[i].vy + ep[i * 3 + 1]) * inv;
                d.bhs[i].vz = (M * d.bhs[i].vz + ep[i * 3 + 2]) * inv;
            }
            d.bhs[i].mass += (float)e[i];
            // 자라는 규칙은 setRsFrom 이 쥔다(세제곱근 — 그 자리의 주석 참조).
            d.setRsFrom(i);
            any = true;
        }
        // 다음 스텝을 위해 비운다. **여기서 비워 두어야** 아래에서 블랙홀이 합쳐지며
        // 배열이 당겨져도 남은 수가 엉뚱한 블랙홀의 것으로 섞이지 않는다.
        if (any) {
            CK(cudaMemset(d.eaten, 0, sizeof(int) * kMaxBlackHoles));
            // 운동량 합도 함께 비운다 — 안 비우면 다음 스텝에 지난 몫이 한 번 더 섞인다.
            CK(cudaMemset(d.eatenP, 0, sizeof(float) * 3 * kMaxBlackHoles));
        }

        // 삼킨 것이 있으면 살아 있는 수를 다시 센다. 열다섯 스텝에 한 번만 하는데,
        // 세려면 결과를 호스트로 가져와야 하고 그 복사가 GPU 를 세우기 때문이다.
        // (화면에 뜨는 수라 0.25초 늦어도 눈에 띄지 않는다.)
        if (any && (d.stepCount % 15) == 0) d.countAlive();

        // 블랙홀도 중력을 받아 움직이고, 겹치면 합쳐진다.
        d.advanceBlackHoles(dt);
    }
    d.checkCollapse();

    // 별이 늙고 터지고 가스로 돌아온다. **매 스텝 돈다** — 나이가 dt 만큼 정확히 늘어야
    // 수명이 시간 배율 위에서 뜻을 갖는다. `doCooling`(2스텝마다) 안에 두면 나이가
    // 두 배로 빨리 가거나 절반만 가서 수명 계산이 통째로 어긋난다.
    //
    // 별 형성과 짝이라 같은 스위치로 켜고 끈다 — 형성만 있고 죽음이 없으면 별이 쌓이기만
    // 하고(실측: 60초에 99.9%), 죽음만 있고 형성이 없으면 아무 일도 안 일어난다.
    if (!g_failed && d.cfg.starFormationEnabled && d.allocN > 0) {
        kStarAge<<<(d.allocN + 255) / 256, 256>>>(
            d.pos, d.vel, d.allocN, dt,
            fmaxf(d.cfg.starSunMass, 1.0f), fmaxf(d.cfg.starSunLifeSim, 1e-3f),
            fmaxf(d.cfg.starExplodeSim, 1e-4f), d.cfg.starKickSpeed,
            (unsigned)(d.stepCount * 2654435761u + 7919u),
            d.ashGrid, d.allocG, d.periodic() ? 1 : 0, d.cfg.starAshYield,
            // 블랙홀 전환이 꺼져 있으면 후보 버퍼를 안 넘긴다 — 커널이 `bhCand` 가 null 인
            // 것을 보고 그 갈래를 건너뛰어, 무거운 별도 그냥 터지고 가스로 돌아온다.
            d.cfg.starCollapseToBH ? d.bhCand : nullptr,
            d.cfg.starCollapseToBH ? d.bhCandV : nullptr,
            d.cfg.starCollapseToBH ? d.bhCandN : nullptr,
            d.bhBlockedCount, kMaxBlackHoles,
            fmaxf(d.cfg.starBHRatio, 1.0f), d.cfg.starWindRate);
        CK(cudaGetLastError());

        // 커널이 남긴 블랙홀 후보를 호스트가 실제로 만든다.
        // (무게중심 정지는 이 블록이 끝난 뒤에 한다 — 아래 참조)
        //
        // **후보 수를 먼저 읽고 0 이면 아무것도 안 한다** — 매 스텝 float4 8개를 복사하면
        // 그 복사가 GPU 를 세운다. 별이 블랙홀이 되는 것은 드문 일이라 대부분 여기서 끝난다.
        int nCand = 0;
        CK(cudaMemcpy(&nCand, d.bhCandN, sizeof(int), cudaMemcpyDeviceToHost));
        if (nCand > 0) {
            float4 cand[kMaxBlackHoles];
            float4 candV[kMaxBlackHoles] = {};
            const int take = (nCand < kMaxBlackHoles) ? nCand : kMaxBlackHoles;
            CK(cudaMemcpy(cand, d.bhCand, sizeof(float4) * take, cudaMemcpyDeviceToHost));
            // 물려줄 속도도 함께 가져온다 — 이것이 없으면 블랙홀이 그 자리에 멎어
            // 각운동량을 잃고 판 밖으로 나간다(`kStarAge` 의 후보 기록 참조).
            CK(cudaMemcpy(candV, d.bhCandV, sizeof(float4) * take, cudaMemcpyDeviceToHost));
            for (int c = 0; c < take; ++c) {
                // **자리가 있을 때만 만든다.** `addBlackHole` 은 자리가 차면 가장 가벼운 것을
                // 밀어내는데, 그건 사용자가 마우스로 놓을 때의 규칙이다. 저절로 생기는 쪽이
                // 남의 자리를 빼앗으면 삼킨 질량이 사라진다.
                if (d.bhCount < kMaxBlackHoles) {
                    d.addBlackHole(cand[c].x, cand[c].y, cand[c].z, cand[c].w, true,
                                   candV[c].x, candV[c].y, candV[c].z);
                } else {
                    ++d.bhBlockedHost;
                }
            }
            CK(cudaMemset(d.bhCandN, 0, sizeof(int)));
            fx::mark("별이 무너져 블랙홀 %d 개 — 자리 %d/%d, 밀려난 후보 누적 %d",
                     take, d.bhCount, kMaxBlackHoles, d.bhBlockedHost);
        }
    }

    // **무게중심을 세운다 — 폭발 킥까지 다 끝난 뒤다.**
    //
    // 판 전체가 한 방향으로 흐르면 은하가 판 밖으로 나가고, 그 상태로는 반지름으로 재는
    // 값(금속 기울기·성단·나선팔·회전곡선)이 전부 어긋난다. 판 전체의 등속 운동은
    // 물리적으로 아무 뜻이 없다(갈릴레이 불변).
    //
    // **자리가 중요하다.** 전에는 냉각 바로 뒤(적분·`kStarAge` 앞)에 있었는데, 그러면
    // **그 뒤에 터진 폭발이 만든 알짜 운동량이 그 스텝에 안 지워진다.** 폭발이 드물던
    // 시절에는 티가 안 났지만(round-24 에서 운동량 89) 별 형성 효율을 고쳐 폭발이 계속
    // 일어나자 **6,399 까지 쌓였다.** 조건을 안 건다 — 냉각·접촉·경계 되튕김·광속 절단·
    // 폭발 킥이 전부 알짜 운동량을 만들 수 있다.
    //
    // 평균을 호스트로 안 가져온다 — `cudaMemcpy` 는 GPU 를 멈추고, 스텝마다 멈추면 위에서
    // 아낀 시간이 다 사라진다. `kMomentumAccum` 이 넷째 칸에 개수까지 세고 나눗셈은 커널
    // 안에서 한다. **그래서 memset 이 세 칸이 아니라 네 칸이다.**
    if (d.allocN > 0) {
        CK(cudaMemset(d.redD, 0, sizeof(double) * 4));
        kMomentumAccum<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, d.redD);
        kSubtractMeanVelDev<<<(d.allocN + 255) / 256, 256>>>(d.vel, d.pos, d.allocN, d.redD);
        CK(cudaGetLastError());
    }

    d.simTime += dt;
    ++d.stepCount;

    CK(cudaEventRecord(d.evB));
    CK(cudaEventSynchronize(d.evB));
    float ms = 0.f;
    CK(cudaEventElapsedTime(&ms, d.evA, d.evB));

    // 구간별 시간. **evB 를 이미 기다렸으므로 앞의 이벤트들은 전부 끝나 있다** —
    // 여기서 추가로 세우는 것이 없다. 어느 커널이 프레임을 먹는지 이 셋으로 갈린다.
    {
        float a = 0.f, b = 0.f, c = 0.f;
        cudaEventElapsedTime(&a, d.evA, d.ev1);   // 중력(정렬·뿌리기·푸아송·격자가속도·압력)
        cudaEventElapsedTime(&b, d.ev1, d.ev2);   // 냉각·분산 갱신·별 판정
        cudaEventElapsedTime(&c, d.ev2, d.evB);   // 적분·블랙홀·별 나이
        // 기존 이름을 그대로 쓴다 — 밖(HUD·status·MCP)이 이미 이 이름으로 읽고 있고,
        // 이름을 바꾸면 그쪽을 다 고쳐야 한다. 뜻만 주석으로 못 박는다.
        d.tm.scatterMs = a;      // = 중력 구간
        d.tm.poissonMs = b;      // = 냉각·압력·별 구간
        d.tm.gatherMs  = c;      // = 적분·블랙홀 구간
    }
    d.tm.totalMs = ms;
}

const SimConfig& Sim::config() const { return impl_->cfg; }
SimTimings Sim::timings() const { return impl_->tm; }
double Sim::simTime() const { return impl_->simTime; }
bool Sim::failed() { return g_failed; }
std::string Sim::failMessage() { return g_failMsg; }
int Sim::gridSize() const { return impl_->allocG; }
int Sim::particleCount() const { return impl_->allocN; }

// 한 칸에 알갱이가 얼마나 몰렸는지 — **워치독이 매번 볼 수 있게 따로 낸다.**
//
// **왜 `measureConservation` 으로 부족한가.** 거기에도 같은 값이 들어 있지만 그 함수는
// 상태 다섯 가지와 총 운동량까지 함께 세어 알갱이 수만큼 도는 커널이 둘 붙는다. 매 프레임
// 부를 물건이 아니다. 여기 있는 것은 **격자 칸 수만큼만** 도는 커널 하나뿐이고 알갱이가
// 몇이든 같은 시간에 끝난다.
//
// **이 값이 워치독에 필요한 이유는 그것이 선행 지표라서다.** 스텝 시간을 보는 감시는
// 스텝이 끝나야 잴 수 있어, 한 스텝이 갑자기 드라이버 타임아웃(2초)을 넘기면 재 볼
// 기회 자체가 없다. 한 칸에 몰리는 것은 그 폭주가 **일어나기 전에** 커지므로 먼저 보인다.
//
// 정렬이 안 돌았으면(`cellStart` 가 없거나 냉각·접촉이 꺼져 있으면) −1 을 돌려준다 —
// 0 을 돌려주면 「안전하다」로 잘못 읽힌다.
// 판 벽에 붙어 있는 알갱이 수. 격자 한 칸을 「붙었다」의 폭으로 쓴다.
int Sim::wallCount() const {
    Impl& d = *impl_;
    if (g_failed || d.allocN <= 0 || d.allocG <= 0) return -1;
    const float margin = 1.0f / (float)d.allocG;
    CK(cudaMemset(d.redI, 0, sizeof(int)));
    kCountAtWall<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.allocN, margin, d.redI);
    int h = 0;
    CK(cudaMemcpy(&h, d.redI, sizeof(int), cudaMemcpyDeviceToHost));
    return h;
}

int Sim::peakCellCount() const {
    Impl& d = *impl_;
    if (g_failed || !d.cellStart || !d.cellEnd || d.allocG <= 0) return -1;
    const int cells = d.allocG * d.allocG * d.allocG;
    CK(cudaMemset(d.redI, 0, sizeof(int)));
    kMaxCellCount<<<(cells + 255) / 256, 256>>>(d.cellStart, d.cellEnd, cells, d.redI);
    int h = 0;
    CK(cudaMemcpy(&h, d.redI, sizeof(int), cudaMemcpyDeviceToHost));
    return h;
}
int Sim::activeCount() const {
    // 삼킨 뒤에는 센 값을 보여 준다. active 는 자리 관리용이라 삼킨 만큼 줄지 않아,
    // 그대로 두면 블랙홀이 판을 다 먹어도 화면에는 「399만 / 399만」이 뜬다.
    const Impl& d = *impl_;
    if (d.aliveShown >= 0 && d.aliveShown <= d.active) return d.aliveShown;
    return d.active;
}
int Sim::starCount() const {
    Impl& d = *impl_;
    if (g_failed || d.allocN <= 0) return 0;
    // 세는 커널을 여기서만 돌린다 — 매 스텝 세면 그 자체가 비용이고, 이 값은
    // 화면·상태 표시에만 쓰여 그때그때 재면 충분하다.
    CK(cudaMemset(d.redI, 0, sizeof(int)));
    CK(cudaMemset(d.redD, 0, sizeof(double)));
    kCountStars<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.allocN, d.redI, d.redD);
    int h = 0;
    CK(cudaMemcpy(&h, d.redI, sizeof(int), cudaMemcpyDeviceToHost));
    return h;
}

// 별 하나의 평균 질량(= 그 별을 이룬 알갱이 수). **시간에 따라 이 값이 내려가면
// 재 사슬이 도는 것이다** — 재가 쌓여 잘 식고, 식으면 Jeans 문턱이 낮아져 더 작은 덩어리도
// 별이 되기 때문이다. 1세대가 거대했던 이유가 그 반대(재가 없어 못 식음)다.
double Sim::meanStarMass() const {
    Impl& d = *impl_;
    if (g_failed || d.allocN <= 0) return 0.0;
    CK(cudaMemset(d.redI, 0, sizeof(int)));
    CK(cudaMemset(d.redD, 0, sizeof(double)));
    kCountStars<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.allocN, d.redI, d.redD);
    int    cnt = 0;
    double sum = 0.0;
    CK(cudaMemcpy(&cnt, d.redI, sizeof(int), cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(&sum, d.redD, sizeof(double), cudaMemcpyDeviceToHost));
    return (cnt > 0) ? sum / (double)cnt : 0.0;
}

// 보존량을 한 번에 잰다. **이 판이 물리가 아니라 회계에서 틀리지 않았는지 보는 창이다.**
//
// 매 프레임 부르지 않는다 — 결과를 호스트로 가져오는 복사가 GPU 를 세우기 때문이고,
// 이 값들은 바퀴마다 한 번 확인하면 충분하다.
Sim::Conservation Sim::measureConservation() const {
    Impl& d = *impl_;
    Conservation c{};
    if (g_failed || d.allocN <= 0) return c;

    // 상태별 개수 + 못 쓸 값
    CK(cudaMemset(d.redI, 0, sizeof(int) * 8));
    kCountStates<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, d.redI);
    int h[7] = {0, 0, 0, 0, 0, 0, 0};
    CK(cudaMemcpy(h, d.redI, sizeof(int) * 7, cudaMemcpyDeviceToHost));
    c.gas = h[0]; c.stars = h[1]; c.exploding = h[2]; c.remnants = h[3]; c.bad = h[4];
    c.neutronStars = h[5]; c.darkMatter = h[6];

    // 총 운동량. 네 칸을 비운다 — `kMomentumAccum` 이 넷째에 개수를 센다(그 커널 주석).
    // 여기서는 개수를 안 읽지만, 안 비우면 지난 스텝 값이 남아 다음에 읽는 쪽이 오염된다.
    CK(cudaMemset(d.redD, 0, sizeof(double) * 4));
    kMomentumAccum<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, d.redD);
    double m[3] = {0.0, 0.0, 0.0};
    CK(cudaMemcpy(m, d.redD, sizeof(double) * 3, cudaMemcpyDeviceToHost));
    c.momentum = sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]);

    // 셀별 최대 점유수 — 정렬이 돌아 있을 때만 뜻이 있다(냉각·접촉이 켜져 있으면 돈다).
    if (d.cellStart && d.cellEnd) {
        const int cells = d.allocG * d.allocG * d.allocG;
        CK(cudaMemset(d.redI + 5, 0, sizeof(int)));
        kMaxCellCount<<<(cells + 255) / 256, 256>>>(d.cellStart, d.cellEnd, cells, d.redI + 5);
        CK(cudaMemcpy(&c.maxCellCount, d.redI + 5, sizeof(int), cudaMemcpyDeviceToHost));
    }
    return c;
}

// 링별 (re, im, sum) 묶음에서 나선 진폭·막대 진폭·감김 각도·패턴 각도를 낸다.
// 질량 쪽과 빛 쪽에 **같은 자를 두 번 대려고** 함수로 뺐다 — 둘을 견주는 것이
// 목적이라 재는 방법이 조금이라도 다르면 그 차이가 결론이 되어 버린다.
namespace {
struct RingFit {
    double amp   = 0.0;   // 링별 평균 = 나선
    double bar   = 0.0;   // 링을 다 더한 뒤 = 막대
    double pitch = 0.0;   // 감김 각도(도). 90 은 안 감긴 것 = 막대
    double phase = 0.0;   // 패턴이 놓인 각도(도, r=0.3 기준)
    int    rings = 0;     // 평균에 쓴 링 수
    // 원반(r 0.1~0.5) 전체 합. 질량 쪽이면 알갱이 수, 빛 쪽이면 **총 광도**다.
    // 진폭을 정규화하느라 어차피 구하던 값인데, 밖에서 보면 그 자체로 쓸모가 있다 —
    // 「별 형성 효율을 낮추면 나선은 좋아지지만 화면이 어두워진다」는 맞바꿈을
    // 눈이 아니라 수로 견주려면 이 값이 있어야 한다(2026-08-19).
    double sum   = 0.0;
};

RingFit fitSpiralRings(const double* h, int bins) {
    constexpr double kPi = 3.14159265358979323846;
    RingFit f;

    double gRe = 0.0, gIm = 0.0, gSum = 0.0;
    for (int b = 0; b < bins; ++b) {
        gRe += h[3 * b + 0]; gIm += h[3 * b + 1]; gSum += h[3 * b + 2];
    }
    f.sum = gSum;
    if (gSum <= 1e-9) return f;
    f.bar = sqrt(gRe * gRe + gIm * gIm) / gSum;

    // 거의 빈 링은 뺀다 — 밀도가 몇 칸에만 남으면 그 몇 칸의 각도가 곧 A2 가 되어
    // 1 에 가깝게 튄다. 그것은 팔이 아니라 표본이 없는 것이다.
    // 문턱은 「평균 링의 5%」— 가스가 다 타서 바깥이 비어도 별이 남은 링은 살아남는다.
    const double floorSum = gSum / (double)bins * 0.05;

    // **밀도로 가중하지 않고 링을 고르게 센다.** 묻는 것이 「팔이 원반 전체에 걸쳐
    // 있는가」라서다. 밀도로 가중하면 제일 무거운 안쪽 한두 링(팽대부·막대가 있는
    // 자리)이 값을 지배해 `bar` 와 거의 같아지고, 그러면 둘을 나눈 뜻이 없어진다.
    //
    // 그 대가로 **`amp` 가 `bar` 보다 작아질 수 있다.** 삼각부등식 |Σ Z_b| ≤ Σ |Z_b|
    // 이 보장하는 것은 `bar` ≤ **가중**평균까지이고, 고른 평균은 그 아래로 내려갈 수
    // 있다 — 안쪽 링만 팔이 세고 바깥이 밋밋하면 그렇다. 버그가 아니다(2026-08-19).
    double acc = 0.0;
    int used = 0;
    double lnr[kSpiralBins] = {}, unw[kSpiralBins] = {};
    double prevPh = 0.0;
    for (int b = 0; b < bins; ++b) {
        const double s = h[3 * b + 2];
        if (s <= floorSum || s <= 1e-9) continue;
        const double re = h[3 * b + 0], im = h[3 * b + 1];
        acc += sqrt(re * re + im * im) / s;

        // 위상을 잇는다(unwrap). atan2 는 −π~π 로 접혀 나오므로 이웃 링과의 차를
        // (−π, π] 로 되접어 누적해야 「계속 감기는 각도」가 된다.
        // **링당 위상차가 π 를 넘으면 못 푼다** — pitch 3° 아래가 그렇다(실측:
        // 5° 는 링당 132°로 안전, 3° 는 220°로 불가). 실제 나선은하는 6~40° 다.
        const double ph = atan2(im, re);
        if (used == 0) {
            unw[0] = ph;
        } else {
            double dd = ph - prevPh;
            while (dd >  kPi) dd -= 2.0 * kPi;
            while (dd < -kPi) dd += 2.0 * kPi;
            unw[used] = unw[used - 1] + dd;
        }
        prevPh = ph;
        lnr[used] = log(0.1 + ((double)b + 0.5) / (double)bins * 0.4);
        ++used;
    }
    if (used > 0) f.amp = acc / (double)used;
    f.rings = used;

    // ── 팔이 감긴 각도(pitch angle) ────────────────────────────────────
    //
    // 로그 나선은 θ(r) = θ₀ + ln(r)/tan(i) 이고 m=2 위상은 그 두 배다:
    //
    //   dφ/d(ln r) = 2/tan(i)   →   i = atan( 2 / |dφ/d ln r| )
    //
    // 기울기가 0 이면 반지름이 달라도 각도가 같다는 뜻 — 그것이 **막대**(90°)다.
    // 실제 나선은하는 6~40°(Sa 6°, Sc 20~30°).
    //
    // 합성 데이터로 알고리즘을 먼저 검증했다(2026-08-19): 넣은 값 7~40° 와 막대를
    // 전부 오차 0.1° 안에서 되찾았다. **팔이 없으면 이 값은 뜻이 없다** —
    // 위상이 잡음이면 기울기도 잡음이다. 진폭과 반드시 함께 읽는다.
    if (used >= 4) {
        double sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
        for (int k = 0; k < used; ++k) {
            sx += lnr[k]; sy += unw[k];
            sxx += lnr[k] * lnr[k]; sxy += lnr[k] * unw[k];
        }
        const double den = (double)used * sxx - sx * sx;
        if (fabs(den) > 1e-12) {
            const double slope = ((double)used * sxy - sx * sy) / den;
            f.pitch = (fabs(slope) < 1e-6) ? 90.0
                                           : atan(2.0 / fabs(slope)) * 180.0 / kPi;

            // 패턴이 지금 어느 각도에 있는가 — 회귀 직선을 r=0.3(원반 대표 반지름)
            // 에 넣어 읽는다. **이 값이 시간에 따라 고르게 도는지가 「팔이 유지되는가」다.**
            // 진폭이 커도 매 순간 다른 각도에 뭉치면 그것은 팔이 아니라 잡음이다.
            // m=2 라 팔은 π 주기이므로 절반을 취해 −90~90° 로 접는다.
            const double icept = (sy - slope * sx) / (double)used;
            double ang = (icept + slope * log(0.3)) * 0.5 * 180.0 / kPi;
            while (ang >   90.0) ang -= 180.0;
            while (ang <= -90.0) ang += 180.0;
            f.phase = ang;
        }
    }
    return f;
}
}  // namespace

// 창발이 실제로 일어났는지 재는 값들. **이 판의 목적을 판정하는 자리다.**
//
// 셋 다 「그렇게 되라」고 코드에 적지 않은 것들이다 — 나오면 규칙들이 스스로 만든 것이고,
// 안 나오면 그것도 결과다(원칙 2: 안 나오면 빠진 현실을 찾는다).
Sim::Emergence Sim::measureEmergence() const {
    Impl& d = *impl_;
    Emergence e{};
    if (g_failed || d.allocG <= 0) return e;
    const int G = d.allocG;

    // ── 나선팔: 밀도의 m=2 푸리에 진폭 ──────────────────────────────────
    //
    // 링별로 재고 평균하면 **나선**(`spiralM2`), 링을 다 더한 뒤 나누면 **막대**(`barM2`).
    // 왜 둘이 다른지는 `kSpiralM2` 주석에 실측표와 함께 적었다 — 한 줄로는,
    // 나선은 반지름마다 팔이 감겨 통째로 합치면 스스로 지워지고 막대는 안 지워진다.
    if (d.pos && d.vel && d.allocN > 0) {
        const int kBins = kSpiralBins;
        CK(cudaMemset(d.redD, 0, sizeof(double) * 6 * kBins));
        kSpiralM2<<<(d.allocN + 255) / 256, 256>>>(
            d.pos, d.vel, d.allocN, kBins, fmaxf(d.cfg.starSunMass, 1.0f), d.redD);
        double h[6 * kSpiralBins] = {};
        CK(cudaMemcpy(h, d.redD, sizeof(double) * 6 * kBins, cudaMemcpyDeviceToHost));

        // 앞 절반은 질량(가스·별·잔해를 고르게), 뒤 절반은 빛(별을 M^3.5 로 가중).
        // **사진에서 보이는 팔은 뒤쪽이다** — 자세한 이유는 `kSpiralM2` 주석에 적었다.
        const RingFit mass  = fitSpiralRings(h, kBins);
        const RingFit light = fitSpiralRings(h + 3 * kBins, kBins);
        e.spiralM2    = mass.amp;   e.barM2      = mass.bar;
        e.spiralRings = mass.rings; e.spiralPitch = mass.pitch;
        e.spiralPhase = mass.phase;
        e.spiralM2Lum    = light.amp;   e.spiralPitchLum = light.pitch;
        e.spiralPhaseLum = light.phase; e.spiralRingsLum = light.rings;
        e.diskCount = mass.sum;         e.diskLum    = light.sum;
    }

    // ── 금속 기울기: 재를 안·중간·바깥 세 구간으로 ─────────────────────
    //
    // 화면 격자(projA/projB)를 빌려 쓴다 — 색을 칠할 때만 쓰이고 지금은 비어 있어
    // 새로 잡지 않아도 된다(`measureRotationCurve` 가 쓰는 것과 같은 수법).
    if (d.ashGrid && d.projA && d.projB) {
        const int kBins = 3;
        CK(cudaMemset(d.projA, 0, sizeof(float) * kBins));
        CK(cudaMemset(d.projB, 0, sizeof(float) * kBins));
        kAshRadial<<<grd3(G), blk3()>>>(d.ashGrid, G, d.projA, d.projB, kBins);
        float s[3] = {0.f, 0.f, 0.f}, c[3] = {0.f, 0.f, 0.f};
        CK(cudaMemcpy(s, d.projA, sizeof(float) * kBins, cudaMemcpyDeviceToHost));
        CK(cudaMemcpy(c, d.projB, sizeof(float) * kBins, cudaMemcpyDeviceToHost));
        e.ashInner = (c[0] > 0.f) ? s[0] / c[0] : 0.f;
        e.ashMid   = (c[1] > 0.f) ? s[1] / c[1] : 0.f;
        e.ashOuter = (c[2] > 0.f) ? s[2] / c[2] : 0.f;
        // **재를 뿌린 칸이 몇 개인지도 가져온다.** 바깥이 진해 보이는데 그 칸이 열 개뿐이면
        // 그것은 기울기가 아니라 표본이 적어서다.
        e.ashCellsInner = (int)c[0];
        e.ashCellsOuter = (int)c[2];
    }

    // ── 알갱이가 어디 있나 — 위 재 분포가 착시인지 가르는 판별식 ────────
    if (d.allocN > 0 && d.projA) {
        const int kBins = 3;
        CK(cudaMemset(d.projA, 0, sizeof(float) * kBins));
        kParticleRadial<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.allocN, d.projA, kBins);
        float n3[3] = {0.f, 0.f, 0.f};
        CK(cudaMemcpy(n3, d.projA, sizeof(float) * kBins, cudaMemcpyDeviceToHost));
        e.nInner = (int)n3[0];
        e.nMid   = (int)n3[1];
        e.nOuter = (int)n3[2];
    }
    return e;
}

// 방향별 분산을 따로 돌려준다. **원반이 스스로 납작해지는지를 보는 창이다** —
// 수직(zz)이 수평(xx·yy)보다 작으면 그 방향으로 덜 밀려 원반이 얇게 유지된다는 뜻이고,
// 그것이 `diskThickness` 를 손으로 정하지 않아도 되는 이유다.
void Sim::measureDispersionAxes(double& xx, double& yy, double& zz) const {
    Impl& d = *impl_;
    xx = yy = zz = 0.0;
    if (g_failed || d.allocG <= 0 || !d.cfg.pressureEnabled) return;
    const int cells = d.allocG * d.allocG * d.allocG;
    auto sumOf = [&](const float* src) -> double {
        CK(cudaMemset(d.redD, 0, sizeof(double)));
        kSumFloatGrid<<<(cells + 255) / 256, 256>>>(src, cells, d.redD);
        double h = 0.0;
        CK(cudaMemcpy(&h, d.redD, sizeof(double), cudaMemcpyDeviceToHost));
        return h;
    };
    const double cnt = sumOf(d.dispCnt);
    if (cnt < 1.0) return;
    xx = sumOf(d.dispX) / cnt;
    yy = sumOf(d.dispY) / cnt;
    zz = sumOf(d.dispZ) / cnt;
}

// 원반의 공간 두께(z 표준편차). 위 `measureDispersionAxes` 와 짝이지만 **다른 것을 잰다** —
// 저기는 속도가 위아래로 얼마나 흩어졌나, 여기는 그래서 판이 실제로 얼마나 두꺼운가다.
// `diskThickness` 를 씨앗 0.001 로 두고 시작해 이 값이 그보다 크게 자라면, 두께를 만든 것은
// 초기 배치가 아니라 압력이다.
double Sim::measureDiskThickness() const {
    Impl& d = *impl_;
    if (g_failed || d.allocN <= 0) return 0.0;
    CK(cudaMemset(d.redD, 0, sizeof(double) * 3));   // redD 는 4칸 — 셋을 쓴다
    kDiskThickness<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.allocN, d.redD);
    CK(cudaGetLastError());
    double h[3] = {0.0, 0.0, 0.0};
    CK(cudaMemcpy(h, d.redD, sizeof(double) * 3, cudaMemcpyDeviceToHost));
    if (h[2] < 2.0) return 0.0;
    const double mean = h[0] / h[2];
    // 알갱이가 수백만이라 표본분산(n−1)과 모분산(n)의 차이는 유효숫자 밖이다.
    // 음수는 부동소수 오차로만 나오므로 0 으로 자른다.
    const double var = h[1] / h[2] - mean * mean;
    return var > 0.0 ? sqrt(var) : 0.0;
}

// 판 전체에 쌓인 재의 총량. 사슬이 도는지 밖에서 확인할 창이다.
double Sim::totalAsh() const {
    Impl& d = *impl_;
    if (g_failed || d.allocG <= 0 || !d.ashGrid) return 0.0;
    const int cells = d.allocG * d.allocG * d.allocG;
    CK(cudaMemset(d.redD, 0, sizeof(double)));
    kSumFloatGrid<<<(cells + 255) / 256, 256>>>(d.ashGrid, cells, d.redD);
    double h = 0.0;
    CK(cudaMemcpy(&h, d.redD, sizeof(double), cudaMemcpyDeviceToHost));
    return h;
}
BlackHoleState Sim::blackHole() const { return impl_->heaviest(); }
int Sim::blackHoleCount() const { return impl_->bhCount; }
BlackHoleState Sim::blackHoleAt(int i) const {
    if (i < 0 || i >= impl_->bhCount) return BlackHoleState{};
    return impl_->bhs[i];
}
void Sim::clearBlackHoles() {
    Impl& d = *impl_;
    d.bhCount = 0;
    for (int i = 0; i < kMaxBlackHoles; ++i) {
        d.bhs[i] = BlackHoleState{};
    }
    if (d.eaten) CK(cudaMemset(d.eaten, 0, sizeof(int) * kMaxBlackHoles));
    if (d.bhAcc) CK(cudaMemset(d.bhAcc, 0, sizeof(float4) * kMaxBlackHoles));
}

double Sim::measureTotalGridMass() {
    Impl& d = *impl_;
    if (g_failed) return 0.0;
    const size_t cells = d.padCells();
    size_t need = 0;
    cub::DeviceReduce::Sum(nullptr, need, d.rho, (float*)d.redD, (int)cells);
    if (need > d.redTmpBytes) {
        if (d.redTmp) cudaFree(d.redTmp);
        CK(cudaMalloc(&d.redTmp, need));
        d.redTmpBytes = need;
    }
    if (g_failed) return 0.0;
    cub::DeviceReduce::Sum(d.redTmp, d.redTmpBytes, d.rho, (float*)d.redD, (int)cells);
    float s = 0.f;
    CK(cudaMemcpy(&s, d.redD, sizeof(float), cudaMemcpyDeviceToHost));
    return (double)s;
}

double Sim::measureMaxDensity() {
    Impl& d = *impl_;
    if (g_failed) return 0.0;
    const size_t cells = d.padCells();
    size_t need = 0;
    cub::DeviceReduce::Max(nullptr, need, d.rho, (float*)d.redD, (int)cells);
    if (need > d.redTmpBytes) {
        if (d.redTmp) cudaFree(d.redTmp);
        CK(cudaMalloc(&d.redTmp, need));
        d.redTmpBytes = need;
    }
    if (g_failed) return 0.0;
    cub::DeviceReduce::Max(d.redTmp, d.redTmpBytes, d.rho, (float*)d.redD, (int)cells);
    float s = 0.f;
    CK(cudaMemcpy(&s, d.redD, sizeof(float), cudaMemcpyDeviceToHost));
    return (double)s;
}

int Sim::measureOccupiedCells() {
    Impl& d = *impl_;
    if (g_failed) return 0;
    const size_t cells = d.padCells();
    CK(cudaMemset(d.redI, 0, sizeof(int)));
    kCountOccupied<<<(int)((cells + 255) / 256), 256>>>(d.rho, (int)cells, d.redI, 1e-6f);
    int c = 0;
    CK(cudaMemcpy(&c, d.redI, sizeof(int), cudaMemcpyDeviceToHost));
    return c;
}

void Sim::measureCentroid(double& cx, double& cy) {
    Impl& d = *impl_;
    cx = cy = 0.5;
    if (g_failed || d.allocN <= 0) return;
    CK(cudaMemset(d.redD, 0, sizeof(double) * 2));
    CK(cudaMemset(d.redI, 0, sizeof(int)));
    kCentroidAccum<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.allocN,
                                                    d.redD, d.redD + 1, d.redI);
    double s[2] = { 0, 0 };
    int cnt = 0;
    CK(cudaMemcpy(s, d.redD, sizeof(double) * 2, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(&cnt, d.redI, sizeof(int), cudaMemcpyDeviceToHost));
    if (cnt > 0) { cx = s[0] / cnt; cy = s[1] / cnt; }
}

// 판의 평균 「온도」 — 별 계에서 온도란 곧 **무작위 운동의 세기**다.
//
// 오래 `return 0.0` 이었다. 잴 것이 없어서가 아니라 재는 자리가 없었기 때문인데,
// 압력을 넣으면서 그 값이 격자에 생겼다(dispX/Y/Z 는 방향별 잔차 분산의 합, dispCnt 는 개수).
// 셋을 더해 개수로 나누면 알갱이 하나당 평균 분산이 나온다.
//
// **이 값이 「압력이 회전을 압력으로 착각하지 않는가」를 밖에서 확인하는 창이다.**
// 이웃 속도를 절대값으로 모았다면 차등회전이 그대로 잡혀, 사이좋게 도는 판에서도
// 이 값이 크게 나온다. kCool 이 자기 속도를 기준으로 재므로 그런 판에서는 0 에 가까워야 한다.
//
// 압력이 꺼져 있으면 격자가 안 채워지므로 0 을 돌려준다 — 옛 값이 남아 거짓을 말하지 않게.
double Sim::measureMeanTemperature() {
    Impl& d = *impl_;
    if (g_failed || d.allocG <= 0 || !d.cfg.pressureEnabled) return 0.0;
    const int cells = d.allocG * d.allocG * d.allocG;

    // 네 격자를 각각 합친다. redD 는 double 두 칸짜리 축소용 버퍼다.
    auto sumOf = [&](const float* src) -> double {
        CK(cudaMemset(d.redD, 0, sizeof(double)));
        kSumFloatGrid<<<(cells + 255) / 256, 256>>>(src, cells, d.redD);
        double h = 0.0;
        CK(cudaMemcpy(&h, d.redD, sizeof(double), cudaMemcpyDeviceToHost));
        return h;
    };
    const double cnt = sumOf(d.dispCnt);
    if (cnt < 1.0) return 0.0;
    return (sumOf(d.dispX) + sumOf(d.dispY) + sumOf(d.dispZ)) / cnt;
}

namespace {
// 파일 첫머리에 두는 표식. 다른 파일을 열었을 때 조용히 이상한 우주가 되는 것을 막는다.
// 형식이 바뀌면 판을 올린다 — 옛 파일을 읽어 알갱이가 엉뚱한 곳에 놓이는 것보다
// 「못 읽는다」가 낫다.
struct StateHeader {
    char  magic[8];      // "STARDUST"
    int   version;       // 1
    int   count;         // 살아 있는 알갱이 수
    int   gridSize;
    int   preset;
    int   boundary;
    float gravity;
    float simTime;
    float bhX, bhY, bhRs, bhMass;
    int   bhActive;
    int   reserved[5];
};
} // namespace

bool Sim::saveState(const std::string& path) {
    Impl& d = *impl_;
    if (g_failed || d.allocN <= 0) return false;
    const int n = (d.active > 0) ? d.active : d.allocN;

    std::vector<float4> hp(n), hv(n);
    if (cudaMemcpy(hp.data(), d.pos, sizeof(float4) * n, cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(hv.data(), d.vel, sizeof(float4) * n, cudaMemcpyDeviceToHost) != cudaSuccess)
        return false;

    StateHeader h{};
    memcpy(h.magic, "STARDUST", 8);
    // 판 2 — 블랙홀을 여럿 담는다. 판 1 은 하나만 담았고, 그것은 아래 머리말 자리에
    // 그대로 남겨 두어 옛 판을 읽는 쪽이 계속 동작한다.
    h.version = 2;
    h.count = n;
    h.gridSize = d.allocG;
    h.preset = (int)d.cfg.preset;
    h.boundary = (int)d.cfg.boundary;
    h.gravity = d.cfg.gravity;
    h.simTime = (float)d.simTime;
    {
        const BlackHoleState top = d.heaviest();
        h.bhX = top.x; h.bhY = top.y; h.bhRs = top.rs; h.bhMass = top.mass;
        h.bhActive = top.active ? 1 : 0;
    }
    h.reserved[0] = d.bhCount;

    FILE* f = nullptr;
    if (fopen_s(&f, path.c_str(), "wb") != 0 || !f) return false;
    // 쓴 만큼과 닫기까지 확인한다 — 디스크가 모자라면 fwrite 가 적게 쓰고,
    // 버퍼에 남은 것은 fclose 에서야 실패한다. 둘 다 안 보면 깨진 파일에 성공을 돌려준다.
    bool ok = fwrite(&h, sizeof(h), 1, f) == 1
           && (d.bhCount <= 0 ||
               fwrite(d.bhs, sizeof(BlackHoleState), d.bhCount, f) == (size_t)d.bhCount)
           && fwrite(hp.data(), sizeof(float4), n, f) == (size_t)n
           && fwrite(hv.data(), sizeof(float4), n, f) == (size_t)n;
    ok = (fclose(f) == 0) && ok;
    return ok;
}

bool Sim::loadState(const std::string& path) {
    Impl& d = *impl_;
    if (g_failed) return false;

    FILE* f = nullptr;
    if (fopen_s(&f, path.c_str(), "rb") != 0 || !f) return false;
    StateHeader h{};
    if (fread(&h, sizeof(h), 1, f) != 1 ||
        memcmp(h.magic, "STARDUST", 8) != 0 ||
        (h.version != 1 && h.version != 2) ||
        h.count <= 0 || h.count > 100000000) {
        fclose(f);
        return false;
    }

    // 블랙홀은 알갱이보다 **먼저** 담겨 있다. 아래 reconfigure 가 판을 새로 깔면서
    // 블랙홀을 비우므로, 읽어만 두었다가 그 뒤에 되돌린다.
    BlackHoleState loadedBh[kMaxBlackHoles];
    int loadedBhCount = 0;
    if (h.version >= 2) {
        loadedBhCount = h.reserved[0];
        if (loadedBhCount < 0 || loadedBhCount > kMaxBlackHoles) { fclose(f); return false; }
        if (loadedBhCount > 0 &&
            fread(loadedBh, sizeof(BlackHoleState), loadedBhCount, f) != (size_t)loadedBhCount) {
            fclose(f);
            return false;
        }
    } else if (h.bhActive) {
        // 판 1 은 블랙홀을 하나만 담았다. 머리말 자리에 그대로 있다.
        loadedBh[0] = BlackHoleState{};
        loadedBh[0].active = true;
        loadedBh[0].x = h.bhX; loadedBh[0].y = h.bhY; loadedBh[0].z = 0.5f;
        loadedBh[0].rs = h.bhRs; loadedBh[0].mass = h.bhMass;
        loadedBhCount = 1;
    }

    // 이 카드가 감당할 수 있는 만큼만 읽는다. 파일이 요구하는 대로 잡으면
    // 다른 컴퓨터에서 만든 파일 하나로 여기서 메모리가 터진다.
    SimConfig c = d.cfg;
    c.particleCount = h.count;
    c.gridSize = h.gridSize;
    c.preset = (Preset)h.preset;
    c.boundary = (Boundary)h.boundary;
    c.gravity = h.gravity;
    reconfigure(c);
    if (g_failed) { fclose(f); return false; }

    const int n = (h.count < d.allocN) ? h.count : d.allocN;
    std::vector<float4> hp(n), hv(n);
    bool ok = fread(hp.data(), sizeof(float4), n, f) == (size_t)n
           && fread(hv.data(), sizeof(float4), n, f) == (size_t)n;
    fclose(f);
    if (!ok) return false;

    if (cudaMemcpy(d.pos, hp.data(), sizeof(float4) * n, cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(d.vel, hv.data(), sizeof(float4) * n, cudaMemcpyHostToDevice) != cudaSuccess)
        return false;
    // 파일보다 버퍼가 크면 남는 자리를 빈 슬롯으로 눌러 둔다 — 미초기화 좌표가
    // 격자 밖을 가리키면 그대로 커널이 배열 밖을 건드린다.
    if (n < d.allocN)
        kHideRange<<<((d.allocN - n) + 255) / 256, 256>>>(d.pos, d.vel, n, d.allocN);

    d.active = n;
    d.aliveShown = -1;                     // 불러온 판이니 세어 둔 값은 버린다
    d.simTime = h.simTime;

    // 담아 두었던 블랙홀을 되돌린다. 지평선은 질량에서 다시 내므로 파일에 있는 값을
    // 그대로 믿지 않는다 — 옛 파일은 부풀린 지평선을 담고 있다.
    d.bhCount = loadedBhCount;
    for (int i = 0; i < kMaxBlackHoles; ++i) {
        d.bhs[i] = (i < loadedBhCount) ? loadedBh[i] : BlackHoleState{};
        if (i < loadedBhCount) d.setRsFrom(i);
    }
    CK(cudaMemset(d.eaten, 0, sizeof(int) * kMaxBlackHoles));
    CK(cudaMemset(d.bhAcc, 0, sizeof(float4) * kMaxBlackHoles));

    d.computeAccel();
    CK(cudaGetLastError());
    return !g_failed;
}

void Sim::measureRotationCurve(float* out, int bins, float maxRadius) {
    Impl& d = *impl_;
    for (int i = 0; i < bins; ++i) out[i] = 0.f;
    if (g_failed || d.allocN <= 0 || bins <= 0 || maxRadius <= 0.f) return;

    // 고리마다 합과 개수를 따로 모아 나눈다. 화면 격자(projA/projB)를 빌려 쓴다 —
    // 이 둘은 색을 칠할 때만 쓰이고 지금은 비어 있어, 새로 잡지 않아도 된다.
    const int cells = d.allocG * d.allocG;
    if (bins > cells) bins = cells;
    kClearF<<<(bins + 255) / 256, 256>>>(d.projA, bins);
    kClearF<<<(bins + 255) / 256, 256>>>(d.projB, bins);
    kRotationAccum<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN,
                                                    d.projA, d.projB, bins, maxRadius);
    std::vector<float> sum(bins), cnt(bins);
    CK(cudaMemcpy(sum.data(), d.projA, sizeof(float) * bins, cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(cnt.data(), d.projB, sizeof(float) * bins, cudaMemcpyDeviceToHost));
    for (int i = 0; i < bins; ++i) out[i] = (cnt[i] > 0.5f) ? (sum[i] / cnt[i]) : 0.f;
}

double Sim::measureKineticEnergy() {
    Impl& d = *impl_;
    if (g_failed || d.allocN <= 0) return 0.0;
    CK(cudaMemset(d.redD, 0, sizeof(double)));
    kKineticAccum<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, d.redD);
    double e = 0.0;
    CK(cudaMemcpy(&e, d.redD, sizeof(double), cudaMemcpyDeviceToHost));
    return e;
}

const float* Sim::densityDevicePtr() const { return impl_->rho; }

// 성운을 입히기 전의 별빛 격자. **밝기 정규화의 기준은 이것으로 잡는다.**
//
// 밝기로 가중한 온도의 합 격자. **밝기 격자로 나누면 그 픽셀의 대표 온도(K)가 된다.**
// `fieldDevicePtr(Field::Light)` 를 부른 뒤에만 뜻이 있다.
const float* Sim::lightTempDevicePtr() const { return impl_->projT; }

// 「폭발 자리에서 새 별이 태어나는가」 — 새로 태어난 별이 있던 칸의 **재 평균**이다.
// 판 전체의 칸당 재 평균과 견주면 답이 나온다: 이쪽이 크면 재가 쌓인 자리(별이 터진
// 자리)에서 별이 더 잘 태어난다는 뜻이다.
// 회전곡선 — 반지름 네 구간의 평균 접선 속도. 바깥 두 구간이 안 떨어지면 평평한 것이다.
void Sim::rotationCurve(float* out4) const {
    Impl& d = *impl_;
    for (int i = 0; i < 4; ++i) out4[i] = 0.f;
    if (g_failed || d.allocN <= 0 || !d.redD) return;
    // 판 중앙이 아니라 **무게중심** 기준이다 — 은하가 판 가운데 있다는 보장이 없고,
    // 그것을 판 중앙으로 재다가 금속 기울기를 100배 틀리게 읽은 적이 있다(round-24).
    // `measureCentroid` 가 non-const 인 것은 GPU 작업을 하기 때문이지 판을 바꿔서가
    // 아니다(`measureConservation` 도 같은 일을 하면서 const 다).
    double cxd = 0.5, cyd = 0.5;
    const_cast<Sim*>(this)->measureCentroid(cxd, cyd);
    const float cx = (float)cxd, cy = (float)cyd;
    if (cudaMemset(d.redD, 0, sizeof(double) * 8) != cudaSuccess) return;
    kRotationCurve<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, cx, cy, d.redD);
    double h[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    if (cudaMemcpy(h, d.redD, sizeof(double) * 8, cudaMemcpyDeviceToHost) != cudaSuccess) return;
    for (int i = 0; i < 4; ++i) out4[i] = (h[4 + i] > 0.5) ? (float)(h[i] / h[4 + i]) : 0.f;
}

// 분산 텐서의 **교차항 크기 ÷ 대각항 크기.** 0 에 가까우면 대각 셋만 들어도 된다는 뜻이고,
// 그것이 설계 때의 추정이었다. `doCooling` 이 채운 칸별 속도 합을 그대로 읽으므로
// 이웃을 다시 훑지 않는다 — 압력이 꺼져 있으면 그 격자가 없어 0 을 돌려준다.
double Sim::dispCrossRatio() const {
    Impl& d = *impl_;
    if (g_failed || d.allocN <= 0 || !d.redD || !d.velSumX || !d.dispCnt) return 0.0;
    if (cudaMemset(d.redD, 0, sizeof(double) * 4) != cudaSuccess) return 0.0;
    kCrossTerms<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, d.allocG,
                                                 d.periodic() ? 1 : 0,
                                                 d.velSumX, d.velSumY, d.velSumZ,
                                                 d.dispCnt, d.redD);
    double h[4] = {0, 0, 0, 0};
    if (cudaMemcpy(h, d.redD, sizeof(double) * 4, cudaMemcpyDeviceToHost) != cudaSuccess) return 0.0;
    // **부호를 살린 합**으로 돌려준다. 절댓값 합(h[0])은 상관 없는 등방 난류에서도
    // 0.637 이 나오므로(E|xy|·3 ÷ E[x²+y²+z²]) 그 값만으로는 아무것도 못 가른다.
    // 압력에 실제로 기여하는 것은 상쇄되고 남는 몫이라 이쪽을 본다.
    return (h[1] > 1e-30) ? (h[3] / h[1]) : 0.0;
}

double Sim::bornAshMean() const {
    if (!impl_->bornStat) return 0.0;
    double h[4] = {0.0, 0.0, 0.0, 0.0};
    if (cudaMemcpy(h, impl_->bornStat, sizeof(double) * 4, cudaMemcpyDeviceToHost) != cudaSuccess)
        return 0.0;
    return (h[0] > 0.5) ? (h[1] / h[0]) : 0.0;
}

// **껍질에서 태어난 별의 비율.** 새 별이 난 칸보다 **이웃 칸의 재가 진하면** 그 별은
// 재의 봉우리 **둘레**에서 태어난 것이다 — 그것이 폭발 껍질이다. 중심에서 태어났다면
// 자기 칸이 봉우리다. 폭발 지점을 따로 기억하지 않고도 껍질 구조를 가르는 창이다.
double Sim::bornShellRatio() const {
    if (!impl_->bornStat) return 0.0;
    double h[4] = {0.0, 0.0, 0.0, 0.0};
    if (cudaMemcpy(h, impl_->bornStat, sizeof(double) * 4, cudaMemcpyDeviceToHost) != cudaSuccess)
        return 0.0;
    return (h[0] > 0.5) ? (h[2] / h[0]) : 0.0;
}

// 보는 방향을 정한다. 단위행렬이면 위에서 곧장 내려다보던 예전 그림 그대로다.
void Sim::setViewRot(const float m[9]) {
    for (int i = 0; i < 9; ++i) impl_->viewM[i] = m[i];
}

// (`setViewPan` 을 지웠다 — 2026-08-18. 격자 렌더는 화면 이동을 자기가 처리하므로
//  여기서 또 받으면 두 번 적용된다. 점 렌더 쪽 화면 이동은 `makeViewRot(m, panX, panY)`
//  가 회전축을 옮기는 것으로 처리한다.)

// 화면은 위에서 내려다본다. 3D 값을 z 로 합쳐 2D 로 투영해 넘긴다.
const float* Sim::fieldDevicePtr(Field field) {
    Impl& d = *impl_;
    if (g_failed) return d.proj;
    const int G = d.allocG;
    const int cells = G * G;
    const int blocks = (cells + 255) / 256;

    const ViewRot rot = d.viewRot();

    if (field == Field::Density) {
        kClearF<<<blocks, 256>>>(d.proj, cells);
        kProjectXY<<<grd3(G), blk3()>>>(d.rho, d.proj, G, d.stride(), rot);
        CK(cudaGetLastError());
        return d.proj;
    }

    // **재 = 은하의 나이 지도.** 별이 죽으며 뿌린 무거운 원소가 쌓인 곳이 곧 별이 많이
    // 태어나고 많이 죽은 곳이다. 실제 은하는 중심이 진하고 바깥이 옅다(금속 기울기).
    //
    // `ashGrid` 는 **패딩 없이 G³** 이라 밀도 격자(`rho`, 고립 경계에서 (2G)³)와 stride 가
    // 다르다 — 그것을 섞으면 엉뚱한 자리를 읽는다. 그래서 stride 에 G 를 넘긴다.
    if (field == Field::Ash) {
        kClearF<<<blocks, 256>>>(d.proj, cells);
        if (d.ashGrid) {
            kProjectXY<<<grd3(G), blk3()>>>(d.ashGrid, d.proj, G, G, rot);
            CK(cudaGetLastError());
        }
        return d.proj;
    }

    if (field == Field::Light) {
        // 별빛은 **나누지 않는다.** 분산·속력은 「평균」이라 개수로 나눠야 하지만, 빛은
        // 합이 곧 그 자리의 밝기다 — 별 열 개가 모이면 열 배 밝은 것이 맞다.
        kClearF<<<blocks, 256>>>(d.proj, cells);
        if (d.projT) kClearF<<<blocks, 256>>>(d.projT, cells);
        // 초신성 밝기 배수. 실제 초신성은 별 1000억 개를 합친 것보다 밝지만 그 값을 그대로
        // 쓰면 화면 기준을 통째로 삼킨다(밝기 정규화가 백분위수로 바뀌기 전까지는).
        // 「가장 무거운 별보다 확실히 밝다」 선에서 끊는다.
        const float nova = 1.0e4f;
        kScatterLight<<<(d.allocN + 255) / 256, 256>>>(
            d.pos, d.vel, d.allocN, G, d.proj, d.projT, rot,
            fmaxf(d.cfg.starSunMass, 1.0f), nova,
            fmaxf(d.cfg.starExplodeSim, 1e-4f),
            fmaxf(d.cfg.starEmbedTime, 0.f));

        // (성운 블록을 지웠다 — 2026-08-18. 별빛을 흐려 「퍼진 별빛」을 만들고 그것을
        //  가스에 곱해 별 둘레를 넓게 밝히던 자리다. 사용자 요청 — 「이런식으로 주위가
        //  밝게 나오는거 제거해줘」. 08-17 에 같은 이유로 지운 별 후광과 한 몸이다.
        //
        //  이제 `proj` 는 `kScatterLight` 가 별을 자기 칸에 뿌린 것 그대로이고, 밝기
        //  정규화도 이 격자를 그대로 기준 삼으면 된다 — 따로 남겨 두던 `projLight` 도
        //  함께 없앴다.)

        CK(cudaGetLastError());
        return d.proj;
    }

    // 속도 분산(=은하의 온도)은 알갱이에서 바로 뿌린다.
    // 격자에는 속도가 없으므로 3D 격자를 거치지 않고 화면 격자에 곧장 쌓는다.
    kClearF<<<blocks, 256>>>(d.projA, cells);
    kClearF<<<blocks, 256>>>(d.projB, cells);
    kScatterDispersion<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, G,
                                                        d.projA, d.projB, rot);
    kDivideInto<<<blocks, 256>>>(d.projA, d.projB, d.proj, cells);
    CK(cudaGetLastError());
    return d.proj;
}

const float* Sim::particlePosDevicePtr() const { return (const float*)impl_->pos; }
const float* Sim::particleVelDevicePtr() const { return (const float*)impl_->vel; }

// ---------------------------------------------------------------------------
// 마우스 도구
// ---------------------------------------------------------------------------
int Sim::addShape(float cx, float cy, ShapeKind kind, float radius, int count, bool autoOrbit) {
    Impl& d = *impl_;
    if (g_failed || d.allocN <= 0) return 0;

    // 블랙홀은 알갱이가 아니다 — 그 자리에 지평선을 세운다.
    //
    // 크기(반지름)가 곧 질량이다. rs = 2GM/c² 이므로 M = rs·c²/(2G) 이고, 크게 놓을수록
    // 무거운 블랙홀이 되어 둘레의 것을 더 멀리서부터 끌어당긴다.
    if (kind == ShapeKind::BlackHole) {
        // **놓는 알갱이 수의 50분의 1 이 블랙홀의 질량이다.**
        //
        // 개수를 그대로 질량으로 쓰던 때는 기본값(15만)만으로도 판 물질의 15% 짜리 블랙홀이
        // 생겼다. 실제 은하는 중심 블랙홀이 은하 질량의 0.1% 안팎이고, 15% 는 그보다 백 배
        // 넘게 무겁다 — 여럿 놓으면 서로 순식간에 끌려가 합쳐지고, 둘레 알갱이는 슬링샷으로
        // 판 밖까지 튕겨 나갔다(2026-08-14 실측: 여덟 개가 40초 만에 하나로, 질량은 판
        // 전체의 292% 까지). 50분의 1 이면 기본값이 판의 0.3% 라 원반이 살아남는다.
        //
        // 지평선은 그 질량에서 낸다. 실제로는 질량에 정비례하지만(rs = 2GM/c²), 이 우주의
        // 광속으로는 화면의 점보다 작아 보이지 않는다. 그래서 「판 전체의 2% 를 모았을 때
        // 0.006」을 기준으로 잡고 세제곱근으로 키운다 — 선형으로 키우면 부풀린 크기까지
        // 함께 자라 삼킬수록 커지고 커질수록 삼키는 되먹임이 생긴다(2026-08-14 실측).
        // 지평선·자리 잡기는 addBlackHole 이 쥔다. 여덟 개까지 나란히 선다.
        const int bi = d.addBlackHole(cx, cy, 0.5f,
                                      (float)(count > 0 ? count : 1) * d.cfg.blackHoleMassScale,
                                      false);

        // **둘레에 궤도를 준다 — 이게 없으면 놓자마자 전부 빨려 든다.**
        //
        // 여기 있던 알갱이들의 속도는 이 블랙홀이 없다는 전제로 정해진 것이라, 새 중심에
        // 대한 각운동량이 거의 없다. 각운동량 없는 것은 궤도를 그리지 못하고 곧장 떨어진다.
        // reset 이 블랙홀을 알갱이보다 **먼저** 세우는 것도 같은 이유인데, 마우스로 놓는
        // 쪽은 순서를 그렇게 할 수 없으니 여기서 궤도를 만들어 준다.
        // (자세한 규칙은 kOrbitAroundBH 의 주석에 있다.)
        {
            const float gm = d.cfg.gravity * d.bhs[bi].mass
                           / (float)(d.allocN > 0 ? d.allocN : 1);
            // 최소 안정 궤도(3rs) 안쪽은 손대지 않는다 — 거기서는 나선으로 떨어지는 것이
            // 옳고, 그 모습이 강착원반의 안쪽 가장자리가 깎이는 장면이다.
            const float rIn  = 3.0f * d.bhs[bi].rs;
            // 브러시 크기가 「어디까지 돌게 할지」를 정한다. 너무 좁으면 바로 바깥이 그대로
            // 쏟아져 들어와 결국 같은 일이 벌어지므로 최소 폭을 함께 둔다.
            const float rOut = fmaxf(radius * 2.0f, rIn * 6.0f);
            kOrbitAroundBH<<<(d.allocN + 255) / 256, 256>>>(
                d.pos, d.vel, d.allocN, cx, cy, 0.5f, gm, rIn, rOut);
            CK(cudaGetLastError());
        }
        return 1;
    }

    if (count <= 0) return 0;

    // 빈 자리가 있으면 거기에 넣고, 다 찼으면 앞에서부터 덮어쓴다.
    //
    // 장면을 깔면 알갱이를 전부 쓰므로 빈 자리가 하나도 없다. 빈 자리만 찾으면 그때부터
    // 「놓기」가 아무 일도 하지 않는다(2026-08-14 실측: 100만 알 장면에서 99만을 놓으려니
    // 한 알도 안 들어갔다). 덮어쓰기가 있어야 언제 눌러도 놓인다.
    //
    // 커서 계산은 정수로만 하고 매번 범위를 확인한다 — 예전에 이 자리에서 커서가 배열 밖으로
    // 넘어가 시스템이 재부팅됐다.
    int n = (count < d.allocN) ? count : d.allocN;
    int from;
    const int room = d.allocN - d.active;
    if (room >= n) {
        from = d.active;
        d.active += n;
    } else {
        from = d.ringCursor;
        if (from < 0 || from + n > d.allocN) from = 0;
        d.ringCursor = from + n;
        if (d.ringCursor >= d.allocN) d.ringCursor = 0;
        d.active = d.allocN;
    }
    d.aliveShown = -1;                     // 알갱이를 새로 넣었으니 세어 둔 값은 버린다

    kFillShape<<<(n + 255) / 256, 256>>>(d.pos, d.vel, from, n, cx, cy,
                                         (int)kind, radius, d.cfg.diskThickness,
                                         (unsigned)(d.stepCount * 7919 + 17));

    if (autoOrbit) {
        d.computeAccel();
        kAccelMag<<<(d.allocN + 255) / 256, 256>>>(d.accG, d.pos, d.accMag, d.allocN,
                                                   d.allocG, d.periodic() ? 1 : 0,
                                                   d.packBH());
        kSetOrbitAt<<<(n + 255) / 256, 256>>>(d.vel, d.pos, d.accMag, from, n, cx, cy);
    }
    CK(cudaGetLastError());
    return n;
}

void Sim::sprayAt(float cx, float cy, float radius, float strength) {
    Impl& d = *impl_;
    if (g_failed) return;
    kBrushPush<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, cx, cy, radius, strength);
    CK(cudaGetLastError());
}

void Sim::wellAt(float cx, float cy, float radius, float strength) {
    Impl& d = *impl_;
    if (g_failed) return;
    kBrushPush<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, cx, cy, radius, -strength);
    CK(cudaGetLastError());
}

int Sim::eraseAt(float cx, float cy, float radius) {
    Impl& d = *impl_;
    if (g_failed) return 0;

    // **브러시 안의 블랙홀도 함께 지운다.**
    //
    // 알갱이만 지우면 블랙홀은 둘레가 비어 눈에 안 보일 뿐 그 자리에 그대로 남아 계속
    // 끌어당긴다. 지운 줄 알았던 블랙홀이 남은 알갱이를 슬링샷으로 판 밖까지 튕겨 내
    // 화면이 통째로 비었다(2026-08-14 보고 — 알갱이 41만에 블랙홀 질량 521만이 남아 있었다).
    // 깊이는 보지 않는다 — 화면에서 고르므로, kEraseIn 과 같은 규칙이다.
    for (int i = d.bhCount - 1; i >= 0; --i) {
        const float dx = d.bhs[i].x - cx, dy = d.bhs[i].y - cy;
        if (dx * dx + dy * dy > radius * radius) continue;
        // 뒤를 당긴다 — 가운데를 비워 두면 번호가 어긋난다(블랙홀 배열의 불변식).
        for (int k = i; k + 1 < d.bhCount; ++k) {
            d.bhs[k]           = d.bhs[k + 1];
        }
        --d.bhCount;
        d.bhs[d.bhCount] = BlackHoleState{};
    }
    // 자리를 당겼으니 「삼킨 수」는 통째로 비운다. 안 비우면 남은 블랙홀이 지워진 것의
    // 몫을 자기 질량에 얹는다.
    if (d.eaten) CK(cudaMemset(d.eaten, 0, sizeof(int) * kMaxBlackHoles));

    CK(cudaMemset(d.redI, 0, sizeof(int)));
    kEraseIn<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.allocN, cx, cy, radius, d.redI);
    int erased = 0;
    CK(cudaMemcpy(&erased, d.redI, sizeof(int), cudaMemcpyDeviceToHost));
    if (erased <= 0) return 0;

    // 지운 자리를 메워 살아 있는 것을 앞으로 모은다. 이 불변식이 깨지면 형태를 다시 넣을 때
    // 요청한 개수가 안 들어간다.
    kMarkAlive<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.allocN, d.flag);
    size_t need = 0;
    cub::DeviceScan::ExclusiveSum(nullptr, need, d.flag, d.scan, d.allocN);
    if (need > d.redTmpBytes) {
        if (d.redTmp) cudaFree(d.redTmp);
        CK(cudaMalloc(&d.redTmp, need));
        d.redTmpBytes = need;
    }
    if (g_failed) return erased;
    cub::DeviceScan::ExclusiveSum(d.redTmp, d.redTmpBytes, d.flag, d.scan, d.allocN);
    kCompact<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.vel, d.temp, d.flag, d.scan,
                                              d.allocN, d.posTmp, d.velTmp, d.tempTmp);
    std::swap(d.pos, d.posTmp); std::swap(d.vel, d.velTmp); std::swap(d.temp, d.tempTmp);
    d.active -= erased;
    if (d.active < 0) d.active = 0;
    d.aliveShown = -1;                     // 자리를 당겼으니 세어 둔 값은 버린다
    if (d.active < d.allocN)
        kHideRange<<<((d.allocN - d.active) + 255) / 256, 256>>>(d.pos, d.vel, d.active, d.allocN);
    CK(cudaGetLastError());
    return erased;
}
