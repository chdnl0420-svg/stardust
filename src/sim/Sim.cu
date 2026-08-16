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
__device__ __forceinline__ float3 diskPoint(float R, float thickness, unsigned s) {
    const float u1 = rnd01(s), u2 = rnd01(s * 3u + 1u), u4 = rnd01(s * 13u + 7u);

    // 반지름 — 표면 밀도가 exp(-r/h) 라도, **그 반지름에 있는 별의 수**는 원둘레가 곱해져
    // r·exp(-r/h) 다. 지수분포를 그대로 쓰면 중심에 과하게 몰려 팔이 안 보인다(실측).
    // r·exp(-r/h) 는 지수 둘의 합이라, 균등난수 두 개의 로그를 더하면 그 분포가 나온다.
    // 스케일 길이. 짧게 잡으면 알갱이가 중심에 몰려 정작 팔이 보이는 반지름대가 비고,
    // 화면에는 밝은 점 하나에 흐릿한 테두리만 남는다(2026-08-14 실측).
    const float h = R * 0.42f;
    float r = -h * (__logf(fmaxf(u1, 1e-6f)) + __logf(fmaxf(u4, 1e-6f)));
    if (r > R * 1.6f) r = R * 1.6f;                  // 아주 먼 꼬리는 자른다
    r = fmaxf(r, R * 0.015f);

    // 감김각. 작을수록 촘촘히 감긴다. 22°(0.40)로 벌렸더니 팔이 거의 안 감겨 막대처럼
    // 보였다(2026-08-14 실측) — 16° 로 조여 두 팔이 확실히 한 바퀴 이상 돌게 한다.
    const float tanI = 0.29f;
    const float psi = __logf(r / (R * 0.06f)) / tanI;

    const float th0 = u2 * 6.2831853f;
    // 팔을 뾰족하게 만든다.
    //
    // 각을 -(A/2)·sin(2Δ) 만큼 당기면 밀도가 1 + A·cos(2Δ) 가 된다(변환의 야코비안).
    // 그런데 코사인 하나로는 팔이 완만한 언덕이라, A 를 상한까지 올려도 팔과 그 사이의
    // 경계가 흐리다. 두 배 빠른 항을 함께 당기면 밀도에 cos(4Δ) 가 더해져 마루가 좁아지고
    // 골이 넓어진다 — 실제 은하의 팔이 그렇게 생겼다(좁은 띠와 넓은 빈 공간).
    //
    // 제약은 야코비안 1 - A·cos(2Δ) - B·cos(4Δ) 가 0 보다 커야 한다는 것이다. 둘이 함께
    // 최대가 되는 자리에서 A + B 가 1 을 넘으면 각이 접혀 알갱이가 한 줄에 겹쳐 쌓인다.
    //
    // 팔이 가장 진한 반지름은 바깥으로 둔다 — 안쪽은 팽대부가 덮어 어차피 안 보인다.
    const float rn = r / R;
    const float env = __expf(-(rn - 0.55f) * (rn - 0.55f) / 0.42f);
    const float A = 0.62f * env;
    const float B = 0.30f * env;                     // A + B <= 0.92 — 접히지 않는 선
    const float dd = 2.0f * (th0 - psi);
    const float th = th0 - (A * 0.5f) * __sinf(dd) - (B * 0.25f) * __sinf(2.0f * dd);

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

// 알갱이를 처음 놓는다.
//
// 비용: N 스레드 × O(1). 한 프레임이 아니라 판을 새로 깔 때 한 번만 돈다.
__global__ void kPlace(float4* pos, float4* vel, float* temp, int n, int preset,
                       float bulgeFrac, float bulgeR, float thickness, unsigned seed) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const unsigned s = (unsigned)i * 2654435761u + seed;
    const float u1 = rnd01(s), u2 = rnd01(s * 3u + 1u), u3 = rnd01(s * 7u + 5u);
    float x = 0.5f, y = 0.5f, z = 0.5f;

    if (preset == 0 || preset == 3) {            // 나선 은하 · 블랙홀
        const float R = 0.30f;
        if (u3 < bulgeFrac) {
            const float3 b = bulgePoint(bulgeR, s ^ 0x51ED2701u);
            x = 0.5f + b.x; y = 0.5f + b.y; z = 0.5f + b.z;
        } else {
            const float3 p = diskPoint(R, thickness, s ^ 0x9E3779B9u);
            x = 0.5f + p.x; y = 0.5f + p.y; z = 0.5f + p.z;
        }
    } else if (preset == 1) {                    // 은하 충돌 — 나선 둘이 양옆에서
        const int side = (i & 1);
        const float cx = side ? 0.72f : 0.28f;
        const float R = 0.20f;
        if (u3 < bulgeFrac) {
            const float3 b = bulgePoint(bulgeR * 0.8f, s ^ 0x51ED2701u);
            x = cx + b.x; y = 0.5f + b.y; z = 0.5f + b.z;
        } else {
            const float3 p = diskPoint(R, thickness, s ^ 0x9E3779B9u);
            x = cx + p.x; y = 0.5f + p.y; z = 0.5f + p.z;
        }
    } else if (preset == 2) {                    // 우주 거미줄 — 고르게 깔고 씨앗을 심는다
        x = u1; y = u2; z = u3;

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
        // 판 밖으로 밀려 나간 것은 반대편으로 감는다 — 이 장면은 주기 경계를 쓴다.
        x -= floorf(x); y -= floorf(y); z -= floorf(z);
    } else {                                     // 빈 판
        pos[i] = make_float4(-1.f, -1.f, -1.f, 0.f);
        vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
        if (temp) temp[i] = 0.f;
        return;
    }

    pos[i] = make_float4(x, y, z, 0.f);
    vel[i] = make_float4(0.f, 0.f, 0.f, 0.f);
    if (temp) temp[i] = 0.02f;
}

// 격자 중력을 한 번 푼 뒤, 그 자리에서 원 궤도가 되는 속도를 넣는다.
//
// 속도를 임의로 정하면 원반이 흩어진다 — 그 자리 중력이 얼마인지 재서 정해야 한다.
// 회전은 xy 평면에서 일어난다(원반의 축이 z 다).
//
// 비용: N 스레드 × O(1). 판을 깔 때 한 번.
__global__ void kSetOrbit(const float4* accG_unused, float4* vel, const float4* pos,
                          const float* accMag, int n, float dispersion,
                          float bulgeR, float2 base, float thickness) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) return;

    const float dx = p.x - 0.5f, dy = p.y - 0.5f;
    const float r = sqrtf(dx * dx + dy * dy);
    if (r < 1e-5f) { vel[i] = make_float4(base.x, base.y, 0.f, 0.f); return; }

    // a = v²/r 에서 v = √(a·r). accMag 는 그 자리에서 잰 중심 방향 가속도 크기다.
    const float v = sqrtf(fmaxf(accMag[i], 0.f) * r);

    // 팽대부에 가까울수록 회전보다 흩어짐이 지배한다 — 실제 은하의 중심부가 그렇다.
    const float bulgeMix = (bulgeR > 0.f) ? __expf(-(r * r) / (bulgeR * bulgeR)) : 0.f;
    const float disp = dispersion + 0.85f * bulgeMix;
    const float spin = 1.0f - 0.55f * bulgeMix;

    const unsigned s = (unsigned)i * 22695477u + 7u;
    const float g1 = rndNormal(s), g2 = rndNormal(s ^ 0xA341316Cu), g3 = rndNormal(s ^ 0x1B873593u);

    // 위아래 속도는 원반 두께에 맞춘다. 두께에 견줘 너무 빠르면 원반이 부풀어 사라진다.
    const float vz = g3 * v * fminf(thickness * 8.0f, 0.35f);
    vel[i] = make_float4(-dy / r * v * spin + g1 * v * disp + base.x,
                          dx / r * v * spin + g2 * v * disp + base.y,
                          vz, 0.f);
}

// ---------------------------------------------------------------------------
// 격자
// ---------------------------------------------------------------------------

__global__ void kClearF(float* a, int n) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) a[i] = 0.f;
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
                          float haloV2, float haloCore2, BHPack bh) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    if (p.x < 0.f) { out[i] = 0.f; return; }
    float4 a = sampleAcc(accG, p, G, periodic);

    if (haloV2 > 0.f) {
        const float hx = p.x - 0.5f, hy = p.y - 0.5f, hz = p.z - 0.5f;
        const float denom = hx * hx + hy * hy + hz * hz + haloCore2;
        a.x -= haloV2 * hx / denom;
        a.y -= haloV2 * hy / denom;
        a.z -= haloV2 * hz / denom;
    }
    // 처음 속도를 정할 때는 상대론 보정을 빼고 뉴턴만 본다 — 그 보정은 각운동량이
    // 정해진 뒤에야 계산할 수 있는데, 지금 정하려는 것이 바로 그 각운동량이다.
    for (int b = 0; b < bh.n; ++b) {
        const float4 bp = bh.p[b];
        const float dx = p.x - bp.x, dy = p.y - bp.y, dz = p.z - bp.z;
        const float r2 = dx * dx + dy * dy + dz * dz;
        const float r = sqrtf(fmaxf(r2, 1e-12f));
        const float m = -bh.q[b].x / (r2 * r);
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
                           BHPack bh, float c2, int* eaten,
                           float haloV2, float haloCore2,
                           const float4* accContact,
                           float waveA, float wavePattern, float wavePitch, float waveTime) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float4 p = pos[i];
    if (p.x < 0.f) return;
    float4 v = vel[i];

    float4 a = sampleAcc(accG, p, G, periodic);
    if (accContact) { const float4 c = accContact[i]; a.x += c.x; a.y += c.y; a.z += c.z; }

    // 보이지 않는 무게(암흑물질 헤일로) — 유사등온구. 바깥에서 회전 속도가 평평해진다.
    //   a(r) = -v₀²·r⃗ / (r² + rc²)
    if (haloV2 > 0.f) {
        const float hx = p.x - 0.5f, hy = p.y - 0.5f, hz = p.z - 0.5f;
        const float denom = hx * hx + hy * hy + hz * hz + haloCore2;
        a.x -= haloV2 * hx / denom;
        a.y -= haloV2 * hy / denom;
        a.z -= haloV2 * hz / denom;
    }

    // 나선 밀도파 — 팔은 물질이 아니라 회전하는 무늬다.
    //
    // 얕은 나선 골 Φ = -A·cos(2(θ - Ωp·t) - (2/tan i)·ln(r/r0)) 를 중력에 더한다.
    // 별은 골을 지날 때 잠깐 몰렸다가 빠져나가고, 몰린 자리가 팔이 된다. 그 자리는 Ωp 로
    // 돌기 때문에 원반이 몇 바퀴를 돌아도 무늬가 감기지 않는다 — 이것이 실제 은하의 팔이
    // 유지되는 방식이다(감김 문제의 답).
    //
    // 힘은 -∇Φ 다. 반지름 방향과 각 방향으로 나눠 구한 뒤 xy 로 되돌린다.
    if (waveA > 0.f) {
        const float dx = p.x - 0.5f, dy = p.y - 0.5f;
        const float r2 = dx * dx + dy * dy;
        const float r = sqrtf(fmaxf(r2, 1e-8f));
        if (r > 0.01f && r < 0.9f) {
            const float th = atan2f(dy, dx);
            const float m = 2.0f;                       // 팔 두 개
            const float km = m / fmaxf(wavePitch, 1e-3f);
            const float phase = m * (th - wavePattern * waveTime) - km * __logf(r / 0.06f);
            // 골의 깊이는 바깥으로 갈수록 사그라든다 — 원반 밖에서까지 끌면 어색하다.
            const float amp = waveA * __expf(-r / 0.30f) * r;
            const float s = __sinf(phase), c = __cosf(phase);
            // Φ = -amp·cos(phase)
            //   ∂Φ/∂r  = -(∂amp/∂r)·cos + amp·sin·(-km/r)·(-1) → 아래처럼 정리된다
            //   (1/r)∂Φ/∂θ = amp·sin·m / r
            const float dPhi_dr  = -amp * (1.0f / r - 1.0f / 0.30f) * c - amp * s * km / r;
            const float dPhi_rdth = amp * s * m / r;
            const float ar = -dPhi_dr, at = -dPhi_rdth;
            a.x += ar * (dx / r) - at * (dy / r);
            a.y += ar * (dy / r) + at * (dx / r);
        }
    }

    // 블랙홀 — 휘어진 시공간의 최단경로. 슈바르츠실트 해의 운동을 그대로 적분한다.
    //   a = -GM/r³ · (1 + 3L²/(c²r²)) · r⃗
    // 뒤의 괄호가 상대론 보정이라, 이것 하나로 광자 구면과 최소 안정 궤도가 저절로 나온다.
    // 비용: 알갱이마다 최대 kMaxBlackHoles(여덟) 번. 상한이 있다.
    for (int b = 0; b < bh.n; ++b) {
        const float4 bp = bh.p[b];
        const float dx = p.x - bp.x, dy = p.y - bp.y, dz = p.z - bp.z;
        const float r2 = dx * dx + dy * dy + dz * dz;
        const float r = sqrtf(fmaxf(r2, 1e-12f));
        if (r <= bp.w) {                       // 지평선 안으로 들어왔다 — 삼킨다
            atomicAdd(&eaten[b], 1);
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
        const float m = -bh.q[b].x * corr / (r2 * r);
        a.x += m * dx; a.y += m * dy; a.z += m * dz;
    }

    v.x += a.x * dt; v.y += a.y * dt; v.z += a.z * dt;

    // **이 우주의 광속을 넘지 못한다.**
    //
    // 물리적으로 당연한 말이지만, 실용적인 이유가 더 크다. 블랙홀을 놓는 순간 이미 궤도
    // 속도로 돌던 알갱이들은 그 중력에 맞지 않는 속도가 되어 안으로 떨어지며 폭주한다.
    // 2026-08-14 실측: 광속의 21배(360)까지 올라갔고, 그러자 CFL 이 「한 스텝에 한 칸을
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
// 블랙홀 수만큼만 도는 아주 작은 커널이라 블록 하나로 충분하다.
__global__ void kSampleAccAtBH(const float4* accG, int G, int periodic,
                               BHPack bh, float4* out) {
    const int i = threadIdx.x;
    if (i >= bh.n) return;
    const float4 bp = bh.p[i];
    out[i] = sampleAcc(accG, make_float4(bp.x, bp.y, bp.z, 0.f), G, periodic);
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
            // 이 우주의 광속(17.3)에 닿은 것이 정확히 이 값이었고, 세기를 2.5분의 1로 낮춰도
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
    // 세기를 2.5분의 1로 낮춰도 여섯 경우 모두 알갱이가 이 우주의 광속(17.3)에 닿았다
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

// 냉각 — 이웃과의 무작위 운동만 걷어낸다.
//
// **이것이 없으면 아무것도 뭉치지 않는다.** 중력으로 모이면 위치에너지가 운동에너지로
// 바뀌어 그 자리가 데워지고, 데워진 것은 다시 흩어진다 — 모였다 흩어졌다만 되풀이한다.
// 실제 우주에서는 그 열이 빛으로 빠져나가기 때문에 수축이 멈추지 않고 별이 태어난다.
//
// 여기서 걷어내는 것은 **이웃과의 상대 속도**뿐이다. 이웃과 함께 흐르는 속도(회전·조류)는
// 그대로 두므로 원반이 멈추거나 은하가 주저앉지 않는다. 온도를 따로 들고 다니지 않아도
// 되는 것이 이 방식의 값어치다 — 속도 분산이 곧 온도다.
//
// 비용: N 스레드 × 27칸 × 최대 96 이웃. N=100만이면 9600만 번의 읽기로, 같은 상한을 쓰는
// kContact 과 같다(실측 스텝 4 ms). 상한이 없으면 뭉친 칸 하나가 프레임을 통째로 먹는다.
// 냉각 + **속도 분산 재기**를 한 번에 한다.
//
// 이 둘을 한 커널에 둔 이유는 게으름이 아니라 비용이다 — 둘 다 「이웃 27칸을 훑어
// 속도를 모으는」 같은 일이 필요하고, 그 훑기가 이 커널의 거의 전부다. 따로 두면
// 가장 비싼 부분을 두 번 한다.
//
// **비용**: N 스레드 × 최대 96 이웃 = 3.8억(N=400만). 여기에 압력을 켜면 알갱이마다
// 격자 원자 연산 4회가 더해진다 — 400만 × 4 = 1600만. CIC 8칸이 아니라 **자기 칸 하나**에만
// 쌓아서 그렇다(8칸이면 1억 2800만이 되어 kScatter 보다 4배 무거워진다). 이웃 27칸을
// 이미 훑은 값이라 그 자체로 국소 평균이고, 한 칸에 쌓아도 정보가 뭉개지지 않는다.
//
// **분산을 자기 속도 기준으로 잰다** — 이것이 이 커널의 핵심이다.
// 이웃 속도를 절대값으로 모아 분산을 내면 원반의 **차등회전**(안쪽이 빨리 도는 것)이
// 그대로 분산으로 잡혀, 사이좋게 나란히 도는 알갱이들이 「제각각 움직인다」고 오해된다.
// 그러면 없는 압력이 생겨 은하가 이유 없이 부푼다.
//   틀린 것: σ² = <|v_j|²> - <v_j>²   ← 회전·전단이 섞임
//   쓰는 것: σ² = <|v_j - v_i|²> - <v_j - v_i>²   ← 자기를 원점으로 옮겨 평균 흐름을 뺀다
// 두 식은 수학적으로 같은 값을 주지만(평행이동 불변), 뒤엣것은 **작은 수끼리 빼서**
// float 정밀도를 훨씬 덜 잃는다. 속도가 광속(1.0) 근처까지 가는 판이라 이 차이가 크다.
__global__ void kCool(const float4* pos, const float4* vel, int n, int G,
                      int periodic, const int* cellStart, const int* cellEnd,
                      float rate, float dt, float4* velOut,
                      float* dispX, float* dispY, float* dispZ, float* dispCnt) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    const float4 p = pos[i];
    const float4 v = vel[i];
    velOut[i] = v;                       // 손댈 일이 없으면 그대로 넘긴다
    if (p.x < 0.f) return;

    const int cx = min(max((int)(p.x * G), 0), G - 1);
    const int cy = min(max((int)(p.y * G), 0), G - 1);
    const int cz = min(max((int)(p.z * G), 0), G - 1);

    const int kMaxPeers = 96;            // kContact 과 같은 상한
    // 이웃 - 자기. 합과 제곱합을 함께 모아 한 번만 돌고 분산까지 낸다.
    float sdx = 0.f, sdy = 0.f, sdz = 0.f;
    float sqx = 0.f, sqy = 0.f, sqz = 0.f;
    int seen = 0;                        // **들여다본** 수 — 상한은 이것으로 센다
    int used = 0;                        // 그중 실제로 더한 수

    for (int dz = -1; dz <= 1 && seen < kMaxPeers; ++dz)
    for (int dy = -1; dy <= 1 && seen < kMaxPeers; ++dy)
    for (int dx = -1; dx <= 1 && seen < kMaxPeers; ++dx) {
        const int c = gidx3(cx + dx, cy + dy, cz + dz, G, G, periodic);
        const int s0 = cellStart[c], e0 = cellEnd[c];
        if (s0 < 0 || e0 <= s0) continue;
        for (int j = s0; j < e0 && seen < kMaxPeers; ++j) {
            if (j == i) continue;
            // 상한은 죽은 것까지 세어 올린다. 건너뛰며 세지 않으면 죽은 알갱이가 많은
            // 칸에서 루프가 칸 끝까지 돌아 상한이 무력해진다(kContact 과 같은 규칙).
            ++seen;
            if (pos[j].x < 0.f) continue;
            const float4 vj = vel[j];
            const float ax = vj.x - v.x, ay = vj.y - v.y, az = vj.z - v.z;
            sdx += ax; sdy += ay; sdz += az;
            sqx += ax * ax; sqy += ay * ay; sqz += az * az;
            ++used;
        }
    }
    if (used <= 0) return;               // 이웃이 없으면 잴 온도도 없다

    const float inv = 1.f / (float)used;
    // 이웃의 평균 흐름(자기 기준). 냉각은 이쪽으로 끌려가는 것이다.
    const float mx = sdx * inv, my = sdy * inv, mz = sdz * inv;

    // **이웃이 둘은 되어야 흩어짐을 잴 수 있다.**
    //
    // 하나뿐이면 분산이 **정확히 0** 이 나온다 — `sqx/1 - mx²` 에서 `mx = ax`, `sqx = ax²`
    // 이므로 `ax² - ax² = 0` 이다. 표본 하나로는 흩어진 정도를 잴 수 없다는 통계의 사실이
    // 식에 그대로 드러난 것인데, 그 0 을 격자에 쌓으면 **그 칸의 압력과 별 문턱이 함께
    // 0 으로 내려간다.** 2026-08-16 실측에서 이것 때문에 알갱이 100%가 별이 됐다 —
    // 냉각을 완전히 꺼서 σ² 를 190배로 올려도 그대로였다.
    if (dispCnt && used >= 2) {
        // 표본분산은 n 이 아니라 **n-1** 로 나눈다(불편추정량). 이웃이 둘일 때 n 으로 나누면
        // 참값의 절반이 나와, 알갱이가 성긴 자리일수록 압력이 체계적으로 약해진다.
        const float invU = 1.f / (float)(used - 1);
        const float vxx = fmaxf((sqx - (float)used * mx * mx) * invU, 0.f);
        const float vyy = fmaxf((sqy - (float)used * my * my) * invU, 0.f);
        const float vzz = fmaxf((sqz - (float)used * mz * mz) * invU, 0.f);
        const int c0 = gidx3(cx, cy, cz, G, G, periodic);
        atomicAdd(&dispX[c0], vxx);
        atomicAdd(&dispY[c0], vyy);
        atomicAdd(&dispZ[c0], vzz);
        atomicAdd(&dispCnt[c0], 1.0f);
    }

    // 한 스텝에 걷어내는 몫. dt 를 곱해 배속을 바꿔도 식는 속도가 그대로이게 하고,
    // 절반에서 끊는다 — 한 스텝에 이웃 속도로 통째로 갈아타면 알갱이들이 한 덩어리로
    // 굳어 버려 흐름이 사라진다.
    float k = rate * dt * 60.0f;
    if (k > 0.5f) k = 0.5f;

    // v + k·(v̄ - v) 인데, m 이 이미 (v̄ - v) 라 그대로 더하면 된다.
    velOut[i] = make_float4(v.x + k * mx, v.y + k * my, v.z + k * mz, v.w);
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
                          const float* dispCnt, float4* accG, int G, int periodic,
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

    // 중력 위에 **더한다** — 덮어쓰지 않는다. 이렇게 두면 kIntegrate 도 sampleAcc 도
    // 손댈 필요가 없다. 알갱이는 두 힘의 합을 하나로 받는다.
    float4 a = accG[c];
    a.x += ax; a.y += ay; a.z += az;
    accG[c] = a;
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
                          const float* dispCnt, float kJeans) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float4 p = pos[i];
    if (p.x < 0.f) return;               // 삼켜졌거나 빈 자리
    if (p.w != 0.f) return;              // 이미 별이거나(>0) 폭발 중(<0)

    const int cx = min(max((int)(p.x * G), 0), G - 1);
    const int cy = min(max((int)(p.y * G), 0), G - 1);
    const int cz = min(max((int)(p.z * G), 0), G - 1);
    const int c  = gidx3(cx, cy, cz, G, G, periodic);

    const float cnt = dispCnt[c];
    // 혼자 있는 알갱이는 별이 될 수 없다. 분산도 못 재고(이웃이 없다) 질량도 하나뿐이다.
    if (cnt < 2.f) return;

    // 방향별 분산의 평균. 셋을 더해 셋으로 나누는 대신 개수로만 나누면 3σ² 가 되므로
    // 그만큼 k_J 에 흡수시킨다 — 나눗셈 하나를 아낀다.
    const float s2 = (dispX[c] + dispY[c] + dispZ[c]) / cnt;

    // ρ > k_J · σ². σ² 가 0 에 가까우면(잘 식은 자리) 문턱이 0 으로 내려가는데,
    // 그때는 cnt >= 2 조건이 바닥 노릇을 한다.
    if (cnt > kJeans * s2) {
        p.w = cnt;                       // 별 질량 = 그 칸에 모인 알갱이 수
        pos[i] = p;
    }
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
                         float kickSpeed, unsigned seed) {
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float4 p = pos[i];
    if (p.x < 0.f) return;                   // 삼켜졌거나 빈 자리

    // ── 폭발 중이면 시간만 흘려보낸다 ──────────────────────────────────
    if (p.w < 0.f) {
        p.w += dt;                            // 음수가 0 을 향해 올라온다
        if (p.w >= 0.f) p.w = 0.f;            // 다 타면 가스로 — 여기서 사슬이 닫힌다
        pos[i] = p;
        return;
    }
    if (p.w == 0.f) return;                   // 가스는 늙지 않는다

    float4 v = vel[i];
    if (v.w < 0.f) return;                    // 잔해는 더 이상 안 늙는다

    v.w += dt;
    // 질량이 클수록 수명이 급격히 짧다. powf 가 비싸 보이지만 별인 알갱이만 지나므로
    // 실제로 도는 수는 전체의 일부다.
    const float ratio = fmaxf(p.w / sunMass, 1e-3f);
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
            p.w = -explodeSim;                // 폭발 시작 — 이 시간 동안 보인다
            v.w = 0.f;

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
__global__ void kCountStars(const float4* pos, int n, int* out) {
    __shared__ int s;
    if (threadIdx.x == 0) s = 0;
    __syncthreads();
    const int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n && pos[i].x >= 0.f && pos[i].w > 0.f) atomicAdd(&s, 1);
    __syncthreads();
    if (threadIdx.x == 0) atomicAdd(out, s);
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
struct ViewRot {
    float cy, sy;      // 좌우 돌리기(yaw) 의 코사인·사인
    float cp, sp;      // 위아래 기울이기(pitch)
    int   on;
};

// 판 안의 한 점을 돌려 화면 좌표로 옮긴다. 판 밖으로 나가면 false.
//
// 판은 정육면체라 비스듬히 보면 대각선이 한 변의 1.73배가 되어 모서리가 화면을 벗어난다.
// 줄여서 다 담으면 똑바로 볼 때보다 작아 보이므로, 여기서는 자르고 확대·축소는 사용자에게
// 맡긴다 — 알갱이는 대개 가운데 모여 있어 잘리는 것은 빈 모서리다.
__device__ inline bool rotPoint(float px, float py, float pz, const ViewRot& r,
                                float& ox, float& oy) {
    const float fx = px - 0.5f, fy = py - 0.5f, fz = pz - 0.5f;
    const float ax =  fx * r.cy + fz * r.sy;         // 세로축으로 돌린다
    const float az = -fx * r.sy + fz * r.cy;
    const float ay =  fy * r.cp - az * r.sp;         // 가로축으로 기울인다
    ox = ax + 0.5f; oy = ay + 0.5f;
    return (ox >= 0.f && ox < 1.f && oy >= 0.f && oy < 1.f);
}

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
__global__ void kFillShape(float4* pos, float4* vel, float* temp, int from, int count,
                           float cx, float cy, int kind, float R, float thickness,
                           unsigned seed) {
    const int t = blockIdx.x * blockDim.x + threadIdx.x;
    if (t >= count) return;
    const int i = from + t;
    const unsigned s = (unsigned)i * 2654435761u + seed;
    const float u1 = rnd01(s), u2 = rnd01(s * 3u + 1u), u3 = rnd01(s * 7u + 5u);

    float x, y, z = 0.5f + rndNormal(s ^ 0x2545F491u) * thickness;
    float temp0 = 0.02f;

    if (kind == 0) {                       // 은하 — 도는 원반
        const float3 p = diskPoint(R, thickness, s ^ 0x9E3779B9u);
        x = cx + p.x; y = cy + p.y; z = 0.5f + p.z;
    } else if (kind == 1) {                // 태양 — 가운데로 갈수록 빽빽하고 뜨겁다
        const float3 b = bulgePoint(R, s);
        x = cx + b.x; y = cy + b.y; z = 0.5f + b.z;
        temp0 = 0.6f;
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
    if (temp) temp[i] = temp0;
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
    float4 *accContact = nullptr;    // 접촉 가속도 N
    float  *rho = nullptr;           // 밀도(패딩 포함) S³
    float  *pot = nullptr;           // 퍼텐셜(패딩 포함) S³
    float  *proj = nullptr;          // 화면에 넘길 2D 투영 G²
    float  *projA = nullptr, *projB = nullptr;   // 속도 분산을 구할 때 쓰는 두 격자 G²
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
    // 블랙홀이 생길 때의 질량과 지평선. 삼켜서 자랄 때 이 둘을 기준으로 삼는다 —
    // 기준 없이 매번 처음 크기(cfg.blackHoleRs)에서 다시 시작하면, 크게 놓은 블랙홀도
    // 한 스텝 만에 작은 것과 같은 크기로 덮어써진다(2026-08-14 실측: 1만과 100만이
    // 0.006005 와 0.006128 로 거의 같았다).
    float bhMassAtBirth[kMaxBlackHoles] = {0};
    float bhRsAtBirth[kMaxBlackHoles] = {0};
    int   bhCount = 0;
    // 이번 스텝에 삼킨 수 — 블랙홀마다 하나씩.
    int *eaten = nullptr;
    // 각 블랙홀이 놓인 자리의 격자 가속도(둘레 물질이 블랙홀을 끄는 힘).
    // 커널이 채우고 host 가 읽어 블랙홀을 움직인다.
    float4 *bhAcc = nullptr;

    // 보는 방향(라디안). 둘 다 0 이면 위에서 곧장 내려다보던 예전 그대로다.
    float viewYaw = 0.f, viewPitch = 0.f;
    ViewRot viewRot() const {
        ViewRot r{};
        r.on = (viewYaw != 0.f || viewPitch != 0.f) ? 1 : 0;
        r.cy = cosf(viewYaw);   r.sy = sinf(viewYaw);
        r.cp = cosf(viewPitch); r.sp = sinf(viewPitch);
        return r;
    }

    // 가장 무거운 것. 오래 「판에 하나」였던 자리들이 이것을 본다.
    BlackHoleState heaviest() const {
        BlackHoleState best;
        for (int i = 0; i < bhCount; ++i)
            if (bhs[i].active && bhs[i].mass > best.mass) best = bhs[i];
        return best;
    }

    cudaEvent_t evA = nullptr, evB = nullptr;

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
        return 2.0f * cfg.gravity * M / fmaxf(cfg.lightSpeedSq, 1e-6f);
    }

    // 커널에 넘길 블랙홀 묶음을 만든다. 삼킴 반경의 바닥(격자 한 칸)도 여기서 건다.
    BHPack packBH() const;
    // i 번째 지평선을 그 질량에서 다시 낸다.
    void   setRsFrom(int i);
    // 블랙홀을 하나 더한다. 자리가 없으면 가장 가벼운 것을 밀어낸다. 그 번호를 돌려준다.
    int    addBlackHole(float x, float y, float z, float mass, bool born);
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
    // 삼키는 반경은 그리는 반경의 절반. 다만 **격자 한 칸보다 작아서는 안 된다** —
    // 그보다 작으면 지평선 바로 밖 한 칸이 삼켜지지 않는 자리가 되어 알갱이가 끝없이
    // 쌓이고, 그 칸에 질량을 더하는 원자 연산이 같은 주소에 겹쳐 커널이 드라이버
    // 타임아웃(2초)을 넘긴다. 2026-08-14 에 그것으로 시스템이 여섯 번 재부팅됐다.
    const float cell = 1.0f / (float)(allocG > 0 ? allocG : 1);
    const float inv  = 1.0f / (float)(allocN > 0 ? allocN : 1);
    for (int i = 0; i < bhCount && i < kMaxBlackHoles; ++i) {
        pk.p[i] = make_float4(bhs[i].x, bhs[i].y, bhs[i].z,
                              fmaxf(bhs[i].rs * 0.5f, cell));
        pk.q[i] = make_float4(cfg.gravity * bhs[i].mass * inv, bhs[i].rs, 0.f, 0.f);
    }
    pk.n = (bhCount < kMaxBlackHoles) ? bhCount : kMaxBlackHoles;
    return pk;
}

void Sim::Impl::setRsFrom(int i) {
    if (i < 0 || i >= kMaxBlackHoles) return;
    // 삼킬수록 지평선이 자란다 — 다만 **세제곱근으로** 자란다.
    // 실제 지평선은 질량에 정비례하지만(rs = 2GM/c²), 이 우주에서는 그 값이 화면의 점보다
    // 작아 아무것도 안 보인다. 그래서 처음 크기를 보이게 부풀려 놓았는데, 거기에 선형
    // 성장을 곱하면 부풀림까지 함께 자라 삼킬수록 커지고 커질수록 삼키는 되먹임이 생긴다.
    if (bhMassAtBirth[i] > 1e-6f && bhRsAtBirth[i] > 1e-9f) {
        const float grow = cbrtf(fmaxf(bhs[i].mass / bhMassAtBirth[i], 1.0f));
        bhs[i].rs = bhRsAtBirth[i] * grow;
        if (bhs[i].rs > 0.25f) bhs[i].rs = 0.25f;   // 화면의 4분의 1을 넘지 않는다
    }
}

int Sim::Impl::addBlackHole(float x, float y, float z, float mass, bool born) {
    // 기준 질량(판 전체의 2%) — 이 무게일 때 지평선이 cfg.blackHoleRs 가 된다.
    //
    // 마우스로 놓는 질량을 50분의 1 로 낮췄으니 이 기준도 같이 낮춰야 지평선이 예전 값으로
    // 돌아온다고 보고 0.0004 로 내려 봤는데, **더 나빠졌다.** 지평선이 0.0078(격자 한 칸
    // 바닥)에서 0.0117 로 커지자 삼키는 범위도 함께 넓어져, 놓은 직후 삼킨 양이 32만에서
    // 38만으로 늘었다(2026-08-14 실측). 밀집한 중심에 놓으면 지평선이 작을수록 덜 삼킨다.
    const float ref = 0.02f * (float)allocN;
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
    bhs[i].mass = mass;
    bhs[i].rs = cfg.blackHoleRs * cbrtf(fmaxf(mass / fmaxf(ref, 1.0f), 0.02f));
    if (bhs[i].rs > 0.25f) bhs[i].rs = 0.25f;
    bhMassAtBirth[i] = mass;
    bhRsAtBirth[i]   = bhs[i].rs;
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
            // 지평선 크기를 무름 길이로 쓴다. 없으면 가까워지는 순간 힘이 발산해 서로를
            // 튕겨 내고, 합쳐지기는커녕 판 밖으로 날아간다.
            const float soft = fmaxf(bhs[i].rs + bhs[j].rs, 1e-4f);
            const float r2 = dx * dx + dy * dy + dz * dz + soft * soft;
            const float r  = sqrtf(r2);
            const float m  = -cfg.gravity * bhs[j].mass * inv / (r2 * r);
            ax += m * dx; ay += m * dy; az += m * dz;
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
            if (d > bhs[i].rs + bhs[j].rs) continue;

            const float mi = bhs[i].mass, mj = bhs[j].mass;
            const float mt = fmaxf(mi + mj, 1e-6f);
            bhs[i].x  = (bhs[i].x  * mi + bhs[j].x  * mj) / mt;
            bhs[i].y  = (bhs[i].y  * mi + bhs[j].y  * mj) / mt;
            bhs[i].z  = (bhs[i].z  * mi + bhs[j].z  * mj) / mt;
            bhs[i].vx = (bhs[i].vx * mi + bhs[j].vx * mj) / mt;
            bhs[i].vy = (bhs[i].vy * mi + bhs[j].vy * mj) / mt;
            bhs[i].vz = (bhs[i].vz * mi + bhs[j].vz * mj) / mt;
            bhs[i].mass = mt;
            bhMassAtBirth[i] = fmaxf(bhMassAtBirth[i] + bhMassAtBirth[j], 1e-6f);
            bhRsAtBirth[i]   = fmaxf(bhRsAtBirth[i], bhRsAtBirth[j]);
            setRsFrom(i);

            // j 를 빼고 뒤를 당긴다 — 가운데를 비워 두면 번호가 어긋난다(맨 위 불변식).
            for (int k = j; k + 1 < bhCount; ++k) {
                bhs[k]           = bhs[k + 1];
                bhMassAtBirth[k] = bhMassAtBirth[k + 1];
                bhRsAtBirth[k]   = bhRsAtBirth[k + 1];
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
    F((void*&)accG); F((void*&)accContact); F((void*&)rho); F((void*&)pot);
    F((void*&)proj); F((void*&)projA); F((void*&)projB); F((void*&)accMag);
    F((void*&)dispX); F((void*&)dispY); F((void*&)dispZ); F((void*&)dispCnt);
    F((void*&)specRho); F((void*&)specGreen);
    F((void*&)keys); F((void*&)order); F((void*&)cellStart); F((void*&)cellEnd);
    F((void*&)flag); F((void*&)scan);
    F(sortTmp); F(redTmp);
    F((void*&)redD); F((void*&)redI); F((void*&)redU); F((void*&)redF);
    F((void*&)eaten); F((void*&)bhAcc);
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
    }
    CK(cudaMalloc(&rho, sizeof(float) * cells));
    CK(cudaMalloc(&pot, sizeof(float) * cells));
    CK(cudaMalloc(&proj, sizeof(float) * (size_t)G * G));
    CK(cudaMalloc(&projA, sizeof(float) * (size_t)G * G));
    CK(cudaMalloc(&projB, sizeof(float) * (size_t)G * G));
    CK(cudaMalloc(&specRho, sizeof(cufftComplex) * spec));
    CK(cudaMalloc(&specGreen, sizeof(cufftComplex) * spec));
    CK(cudaMalloc(&keys, sizeof(int) * N));
    CK(cudaMalloc(&order, sizeof(int) * N));
    CK(cudaMalloc(&flag, sizeof(int) * N));
    CK(cudaMalloc(&scan, sizeof(int) * N));
    CK(cudaMalloc(&cellStart, sizeof(int) * (size_t)G * G * G));
    CK(cudaMalloc(&cellEnd, sizeof(int) * (size_t)G * G * G));
    CK(cudaMalloc(&redD, sizeof(double) * 2));
    CK(cudaMalloc(&redI, sizeof(int) * 2));
    CK(cudaMalloc(&redU, sizeof(unsigned long long)));
    CK(cudaMalloc(&redF, sizeof(float)));
    // 삼킨 수와 블랙홀 자리의 가속도는 블랙홀마다 하나씩. 잡은 직후에 반드시 비운다 —
    // 미초기화 값을 그대로 읽어 질량에 더하면 블랙홀이 난데없이 무거워진다.
    CK(cudaMalloc(&eaten, sizeof(int) * kMaxBlackHoles));
    CK(cudaMalloc(&bhAcc, sizeof(float4) * kMaxBlackHoles));
    CK(cudaMemset(eaten, 0, sizeof(int) * kMaxBlackHoles));
    CK(cudaMemset(bhAcc, 0, sizeof(float4) * kMaxBlackHoles));

    if (!g_failed) {
        FK(cufftPlan3d(&planR2C, S, S, S, CUFFT_R2C));
        FK(cufftPlan3d(&planC2R, S, S, S, CUFFT_C2R));
        planReady = !g_failed;
    }
    if (!evA) { CK(cudaEventCreate(&evA)); CK(cudaEventCreate(&evB)); }
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
    if (cfg.pressureEnabled) {
        // 상한은 중력 쪽과 같은 자리에서 잘라야 뜻이 있다. kIntegrate 가 쓰는 값과 맞춘다.
        constexpr float kMaxPressureAcc = 5.0f;
        kPressure<<<grd3(allocG), blk3()>>>(dispX, dispY, dispZ, dispCnt, accG,
                                            allocG, periodic() ? 1 : 0,
                                            cfg.pressureK, kMaxPressureAcc);
    }
    CK(cudaGetLastError());
}

void Sim::Impl::placeInitial() {
    if (g_failed) return;
    const int preset = (cfg.preset == Preset::SpiralDisk) ? 0
                     : (cfg.preset == Preset::TidalPair)  ? 1
                     : (cfg.preset == Preset::CosmicWeb)  ? 2
                     : (cfg.preset == Preset::BlackHole)  ? 3 : 4;
    kPlace<<<(allocN + 255) / 256, 256>>>(pos, vel, temp, allocN, preset,
                                          cfg.bulgeFraction, cfg.bulgeRadius,
                                          cfg.diskThickness, 12345u);
    CK(cudaGetLastError());
    active = (preset == 4) ? 0 : allocN;
    aliveShown = -1;                       // 판을 새로 열었으니 세어 둔 값은 버린다
}

void Sim::Impl::giveOrbits() {
    if (g_failed || cfg.preset == Preset::Empty || cfg.preset == Preset::CosmicWeb) return;
    computeAccel();
    // 적분기가 쓰는 힘을 그대로 넘긴다 — 하나라도 빠지면 궤도가 어긋나 원반이 무너진다.
    const float haloV2 = cfg.haloEnabled ? (cfg.haloSpeed * cfg.haloSpeed) : 0.f;
    const float haloCore2 = cfg.haloCore * cfg.haloCore;
    kAccelMag<<<(allocN + 255) / 256, 256>>>(accG, pos, accMag, allocN, allocG,
                                             periodic() ? 1 : 0, haloV2, haloCore2, packBH());
    // 은하 충돌은 둘을 서로에게 밀어 준다. 나머지는 제자리에서 돈다.
    const float2 base = make_float2(0.f, 0.f);
    kSetOrbit<<<(allocN + 255) / 256, 256>>>(accG, vel, pos, accMag, allocN,
                                             cfg.orbitDispersion, cfg.bulgeRadius, base,
                                             cfg.diskThickness);
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

    // 제자리에서 고치면 옆 스레드가 이미 식은 값을 읽어 한쪽으로 쏠린다. 정렬이 쓰는
    // 임시 버퍼에 새 속도를 쓰고 통째로 바꿔 끼운다.
    //
    // 냉각이 꺼져 있으면 rate 에 0 을 넘긴다 — 커널 안에서 k=0 이 되어 속도가 그대로 나오고,
    // 분산만 쌓인다. 커널을 둘로 나누지 않는 이유는 이웃 훑기가 이 커널 비용의 거의 전부라
    // 나누면 가장 비싼 부분을 두 번 하기 때문이다.
    kCool<<<(allocN + 255) / 256, 256>>>(pos, vel, allocN, G, periodic() ? 1 : 0,
                                         cellStart, cellEnd,
                                         wantCool ? cfg.coolingRate : 0.f, dt, velTmp,
                                         wantPressure ? dispX : nullptr,
                                         wantPressure ? dispY : nullptr,
                                         wantPressure ? dispZ : nullptr,
                                         wantPressure ? dispCnt : nullptr);
    std::swap(vel, velTmp);
    CK(cudaGetLastError());

    // 별 판정. **방금 갱신한 분산을 그대로 읽으므로 이웃을 다시 훑지 않는다** — O(N) 이다.
    // 압력이 꺼져 있으면 σ² 가 없어 Jeans 조건을 세울 수 없으므로 함께 켜져 있을 때만 돈다.
    if (wantPressure && cfg.starFormationEnabled) {
        kStarForm<<<(allocN + 255) / 256, 256>>>(pos, allocN, G, periodic() ? 1 : 0,
                                                 dispX, dispY, dispZ, dispCnt,
                                                 cfg.starJeansK);
        CK(cudaGetLastError());
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
    bhs[i].rs = fmaxf(horizonOf(bhs[i].mass), cfg.blackHoleRs);
    bhRsAtBirth[i] = bhs[i].rs;
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
    b += sizeof(float)  * cells * 2;  // rho, pot
    b += sizeof(cufftComplex) * spec * 2;
    b += sizeof(int) * G * G * G * 2; // cellStart, cellEnd
    // 압력 격자 넷(dispX/Y/Z/Cnt). **패딩 없이 G³ 이라 cells 가 아니라 G³ 로 센다** —
    // 고립 경계에서 cells 는 G³ 의 여덟 배고, 그걸로 세면 실제의 여덟 배를 잡아 둔 것으로
    // 계산해 알갱이 상한이 까닭 없이 내려간다. 128³ 에서 이 넷은 33 MB 다.
    b += sizeof(float) * G * G * G * 4;
    // 위 두 줄은 화면용 격자(proj/projA/projB, G²)를 안 센다 — 셋을 합쳐도 128² 에서
    // 196 KB 라 어림에 영향이 없다.

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

    const double gridBytes = 20.0 * cells * 4.0;              // 푸아송 왕복
    const double partBytes = (double)particleCount * 80.0;    // pos·vel 읽고 쓰기 + 격자 표집
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
        d.bhMassAtBirth[i] = 0.f;
        d.bhRsAtBirth[i] = 0.f;
    }

    // 블랙홀 장면은 알갱이를 놓기 **전에** 세운다. 나중에 세우면 초기 궤도 속도가
    // 블랙홀 없는 중력만 보고 정해져, 원반이 통째로 빨려 든다.
    // (마우스로 놓는 쪽은 그럴 수 없으므로 그때는 둘레에 궤도를 따로 준다 — addShape 참조.)
    if (d.cfg.preset == Preset::BlackHole || d.cfg.blackHoleEnabled) {
        // **질량을 먼저 정하고 지평선을 거기서 낸다.** 반대로 하면 안 된다.
        //
        // 지평선 크기(0.006)에서 질량을 역산하면 rs·c²/(2G) = 1.5 — 판의 모든 알갱이를
        // 합친 것의 1.5배다. 은하보다 무거우니 원반이 통째로 곧장 빨려 들었다
        // (2026-08-14 실측). 실제 은하의 중심 블랙홀은 은하 질량의 0.1% 안팎이다.
        //
        // 여기서는 2% 로 둔다. 0.1% 로 하면 물리적으로는 옳지만 원반이 블랙홀을 거의
        // 못 느껴 「블랙홀 장면」이라는 이름이 무색해진다. 2% 면 안쪽이 눈에 띄게 감기면서도
        // 원반은 살아남아, 회전하며 빨려 드는 모습이 보인다.
        const int i = d.addBlackHole(0.5f, 0.5f, 0.5f, 0.02f * (float)d.allocN, false);
        // 그 질량의 지평선은 화면에서 점보다 작다. 삼킴 판정과 그리기에 쓸 최소 크기를 준다.
        d.bhs[i].rs = d.cfg.blackHoleRs;
        d.bhRsAtBirth[i] = d.bhs[i].rs;
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

    // CFL — 한 스텝에 한 칸을 넘게 가면 격자가 그 움직임을 못 따라가 알갱이가 튄다.
    CK(cudaMemset(d.redF, 0, sizeof(float)));
    kMaxSpeed<<<(d.allocN + 255) / 256, 256>>>(d.vel, d.pos, d.allocN, d.redF);
    float vmax = 0.f;
    CK(cudaMemcpy(&vmax, d.redF, sizeof(float), cudaMemcpyDeviceToHost));
    const float cell = 1.0f / (float)d.allocG;
    float dt = 0.0016f * d.cfg.timeScale;
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
    d.tm.dtUsed = dt; d.tm.maxSpeed = vmax; d.tm.substeps = 1;

    // 식히는 것은 힘을 더하기 전에 한다 — 이번 스텝의 dt 로 이웃과의 무작위 운동을 걷어낸다.
    // 속도를 줄이는 쪽이라 방금 CFL 이 정한 dt 를 위태롭게 하지 않는다.
    d.doCooling(dt);

    const float haloV2 = d.cfg.haloEnabled ? (d.cfg.haloSpeed * d.cfg.haloSpeed) : 0.f;
    const float haloCore2 = d.cfg.haloCore * d.cfg.haloCore;
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
        bhPack, d.cfg.lightSpeedSq, d.eaten, haloV2, haloCore2,
        // 세 힘 중 하나라도 켜져 있으면 그 가속도를 함께 넘긴다.
        (d.cfg.contactEnabled || d.cfg.strongForceEnabled || d.cfg.emForceEnabled)
            ? d.accContact : nullptr,
        d.cfg.spiralWaveEnabled ? d.cfg.spiralWaveStrength : 0.f,
        d.cfg.spiralWavePattern, d.cfg.spiralWavePitch, (float)d.simTime);
    CK(cudaGetLastError());

    if (d.bhCount > 0) {
        // 블랙홀이 놓인 자리의 격자 가속도를 뽑아 둔다 — 둘레 물질이 블랙홀을 끄는 힘이다.
        // 블랙홀 수만큼만 도는 커널이라 값이 거의 안 든다.
        kSampleAccAtBH<<<1, kMaxBlackHoles>>>(d.accG, d.allocG, d.periodic() ? 1 : 0,
                                              bhPack, d.bhAcc);
        CK(cudaGetLastError());

        // 삼킨 만큼 무거워지고 지평선이 자란다.
        int e[kMaxBlackHoles] = {0};
        CK(cudaMemcpy(e, d.eaten, sizeof(int) * d.bhCount, cudaMemcpyDeviceToHost));
        bool any = false;
        for (int i = 0; i < d.bhCount; ++i) {
            if (e[i] <= 0) continue;
            d.bhs[i].mass += (float)e[i];
            // 자라는 규칙은 setRsFrom 이 쥔다(세제곱근 — 그 자리의 주석 참조).
            d.setRsFrom(i);
            any = true;
        }
        // 다음 스텝을 위해 비운다. **여기서 비워 두어야** 아래에서 블랙홀이 합쳐지며
        // 배열이 당겨져도 남은 수가 엉뚱한 블랙홀의 것으로 섞이지 않는다.
        if (any) CK(cudaMemset(d.eaten, 0, sizeof(int) * kMaxBlackHoles));

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
            (unsigned)(d.stepCount * 2654435761u + 7919u));
        CK(cudaGetLastError());
    }

    d.simTime += dt;
    ++d.stepCount;

    CK(cudaEventRecord(d.evB));
    CK(cudaEventSynchronize(d.evB));
    float ms = 0.f;
    CK(cudaEventElapsedTime(&ms, d.evA, d.evB));
    d.tm.totalMs = ms;
}

const SimConfig& Sim::config() const { return impl_->cfg; }
SimTimings Sim::timings() const { return impl_->tm; }
double Sim::simTime() const { return impl_->simTime; }
bool Sim::failed() { return g_failed; }
std::string Sim::failMessage() { return g_failMsg; }
int Sim::gridSize() const { return impl_->allocG; }
int Sim::particleCount() const { return impl_->allocN; }
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
    kCountStars<<<(d.allocN + 255) / 256, 256>>>(d.pos, d.allocN, d.redI);
    int h = 0;
    CK(cudaMemcpy(&h, d.redI, sizeof(int), cudaMemcpyDeviceToHost));
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
        d.bhMassAtBirth[i] = 0.f;
        d.bhRsAtBirth[i] = 0.f;
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

    // 담아 두었던 블랙홀을 되돌린다. 자라는 기준(bhMassAtBirth·bhRsAtBirth)은 파일에
    // 없으므로 지금 값을 기준으로 삼는다 — 되살린 순간부터 다시 자라기 시작한다.
    d.bhCount = loadedBhCount;
    for (int i = 0; i < kMaxBlackHoles; ++i) {
        d.bhs[i] = (i < loadedBhCount) ? loadedBh[i] : BlackHoleState{};
        d.bhMassAtBirth[i] = d.bhs[i].mass;
        d.bhRsAtBirth[i]   = d.bhs[i].rs;
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

// 격자 중력의 정확도를 O(N²) 직접 계산과 견준다.
// 3D 전환에서는 이 진단을 쓰지 않는다 — 필요해지면 그때 되살린다.
double Sim::measureForceErrorVsDirect(int, int, float) { return 0.0; }

const float* Sim::densityDevicePtr() const { return impl_->rho; }

// 보는 방향을 정한다(라디안). 둘 다 0 이면 위에서 곧장 내려다보던 예전 그림 그대로다.
void Sim::setViewAngles(float yaw, float pitch) {
    impl_->viewYaw   = yaw;
    impl_->viewPitch = pitch;
}

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

    // 속도 분산(=은하의 온도)과 속력은 알갱이에서 바로 뿌린다.
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
const float* Sim::particleTempDevicePtr() const { return impl_->temp; }

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

    kFillShape<<<(n + 255) / 256, 256>>>(d.pos, d.vel, d.temp, from, n, cx, cy,
                                         (int)kind, radius, d.cfg.diskThickness,
                                         (unsigned)(d.stepCount * 7919 + 17));

    if (autoOrbit) {
        d.computeAccel();
        const float hv2 = d.cfg.haloEnabled ? (d.cfg.haloSpeed * d.cfg.haloSpeed) : 0.f;
        const float hc2 = d.cfg.haloCore * d.cfg.haloCore;
        kAccelMag<<<(d.allocN + 255) / 256, 256>>>(d.accG, d.pos, d.accMag, d.allocN,
                                                   d.allocG, d.periodic() ? 1 : 0, hv2, hc2,
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
            d.bhMassAtBirth[k] = d.bhMassAtBirth[k + 1];
            d.bhRsAtBirth[k]   = d.bhRsAtBirth[k + 1];
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
